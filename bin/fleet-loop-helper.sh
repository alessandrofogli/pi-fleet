#!/usr/bin/env bash
# pi-fleet · deterministic review-loop helper (T-015)
#
# Pure, deterministic helpers for the review&fix loop (see
# skills/fleet-review-loop and skills/review-loop-protocol). No AI, no state
# mutation, no side effects: JSON in → JSON out.
#
# Subcommands:
#   dedup <state-file...>        merge + deduplicate findings (by id + location)
#   group <findings.json>        group findings by review domain
#   partition <findings.json>    hybrid fixer partitioning (option c):
#                                parallel ONLY on disjoint files, sequential
#                                otherwise; a fixer NEVER crosses review domains
#   spec-validate <spec.json>    validate a pipeline spec (docs/pipeline-spec.md)
#   help                         this message
#
# Findings data model — the machine-readable contract of review-loop-protocol:
#   { id, severity, domain, checklist, location, rule, problem, evidence,
#     requiredFix, verification }
#   `location` is "path[:line]" (or a comma-separated list of such parts when a
#   single finding touches several files); the helper derives the file set from
#   it for partitioning.
#
# Input files for `dedup`/`partition` — pi-fleet task state files carrying the
# structured findings:
#   - the durable sibling `<id>.findings.json` ({"taskId":..., "findings": [...]})
#     written by reviewers per the orchestrator brief
#     (templates/fleet-loop-orchestrator.brief.md). The done-marker
#     `<id>.done.json` is TRANSIENT: the launcher consumes and deletes it
#     (bin/herdr-launch.sh) before the group digest wakes the orchestrator, so
#     the orchestrator reads the durable sibling.
#   - a done-marker `<id>.done.json` if still present (same shape, tolerated)
#   - a bare JSON array of findings
# A file is recognized by shape: an object with a `findings` array, or an array.
# Malformed/missing inputs are skipped with a warning on stderr (never crash).
#
# Determinism: same inputs → byte-identical outputs (stable sorts, no hashing
# randomness, no timestamps). Logs go to stderr; stdout carries ONLY the JSON
# result.
#
# Usage examples (from the pi-fleet repo root):
#   bin/fleet-loop-helper.sh dedup ~/.pi/fleet/*.findings.json
#   bin/fleet-loop-helper.sh group  findings.json
#   bin/fleet-loop-helper.sh partition --severity BLOCKING findings.json
#   bin/fleet-loop-helper.sh spec-validate fixtures/loop-sample/pipeline.spec.json
#
# Partition algorithm (hybrid — option (c) of the ticket):
#   1. derive the file set of every finding from `location`;
#   2. build the file-intersection graph over findings;
#   3. connected components → candidate batches (pairwise file-disjoint →
#      parallel-safe by construction);
#   4. within a component, findings of different domains are split into chained
#      sub-batches (they share files → strictly sequential; still one domain
#      per fixer);
#   5. greedy wave coloring: batch k goes into the lowest wave whose file set
#      is disjoint from every batch already placed there (parallel ⇔ disjoint
#      files, sequential ⇔ shared files).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '1,48p' "$0" | sed 's/^# \{0,1\}//'
}

