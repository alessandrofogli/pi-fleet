#!/usr/bin/env bash
# pi-fleet · deterministic review-loop helper (T-015)
#
# Pure, deterministic helpers for the review&fix loop (see
# skills/fleet-review-loop and skills/review-loop-protocol). No AI: JSON in →
# JSON out. The loop-state subcommands (T-019) are the ONE documented exception
# to 'no state mutation': they read/update the mechanical cycle bound file
# ~/.pi/fleet/<loop>.loop.json ({cycle, maxCycles}) so the orchestrator bound is
# machine-enforced, not prompt-only.
#
# Subcommands:
#   dedup <state-file...>        merge + deduplicate findings (by id + location)
#   group <findings.json>        group findings by review domain
#   partition <findings.json>    hybrid fixer partitioning (option c):
#                                parallel ONLY on disjoint files, sequential
#                                otherwise; a fixer NEVER crosses review domains
#   spec-validate <spec.json>    validate a pipeline spec (docs/pipeline-spec.md)
#   loop-init <loopId> <maxCycles> [--reset]
#                                create the cycle-bound file (cycle=1)
#   loop-next <loopId> <maxCycles>
#                                mechanical entry to the NEXT cycle; REFUSES
#                                (exit 1) when cycle >= maxCycles
#   loop-final <loopId> <maxCycles>
#                                gate for a terminal verdict: ok ONLY when
#                                cycle == maxCycles (refuses early exits)
#   loop-state <loopId>          read-only dump of the bound file
#   help                         this message
#
# Loop-state file: $FLEET_STATE_HOME/<loopId>.loop.json (default ~/.pi/fleet).
# loopId is sanitized to [A-Za-z0-9._-] (max 64 chars). loop-next:
#   missing file -> init cycle=1 (ok, first cycle) | cycle < maxCycles -> bump
#   | cycle >= maxCycles -> REFUSE {"ok":false,"refused":"maxCycles",...} exit 1.
# loop-final: cycle == maxCycles -> ok | cycle < maxCycles -> REFUSE
# {"ok":false,"refused":"early-exit",...} exit 1 (a terminal verdict before the
# bound is a contract violation). All outputs are JSON on stdout; logs on stderr.
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
# loop-state helpers (T-019) — mechanical review-loop cycle bound
# ~/.pi/fleet/<loopId>.loop.json = {cycle, maxCycles, updatedAt}
# ---------------------------------------------------------------------------
LOOP_STATE_HOME="${FLEET_STATE_HOME:-$HOME/.pi/fleet}"

sanitize_loop_id() {
  local raw="$1"
  raw="$(printf '%s' "$raw" | tr -c 'A-Za-z0-9._-' '_')"
  raw="${raw:0:64}"
  printf '%s' "$raw"
}

loop_file() {
  local id
  id="$(sanitize_loop_id "$1")"
  printf '%s' "$LOOP_STATE_HOME/$id.loop.json"
}

# loop_read <loopId> → prints {cycle, maxCycles} or nothing (missing/invalid)
loop_read() {
  local f
  f="$(loop_file "$1")"
  [[ -f "$f" ]] || return 1
  jq -r '{cycle: (.cycle // 0), maxCycles: (.maxCycles // 0)}' "$f" 2>/dev/null
}

# loop_write <loopId> <cycle> <maxCycles> (atomic tmp+mv)
loop_write() {
  local f
  f="$(loop_file "$1")"
  mkdir -p "$LOOP_STATE_HOME" 2>/dev/null || true
  jq -nc --argjson c "$2" --argjson m "$3" --argjson at "$(date +%s)000" \
    '{cycle:$c, maxCycles:$m, updatedAt:$at}' > "$f.tmp.$$" 2>/dev/null \
    && mv "$f.tmp.$$" "$f" 2>/dev/null \
    && rm -f "$f.tmp.$$" 2>/dev/null || true
}