log() { printf '[fleet-loop-helper] %s\n' "$*" >&2; }
die() { printf '[fleet-loop-helper] ERROR: %s\n' "$*" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || die "jq not found in PATH (brew install jq)"

# ---------------------------------------------------------------------------
# normalize <file>  →  prints the findings ARRAY contained in the file.
# Accepts: object with `findings` array (done-marker / durable findings file),
# or a bare array. Empty result on missing/invalid input (warn).
# ---------------------------------------------------------------------------
normalize() {
  local f="$1" out=""
  [[ -f "$f" ]] || { log "skip (missing file): $f"; return 0; }
  out="$(jq -c '
    if type == "array" then .
    elif type == "object" and has("findings") and (.findings | type) == "array" then .findings
    else null
    end
  ' "$f" 2>/dev/null)" || { log "skip (unparseable JSON): $f"; return 0; }
  [[ -z "$out" || "$out" == "null" ]] && { log "skip (no findings array): $f"; return 0; }
  printf '%s\n' "$out"
}

# ---------------------------------------------------------------------------
# emit_findings <files...>  →  one normalized findings array on stdout.
# Keeps only well-formed contract findings (id/domain/location required, known
# severities), trims locations, applies the optional SEVERITY_FILTER env.
# Malformed entries are counted and logged on stderr (never crash).
# ---------------------------------------------------------------------------
emit_findings() {
  local sev="${SEVERITY_FILTER:-}" merged="[]" arr kept dropped
  local f
  for f in "$@"; do
    arr="$(normalize "$f")" || continue
    [[ -n "$arr" ]] || continue
    merged="$(jq -nc --argjson base "$merged" --argjson add "$arr" '$base + $add')" \
      || { log "skip (merge failed): $f"; continue; }
  done
  kept="$(jq -c --arg sev "$sev" '
    def pick:
      { id, severity, domain, checklist, location, rule, problem, evidence,
        requiredFix, verification } +
      ( to_entries
        | map(select(.key as $k |
            (["id","severity","domain","checklist","location","rule","problem",
              "evidence","requiredFix","verification"] | index($k)) | not))
        | from_entries );
    [ .[]
        | select(type == "object")
        | select((.id|type)=="string" and (.id|length)>0)
        | select((.domain|type)=="string" and (.domain|length)>0)
        | select((.location|type)=="string" and (.location|length)>0)
        | .location = (.location | gsub("^[[:space:]]+|[[:space:]]+$"; ""))
        | .severity = (if has("severity") and (.severity == "BLOCKING" or .severity == "NON_BLOCKING") then .severity else "NON_BLOCKING" end)
        | select($sev == "" or .severity == $sev)
        | pick
      ]
  ' <<<"$merged")"
  dropped="$(jq -c --arg sev "$sev" '
    [ .[]
      | select(type != "object"
          or (has("id")|not) or ((.id|type)!="string") or (.id|length)==0
          or (has("domain")|not) or ((.domain|type)!="string") or (.domain|length)==0
          or (has("location")|not) or ((.location|type)!="string") or (.location|length)==0
          or (has("severity") and .severity != "BLOCKING" and .severity != "NON_BLOCKING")) ]
    | length
  ' <<<"$merged")"
  [[ -n "$dropped" && "$dropped" != "0" ]] && log "dropped $dropped malformed finding(s)"
  printf '%s\n' "$kept"
}

# Deterministic file set of a finding from its `location`:
# split on commas, strip a trailing ":<line>" / ":<line>-<line>" per part.
FILES_JQ='
  def files_of:
    .location as $loc
    | ( $loc | split(",")
      | map(gsub("^[[:space:]]+|[[:space:]]+$"; ""))
      | map(select(length > 0))
      | map(if test(":[0-9]+(-[0-9]+)?$") then
              sub(":[0-9]+(-[0-9]+)?$"; "") else . end)
      | map(select(length > 0)) )
    | if length == 0 then [$loc] else unique | sort end;
'

# Union-find over finding indexes (path compression, deterministic: the lexically
# smaller root wins). Edges = indexes whose file sets intersect.
UFIND_JQ='
  def uf_find($p; $x):
    ($p[$x|tostring]) as $px |
    if $px == $x then $x else uf_find($p; $px) end;
  def uf_union($p; $a; $b):
    (uf_find($p; $a)) as $ra | (uf_find($p; $b)) as $rb |
    if $ra == $rb then $p
    elif $ra < $rb then $p | .[($rb|tostring)] = $ra
    else $p | .[($ra|tostring)] = $rb end;
'

# ---------------------------------------------------------------------------
# dedup <state-file...>
# Output: a JSON array of findings, deduplicated by (id + normalized location),
# sorted by (id, location). Same id at DIFFERENT locations is kept (distinct
# instances); same id + same location collapses.
# ---------------------------------------------------------------------------
cmd_dedup() {
  [[ $# -ge 1 ]] || die "dedup: at least one state file required"
  local arr
  arr="$(emit_findings "$@")" || die "dedup: findings extraction failed"
  jq -c '
    ( reduce .[] as $f ({}; .[($f.id + "\u0000" + $f.location)] = $f)
      | to_entries | map(.value) | sort_by(.id, .location) )
  ' <<<"$arr"
}

# ---------------------------------------------------------------------------
# group <findings.json>
# Output: { "<DOMAIN>": [findings...], ... } — keys sorted, findings sorted
# by (id, location). Never invents findings.
# ---------------------------------------------------------------------------
cmd_group() {
  [[ $# -eq 1 ]] || die "group: exactly one findings JSON file required"
  local arr
  arr="$(emit_findings "$1")" || die "group: findings extraction failed"
  jq -c '
    group_by(.domain)
    | map({ key: .[0].domain, value: (. | sort_by(.id, .location)) })
    | sort_by(.key)
    | from_entries
  ' <<<"$arr"
}

# ---------------------------------------------------------------------------
# partition [--severity SEV] <findings.json>
# Hybrid fixer partitioning (see header). Output:
#   { "findings": N, "batches": [ { id, component, domain, files, findings,
#     wave } ], "waves": W }
# ---------------------------------------------------------------------------
cmd_partition() {
  local sev="" arr program
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --severity) sev="${2:?--severity needs a value}"; shift 2 ;;
      -*) die "partition: unknown option $1" ;;
      *) break ;;
    esac
  done
  [[ $# -eq 1 ]] || die "partition: exactly one findings JSON file required"
  SEVERITY_FILTER="$sev"
  arr="$(emit_findings "$1")" || die "partition: findings extraction failed"
  local body
  body="$(cat <<'JQEOF'
  . as $findings
  | ($findings | length) as $n
  | [ $findings[] | files_of ] as $fileSets
  # 2. edges (file intersection)
  | [ range(0; $n) as $i | range($i + 1; $n) as $j
      | select( any( $fileSets[$i][];
                     . as $f | any($fileSets[$j][]; . == $f) ) )
      | [$i, $j] ] as $edges
  # 3. union-find → roots (canonical = min index of the component)
  | (reduce $edges[] as $e
      ( reduce range(0; $n) as $i ({}; .[($i|tostring)] = $i );
        uf_union(.; $e[0]; $e[1]) )) as $p
  | [ range(0; $n) | uf_find($p; .) ] as $rawRoots
  | (reduce $rawRoots[] as $r ({}; .[($r|tostring)] = 1)) as $rset
  | (($rset | keys | map(tonumber)) | sort) as $compRoots
  | [ $compRoots[] as $r
      | { component: ($compRoots | index($r)),
          findings: [ range(0; $n) | select($rawRoots[.] == $r) ] } ] as $comps
  # 4. domain split within a component (chained when >1 domain)
  | [ $comps[] as $c
      | ( $c.findings
          | group_by($findings[.].domain)
          | map({ domain: $findings[.[0]].domain, idxs: . }) ) as $doms
      | [ $doms[] as $d
          | { component: $c.component,
              domain: $d.domain,
              idxs: ($d.idxs | sort) } ] ]
  | flatten as $rawBatches
  # 5. greedy wave coloring: first wave whose file set is disjoint from all placed
  | (reduce range(0; $rawBatches|length) as $b
      ( { batches: [] };
        . as $cur
        | ($rawBatches[$b].idxs | map($fileSets[.]) | add | unique | sort) as $files
        | ( [ range(1; 200) as $w
              | select( all( $cur.batches[];
                  .wave != $w or
                  ( ([$files[]] as $bf
                     | any( .files[]; . as $x | any($bf[]; . == $x) ) ) | not ) ) )
              | $w ]
            | if length > 0 then .[0]
              else ((($cur.batches | map(.wave) | max) // 0) + 1) end ) as $wave
        | { batches: ($cur.batches +
            [{ id: ((if $b < 9 then "fixer-0" else "fixer-" end) + (($b + 1)|tostring)),
               component: $rawBatches[$b].component,
               domain: $rawBatches[$b].domain,
               files: $files,
               findings: ($rawBatches[$b].idxs | map($findings[.].id) | sort),
               wave: $wave }]) } ) ) as $out
  | { findings: $n,
      batches: $out.batches,
      waves: ($out.batches | map(.wave) | max // 0) }
JQEOF
)"
  local program="${FILES_JQ}${UFIND_JQ}${body}"
  jq -c "$program" <<<"$arr"
}

# ---------------------------------------------------------------------------
# spec-validate <spec.json>
# Structural validation of a pipeline spec against docs/pipeline-spec.md
# (the Markdown there is the source of truth; this mirror implements it):
#   scope:string; slices:array(non-empty); checks:array
#   slice: id/title:string; impl_skills/review_skills/deps: arrays of strings;
#          unique slice ids; deps reference valid ids; deps form a DAG
#   check: name:string, cmd:string (exit 0 = pass)
#   unknown keys rejected (docs: "unknown keys are rejected by the machinery")
# Exit 0 with {"valid":true} / exit 1 with {"valid":false,"errors":[...]}.
# ---------------------------------------------------------------------------
cmd_spec_validate() {
  [[ $# -eq 1 ]] || die "spec-validate: exactly one spec JSON file required"
  local f="$1" spec errors="[]"
  [[ -f "$f" ]] || die "spec-validate: file not found: $f"
  jq -e . "$f" >/dev/null 2>&1 || die "spec-validate: not valid JSON: $f"
  spec="$(jq -c . "$f")"

  local add_err
  add_err() { errors="$(jq -c --arg e "$1" '. + [$e]' <<<"$errors")"; }
  local extra
  extra="$(jq -c '[keys[] | select(. != "scope" and . != "slices" and . != "checks")]' <<<"$spec")"
  [[ "$extra" != "[]" ]] && add_err "unknown top-level key(s): $(jq -r 'join(", ")' <<<"$extra")"

  jq -e 'has("scope") and (.scope|type)=="string" and (.scope|length)>0' <<<"$spec" >/dev/null 2>&1 \
    || add_err "scope: required non-empty string"
  jq -e 'has("slices") and (.slices|type)=="array" and (.slices|length)>0' <<<"$spec" >/dev/null 2>&1 \
    || add_err "slices: required non-empty array"
  jq -e 'has("checks") and (.checks|type)=="array"' <<<"$spec" >/dev/null 2>&1 \
    || add_err "checks: required array (may be empty)"
  jq -e '.slices | all(.[]; (has("id") and (.id|type)=="string" and (.id|length)>0))' <<<"$spec" >/dev/null 2>&1 \
    || add_err "slices[].id: required non-empty string (unique stable slug)"
  jq -e '.slices | all(.[]; (has("title") and (.title|type)=="string"))' <<<"$spec" >/dev/null 2>&1 \
    || add_err "slices[].title: required string"
  jq -e '.slices | all(.[]; (has("impl_skills") and (.impl_skills|type)=="array") and (all(.impl_skills[]; type=="string")))' <<<"$spec" >/dev/null 2>&1 \
    || add_err "slices[].impl_skills: required array of strings (may be empty)"
  jq -e '.slices | all(.[]; (has("review_skills") and (.review_skills|type)=="array") and (all(.review_skills[]; type=="string")))' <<<"$spec" >/dev/null 2>&1 \
    || add_err "slices[].review_skills: required array of strings (a configured skill must never be silently skipped)"
  jq -e '.slices | all(.[]; (has("deps") and (.deps|type)=="array") and (all(.deps[]; type=="string")))' <<<"$spec" >/dev/null 2>&1 \
    || add_err "slices[].deps: required array of strings (may be empty)"
  jq -e '.slices | group_by(.id) | all(length == 1)' <<<"$spec" >/dev/null 2>&1 \
    || add_err "slices[].id: must be unique"
  jq -e '(.slices | map(.id)) as $ids | .slices | all(.[]; all(.deps[]; . as $d | ($ids | index($d)) != null))' <<<"$spec" >/dev/null 2>&1 \
    || add_err "slices[].deps: must reference existing slice ids"
  jq -e '.slices | all(.[]; ([keys[]] | all(. as $k | (["id","title","impl_skills","review_skills","deps"] | index($k)) != null)))' <<<"$spec" >/dev/null 2>&1 \
    || add_err "slice has unknown key(s) (allowed: id, title, impl_skills, review_skills, deps)"
  jq -e '.checks | all(.[]; (has("name") and (.name|type)=="string" and (.name|length)>0) and (has("cmd") and (.cmd|type)=="string" and (.cmd|length)>0))' <<<"$spec" >/dev/null 2>&1 \
    || add_err "checks[]: each entry needs name (unique) and cmd (exit 0 = pass)"
  jq -e '.checks | group_by(.name) | all(length == 1)' <<<"$spec" >/dev/null 2>&1 \
    || add_err "checks[].name: must be unique"
  jq -e '.checks | all(.[]; ([keys[]] | all(. as $k | (["name","cmd"] | index($k)) != null)))' <<<"$spec" >/dev/null 2>&1 \
    || add_err "check has unknown key(s) (allowed: name, cmd)"

  # deps DAG: bounded iterative removal (no jq recursion: a recursive topo on a
  # non-progressing update can spin forever). A cycle exists iff some nodes can
  # never be resolved because their deps are still present.
  if jq -e '(.slices | map(.id)) as $ids | .slices | all(.[]; all(.deps[]; . as $d | ($ids | index($d)) != null))' <<<"$spec" >/dev/null 2>&1; then
    local cycle
    cycle="$(jq -c '
      ( [ .slices[] | {id: .id, deps: .deps} ] ) as $S
      | reduce range(0; ($S|length) + 1) as $round
          ( { rest: $S, removed: [], cyclic: false };
            . as $acc
            | ($acc.rest) as $r
            | ($acc.removed) as $rm
            | if $acc.cyclic then $acc
              elif ($r | length) == 0 then $acc
              elif ($r | any( . as $s | ( $s.deps | all( . as $d | ($rm | index($d)) != null ) ) )) then
                { rest: ($r | map(select( . as $s | ( $s.deps | all( . as $d | ($rm | index($d)) != null ) ) | not ))),
                  removed: ($rm + [ $r[] | select( . as $s | ( $s.deps | all( . as $d | ($rm | index($d)) != null ) ) ) | .id ]),
                  cyclic: false }
              else { rest: $r, removed: $rm, cyclic: true }
              end )
      | (.cyclic | not)
    ' <<<"$spec")"
    [[ "$cycle" == "false" ]] && add_err "slices[].deps: cycle detected (deps must form a DAG)"
  fi

  if [[ "$errors" == "[]" ]]; then
    printf '{"valid":true}\n'
    exit 0
  fi
  jq -c --argjson e "$errors" '{valid:false, errors:$e}' <<<"{}"
  exit 1
}

# ---------------------------------------------------------------------------
main() {
  local cmd="${1:-help}"
  shift || true
  case "$cmd" in
    dedup)         cmd_dedup "$@" ;;
    group)         cmd_group "$@" ;;
    partition)     cmd_partition "$@" ;;
    spec-validate) cmd_spec_validate "$@" ;;
    help|-h|--help) usage; exit 0 ;;
    *) die "unknown subcommand: $cmd (try: help)" ;;
  esac
}

main "$@"