cmd_loop_init() {
  local loopId="${1:-}" max="${2:-}" reset=0 f cy mx
  [[ -n "$loopId" && -n "$max" ]] || die "loop-init: <loopId> and <maxCycles> required"
  [[ "${3:-}" == "--reset" ]] && reset=1
  case "$max" in ''|*[!0-9]*) die "loop-init: maxCycles must be a positive integer" ;; esac
  [ "$max" -ge 1 ] || die "loop-init: maxCycles must be >= 1"
  f="$(loop_file "$loopId")"
  if [[ -f "$f" ]] && [[ "$reset" -eq 0 ]]; then
    cy="$(jq -r '.cycle // 0' "$f" 2>/dev/null || echo 0)"
    mx="$(jq -r '.maxCycles // 0' "$f" 2>/dev/null || echo 0)"
    jq -nc --argjson c "$cy" --argjson m "$mx" '{ok:false, refused:"exists", cycle:$c, maxCycles:$m}'
    exit 1
  fi
  loop_write "$loopId" 1 "$max"
  jq -nc --argjson m "$max" '{ok:true, cycle:1, maxCycles:$m}'
}

cmd_loop_next() {
  local loopId="${1:-}" max="${2:-}" cur cy mx
  [[ -n "$loopId" && -n "$max" ]] || die "loop-next: <loopId> and <maxCycles> required"
  case "$max" in ''|*[!0-9]*) die "loop-next: maxCycles must be a positive integer" ;; esac
  [ "$max" -ge 1 ] || die "loop-next: maxCycles must be >= 1"
  cur="$(loop_read "$loopId")"
  if [[ -z "$cur" ]]; then
    loop_write "$loopId" 1 "$max"
    jq -nc --argjson m "$max" '{ok:true, cycle:1, maxCycles:$m}'
    return 0
  fi
  cy="$(printf '%s' "$cur" | jq -r '.cycle // 0')"
  mx="$(printf '%s' "$cur" | jq -r '.maxCycles // 0')"
  # bound already reached (or the requested max shrank): mechanical refusal
  if [[ "$cy" -ge "$max" ]]; then
    jq -nc --argjson c "$cy" --argjson m "$max" \
      '{ok:false, refused:"maxCycles", cycle:$c, maxCycles:$m, message:"cycle bound reached: cannot start another cycle"}'
    exit 1
  fi
  loop_write "$loopId" $((cy + 1)) "$max"
  jq -nc --argjson c $((cy + 1)) --argjson m "$max" '{ok:true, cycle:$c, maxCycles:$m}'
}

cmd_loop_final() {
  local loopId="${1:-}" max="${2:-}" cur cy mx
  [[ -n "$loopId" && -n "$max" ]] || die "loop-final: <loopId> and <maxCycles> required"
  case "$max" in ''|*[!0-9]*) die "loop-final: maxCycles must be a positive integer" ;; esac
  [ "$max" -ge 1 ] || die "loop-final: maxCycles must be >= 1"
  cur="$(loop_read "$loopId")"
  if [[ -z "$cur" ]]; then
    jq -nc --argjson m "$max" '{ok:false, refused:"unstarted", cycle:0, maxCycles:$m}'
    exit 1
  fi
  cy="$(printf '%s' "$cur" | jq -r '.cycle // 0')"
  mx="$(printf '%s' "$cur" | jq -r '.maxCycles // 0')"
  if [[ "$cy" -eq "$max" ]]; then
    jq -nc --argjson c "$cy" --argjson m "$max" '{ok:true, cycle:$c, maxCycles:$m}'
    return 0
  fi
  jq -nc --argjson c "$cy" --argjson m "$max" \
    '{ok:false, refused:"early-exit", cycle:$c, maxCycles:$m, message:"terminal verdict before the cycle bound: cycle < maxCycles"}'
  exit 1
}

cmd_loop_state() {
  local cur
  cur="$(loop_read "${1:-}")"
  if [[ -z "$cur" ]]; then
    jq -nc '{ok:false, refused:"missing", cycle:0, maxCycles:0}'
    exit 1
  fi
  printf '%s\n' "$cur"
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
    loop-init)     cmd_loop_init "$@" ;;
    loop-next)     cmd_loop_next "$@" ;;
    loop-final)    cmd_loop_final "$@" ;;
    loop-state)    cmd_loop_state "$@" ;;
    help|-h|--help) usage; exit 0 ;;
    *) die "unknown subcommand: $cmd (try: help)" ;;
  esac
}

main "$@"