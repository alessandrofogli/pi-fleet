#!/usr/bin/env bash
# pi-fleet · deterministic pipeline helper (T-017)
#
# Pure, deterministic helpers for the pipeline orchestrator (shipper DAG
# waves + md→yaml converter + hybrid integration). No AI, no state mutation,
# no side effects: JSON in → JSON out (logs go to stderr only).
#
# Subcommands:
#   convert <tickets.md> [--out <pipeline.yaml>] [--json-out <pipeline.spec.json>]
#       md→yaml converter: parse a pipeline ticket markdown document
#       (format documented in docs/pipeline-tickets.md — the source of
#       truth) into a pipeline spec per docs/pipeline-spec.md (the T-014
#       schema: scope, slices[{id,title,impl_skills,review_skills,deps}],
#       checks[{name,cmd}]). The projection is validated (unknown keys /
#       cycles invalid — same rules as spec-validate); the markdown stays
#       the source of truth, the YAML/JSON are a LOSSLESS projection.
#       Stdout: the spec JSON (machine mirror). --out writes pipeline.yaml
#       via a deterministic YAML emitter; --json-out writes the JSON mirror.
#   waves <spec.json>
#       deterministic DAG waves (topological layers): wave k = slices whose
#       deps are all resolved by the end of wave k-1; wave 1 = slices with no
#       deps. No deps at all -> ONE wave with every slice. Slices within a
#       wave are sorted lexically (determinism). Output:
#       {"total":N,"waves":[["a","b"],["c"]],"order":[...],"cycle":false}
#   integrate <spec.json> <shipper-status.json>
#       hybrid integration plan (option (c) of the ticket) over the ACTUAL
#       file sets of the shipper branches: parallel batches ONLY on disjoint
#       files, sequential otherwise. Same coloring algorithm as the
#       review-loop helper partition (union-find over file sets + greedy wave
#       coloring): same-wave batches are file-disjoint BY CONSTRUCTION (the
#       output carries a `disjoint` proof flag). Input status shape:
#       [{"slice":"<id>","branch":"fleet/<taskid>-<slug>","files":["rel/path",...]}]
#       Output: {"slices":N,"batches":[{id,slice,branch,files,wave}...],
#       "waves":W,"disjoint":true|false}
#   spec-validate <spec.json>
#       delegates to bin/fleet-loop-helper.sh spec-validate (single source
#       of truth for the pipeline-spec schema rules).
#   help                         this message
#
# Determinism: same inputs -> byte-identical outputs (stable sorts, no
# randomness, no timestamps).
#
# Usage examples (from the pi-fleet repo root):
#   bin/fleet-pipeline-helper.sh convert tickets.md --out pipeline.yaml --json-out pipeline.spec.json
#   bin/fleet-pipeline-helper.sh waves   pipeline.spec.json
#   bin/fleet-pipeline-helper.sh integrate pipeline.spec.json shipper-status.json
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOOP_HELPER="$SCRIPT_DIR/fleet-loop-helper.sh"

usage() {
  sed -n '1,42p' "$0" | sed 's/^# \{0,1\}//'
}

log() { printf '[fleet-pipeline-helper] %s\n' "$*" >&2; }
die() { printf '[fleet-pipeline-helper] ERROR: %s\n' "$*" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || die "jq not found in PATH (brew install jq)"
[[ -f "$LOOP_HELPER" ]] || die "review-loop helper not found: $LOOP_HELPER"

# ---------------------------------------------------------------------------
# spec_validate <spec.json> — delegate to fleet-loop-helper.sh spec-validate
# (the single source of truth implementing docs/pipeline-spec.md).
# ---------------------------------------------------------------------------
spec_validate() {
  [[ $# -eq 1 ]] || die "spec-validate: exactly one spec JSON file required"
  local f="$1"
  [[ -f "$f" ]] || die "spec-validate: file not found: $f"
  "$LOOP_HELPER" spec-validate "$f"
}

# ---------------------------------------------------------------------------
# PARSER_JQ — pipeline tickets markdown -> {valid, spec} (see
# docs/pipeline-tickets.md for the input format). Strict: unknown sections,
# unknown slice fields, duplicate ids/fields/check names, id pattern
# violations, missing scope/title/slices -> {valid:false, errors:[...]} with
# line numbers. List fields omitted in the markdown default to [] (the
# projection always carries every schema-required key). Markdown stays the
# source of truth: this is a lossless projection, never a rewrite.
# ---------------------------------------------------------------------------
read -r -d '' PARSER_JQ <<'JQEOF' || true
def trim: gsub("^[[:space:]]+|[[:space:]]+$"; "");
def is_comment: test("^[[:space:]]*<!--");
[ inputs ] as $raw
| [ $raw | to_entries[] | { n: (.key + 1), t: (.value | gsub("
$"; "")) } ] as $lines
| [ ($lines | to_entries[] | select(.value.t | test("^## ")) | .key) ] as $hdrIdx
| ($lines | length) as $L
| [ range(0; ($hdrIdx | length)) as $i
    | { start: ($hdrIdx[$i] + 1),
        end:   (if ($i + 1) < ($hdrIdx | length) then $hdrIdx[$i + 1] else $L end),
        hdr:   ($lines[$hdrIdx[$i]].t | gsub("^##[[:space:]]+"; "") | trim) } ] as $secs
| [ $secs[] as $s
    | { hdr: $s.hdr,
        body: [ (range($s.start; $s.end) as $i
                 | select(($lines[$i].t | trim | length) > 0)
                 | select(($lines[$i].t | is_comment) | not)
                 | { n: $lines[$i].n, t: ($lines[$i].t | trim) }) ] } ] as $secBodies
| ($secBodies | map(select(.hdr == "scope") | .body | map(.t) | join("
")) | .[0] // null) as $scope
| [ $secBodies[] | select( .hdr | startswith("slice ") ) ] as $sliceSecs
| ([ $secBodies[].hdr ] | map(select(test("^(scope|checks|slice[[:space:]]+[a-zA-Z0-9_-]+)$") | not))) as $badSection
| ( $sliceSecs | map(.hdr | gsub("^slice[[:space:]]+"; "") | trim) ) as $allIds
| ($allIds | group_by(.) | map(select(length > 1)) | map(.[0])) as $dupIds
| [ $allIds[] | select( (test("^[a-z0-9][a-z0-9-]*$")) | not ) ] as $badIds
| [ $sliceSecs[]
    | . as $sec
    | ($sec.hdr | gsub("^slice[[:space:]]+"; "") | trim) as $id
    | { id: $id, title: null, impl_skills: [], review_skills: [], deps: [] } as $base
    | ( reduce $sec.body[] as $ln
        ( { o: $base, err: [], seen: {} };
          ( ($ln.t | capture("^(?<k>[a-zA-Z0-9_-]+)[[:space:]]*:[[:space:]]*(?<v>.*)$")) // null ) as $m
          | if $m == null then .err += [ ("slice '" + $id + "': expected 'key: value' field line (line " + ($ln.n|tostring) + "): '" + $ln.t + "'") ]
            elif ($m.k == "title") then
              if (($m.v | trim | length) == 0) then .err += [ ("slice '" + $id + "': title must be non-empty (line " + ($ln.n|tostring) + ")") ]
              elif (.o.title != null) then .err += [ ("slice '" + $id + "': duplicate field 'title' (line " + ($ln.n|tostring) + ")") ]
              else .o.title = ($m.v | trim) end
            elif (["impl_skills","review_skills","deps"] | index($m.k)) != null then
              if (.seen[$m.k] == true) then .err += [ ("slice '" + $id + "': duplicate field '" + $m.k + "' (line " + ($ln.n|tostring) + ")") ]
              else .o[$m.k] = ($m.v | split(",") | map(trim) | map(select(length > 0))) | .seen[$m.k] = true end
            else .err += [ ("slice '" + $id + "': unknown field '" + $m.k + "' (line " + ($ln.n|tostring) + ")") ]
            end )
      | if .o.title == null then .err += [ ("slice '" + $id + "': missing required field 'title'") ] end
      | { id: $id, spec: .o, err: .err } ) ] as $sliceParsed
| ( [ $secBodies[] | select(.hdr == "checks") | .body[]
      | ( (.t | capture("^(?<n>[^:]+):[[:space:]]*(?<c>.*)$")) // null ) as $m
      | if $m == null then { err: [ ("checks: expected 'name: cmd' line (line " + (.n|tostring) + "): '" + .t + "'") ] }
        elif (($m.n | trim | length) == 0) then { err: [ ("checks: empty name (line " + (.n|tostring) + ")") ] }
        elif (($m.n | trim | test("^[^[:space:]]+$")) | not) then { err: [ ("checks: name '" + ($m.n|trim) + "' must not contain whitespace (line " + (.n|tostring) + ")") ] }
        elif (($m.c | trim | length) == 0) then { err: [ ("checks: empty cmd for '" + ($m.n|trim) + "' (line " + (.n|tostring) + ")") ] }
        else { chk: { name: ($m.n | trim), cmd: ($m.c | trim) } } end ] ) as $chkRaw
| ( [$chkRaw[] | .chk? // empty] ) as $checks
| ([ $chkRaw[] | select(has("err")) | .err[] ]) as $chkErr
| ([ $checks[].name ] | group_by(.) | map(select(length > 1)) | map(.[0]) | map("checks: duplicate name '" + . + "'")) as $dupChk
| (($scope == null) or ($scope | trim | length) == 0) as $noScope
| (($sliceParsed | length) == 0) as $noSlices
| ( [ $sliceParsed[].err[] ] + [ $badSection[] | ("unknown section '## " + . + "'") ] + $chkErr + $dupChk
    + [ $dupIds[] | ("slice '" + . + "' duplicate id") ]
    + [ $badIds[] | ("slice id '" + . + "' must match ^[a-z0-9][a-z0-9-]*$") ]
    + (if $noScope then [ "missing '## scope' section (required)" ] else [] end)
    + (if $noSlices then [ "at least one '## slice <id>' section required" ] else [] end)
  ) as $errors
| if ($errors | length) > 0
  then { valid: false, errors: $errors }
  else { valid: true,
         spec: { scope: $scope,
                 slices: [ $sliceParsed[].spec ],
                 checks: $checks } }
  end
JQEOF

# ---------------------------------------------------------------------------
# YAML_EMIT_JQ — deterministic YAML emitter for the (assumed valid) spec
# object: scope as a literal block scalar, slices/checks as list of maps,
# strings either bare (safe charset) or single-quoted with '' doubling.
# ---------------------------------------------------------------------------
read -r -d '' YAML_EMIT_JQ <<'JQEOF' || true
def ystr:
  if test("^[A-Za-z0-9_][A-Za-z0-9_ ./+%:=@()-]*$") then .
  else "'" + (gsub("'"; "''")) + "'" end;
def lst: "[" + ((map(ystr)) | join(", ")) + "]";
"scope: |-",
( .scope | split("\n") | map("  " + .)[]),
"slices:",
( .slices[] | "  - id: " + (.id | ystr),
              "    title: " + (.title | ystr),
              "    impl_skills: " + (.impl_skills | lst),
              "    review_skills: " + (.review_skills | lst),
              "    deps: " + (.deps | lst) ),
"checks:",
( .checks[] | "  - name: " + (.name | ystr),
               "    cmd: " + (.cmd | ystr) )
JQEOF

# ---------------------------------------------------------------------------
# WAVES_JQ — topological DAG waves over validated spec slices.
# ---------------------------------------------------------------------------
read -r -d '' WAVES_JQ <<'JQEOF' || true
[ .slices[] | { id, deps } ] as $S
| reduce range(0; ($S|length) + 1) as $round
    ( { waves: [], resolved: [], rest: $S, cycles: 0 };
      if (.rest | length) == 0 then .
      else
        . as $acc
        | ($acc.rest | map(select( all(.deps[]; . as $d | ($acc.resolved | index($d)) != null) ))) as $ready
        | if ($ready | length) == 0
          then { waves: ($acc.waves + [ [] ]), resolved: $acc.resolved,
                 rest: $acc.rest, cycles: ($acc.cycles + 1) }
          else { waves: ($acc.waves + [ ($ready | map(.id) | sort) ]),
                 resolved: ($acc.resolved + ($ready | map(.id))),
                 rest: ($acc.rest | map(select( . as $s |
                       (all(.deps[]; . as $d | ($acc.resolved | index($d)) != null)) | not ))),
                 cycles: $acc.cycles }
          end
      end )
| { total: (.waves | map(length) | add),
    waves: .waves,
    order: (.waves | add),
    cycle: (.cycles > 0) }
JQEOF

# ---------------------------------------------------------------------------
# INTEGRATE_JQ — hybrid integration plan (option (c)): synthetic findings
# (one per shipper slice, location = its actual file set) + the SAME
# union-find + greedy wave-coloring algorithm as fleet-loop-helper partition
# (parallel batches ONLY on disjoint files). `disjoint` asserts the coloring
# invariant on the output (proven in the smoke).
# ---------------------------------------------------------------------------
read -r -d '' INTEGRATE_JQ <<'JQEOF' || true
def files_of:
  .location as $loc
  | ( $loc | split(",")
      | map(gsub("^[[:space:]]+|[[:space:]]+$"; ""))
      | map(select(length > 0))
      | map(if test(":[0-9]+(-[0-9]+)?$") then
              sub(":[0-9]+(-[0-9]+)?$"; "") else . end)
      | map(select(length > 0)) )
  | if length == 0 then [$loc] else unique | sort end;
def uf_find($p; $x):
  ($p[$x|tostring]) as $px |
  if $px == $x then $x else uf_find($p; $px) end;
def uf_union($p; $a; $b):
  (uf_find($p; $a)) as $ra | (uf_find($p; $b)) as $rb |
  if $ra == $rb then $p
  elif $ra < $rb then $p | .[($rb|tostring)] = $ra
  else $p | .[($ra|tostring)] = $rb end;
[ $status[] | { id: .slice, domain: .slice, slice: .slice, branch: .branch,
                location: ((.files // []) | join(",")) } ] as $findings
| ($findings | length) as $n
| [ $findings[] | files_of ] as $fileSets
| [ range(0; $n) as $i | range($i + 1; $n) as $j
    | select( any( $fileSets[$i][]; . as $f | any($fileSets[$j][]; . == $f) ) )
    | [$i, $j] ] as $edges
| (reduce $edges[] as $e
    ( reduce range(0; $n) as $i ({}; .[($i|tostring)] = $i );
      uf_union(.; $e[0]; $e[1]) )) as $p
| [ range(0; $n) | uf_find($p; .) ] as $rawRoots
| (reduce $rawRoots[] as $r ({}; .[($r|tostring)] = 1)) as $rset
| (($rset | keys | map(tonumber)) | sort) as $compRoots
| [ $compRoots[] as $r
    | { component: ($compRoots | index($r)),
        findings: [ range(0; $n) | select($rawRoots[.] == $r) ] } ] as $comps
| [ $comps[] as $c
    | ( $c.findings
        | group_by($findings[.].domain)
        | map({ domain: $findings[.[0]].domain, idxs: . }) ) as $doms
    | [ $doms[] as $d
        | { component: $c.component,
            domain: $d.domain,
            idxs: ($d.idxs | sort) } ] ]
| flatten as $rawBatches
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
          [{ id: ((if $b < 9 then "integrate-0" else "integrate-" end) + (($b + 1)|tostring)),
             slice: $findings[$rawBatches[$b].idxs[0]].slice,
             branch: $findings[$rawBatches[$b].idxs[0]].branch,
             files: $files,
             wave: $wave }]) } ) ) as $out
| { slices: $n,
    batches: $out.batches,
    waves: (($out.batches | map(.wave) | max) // 0),
    disjoint: ( [ $out.batches[] | . as $b | select( [ $out.batches[] |
                 select(.wave == $b.wave and .id != $b.id)
                 | .files[] as $f | (($b.files | index($f)) != null) ] | any ) ]
               | length == 0 ) }
JQEOF

# ---------------------------------------------------------------------------
# cmd_convert <tickets.md> [--out yaml] [--json-out json]
# ---------------------------------------------------------------------------
cmd_convert() {
  local md="" out_yaml="" out_json="" parsed tmp
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out) out_yaml="${2:?--out needs a value}"; shift 2 ;;
      --json-out) out_json="${2:?--json-out needs a value}"; shift 2 ;;
      -*) die "convert: unknown option $1" ;;
      *) [[ -z "$md" ]] && md="$1" || die "convert: too many arguments (expect <tickets.md>)"; shift ;;
    esac
  done
  [[ -n "$md" ]] || die "convert: missing <tickets.md> argument"
  [[ -f "$md" ]] || die "convert: file not found: $md"

  parsed="$(jq -Rn "$PARSER_JQ" "$md")" || die "convert: parse failed"
  if jq -e '.valid != true' <<<"$parsed" >/dev/null 2>&1; then
    printf '%s\n' "$(jq -c '{valid:false, errors}' <<<"$parsed")"
    exit 1
  fi
  local spec
  spec="$(jq -c '.spec' <<<"$parsed")"

  # validate the projection with the canonical schema rules (unknown keys,
  # deps references, cycles, required fields) before writing anything
  tmp="$(mktemp /tmp/fleet-pipeline-convert.XXXXXX.json)"
  printf '%s\n' "$spec" > "$tmp"
  if ! "$LOOP_HELPER" spec-validate "$tmp" >/dev/null 2>&1; then
    printf '%s\n' "$("$LOOP_HELPER" spec-validate "$tmp" 2>/dev/null)"
    rm -f "$tmp"
    exit 1
  fi
  rm -f "$tmp"

  printf '%s\n' "$spec"            # stdout = machine mirror (JSON)
  log "convert: valid spec projection ($(jq -r '.slices | length' <<<"$spec") slices, $(jq -r '.checks | length' <<<"$spec") checks)"
  if [[ -n "$out_yaml" ]]; then
    jq -r "$YAML_EMIT_JQ" <<<"$spec" > "$out_yaml" || die "convert: yaml emit failed"
    printf -- '--- %s\n' "$out_yaml" >&2
    cat "$out_yaml" >&2
  fi
  if [[ -n "$out_json" ]]; then
    printf '%s\n' "$spec" > "$out_json" || die "convert: json-out write failed"
    log "convert: wrote $out_json"
  fi
}

# ---------------------------------------------------------------------------
# cmd_waves <spec.json>
# ---------------------------------------------------------------------------
cmd_waves() {
  [[ $# -eq 1 ]] || die "waves: exactly one spec JSON file required"
  local f="$1" parsed
  [[ -f "$f" ]] || die "waves: file not found: $f"
  spec_validate "$f" >/dev/null 2>&1 || { spec_validate "$f"; exit 1; }
  parsed="$(jq -c "$WAVES_JQ" "$f")" || die "waves: computation failed"
  if jq -e '.cycle == true' <<<"$parsed" >/dev/null 2>&1; then
    printf '%s\n' "$(jq -c '{valid:false, errors:["slices[].deps: cycle detected — deps must form a DAG"]}' <<<"{}")"
    exit 1
  fi
  printf '%s\n' "$parsed"
}

# ---------------------------------------------------------------------------
# cmd_integrate <spec.json> <shipper-status.json>
# ---------------------------------------------------------------------------
cmd_integrate() {
  [[ $# -eq 2 ]] || die "integrate: exactly <spec.json> <shipper-status.json> required"
  local spec="$1" status="$2" specids bad
  [[ -f "$spec" ]]   || die "integrate: file not found: $spec"
  [[ -f "$status" ]] || die "integrate: file not found: $status"
  spec_validate "$spec" >/dev/null 2>&1 || { spec_validate "$spec"; exit 1; }
  jq -e 'type == "array"' "$status" >/dev/null 2>&1 || die "integrate: shipper-status must be a JSON array"
  # shape check + known-slice check (deterministic guard against typos)
  bad="$(jq -c --argjson spec "$(jq -c . "$spec")" '
    ( [$spec.slices[].id] ) as $ids
    | [ .[] as $e
        | select( (($e | has("slice")) and ($e.slice|type)=="string" and ($e.slice|length)>0 and (($ids|index($e.slice)) != null)) | not )
        | "unknown slice in status: \($e.slice // "<missing>") (expected one of: \($ids|join(", ")))" ]
      + [ .[] as $e | select( (($e | has("branch")) and ($e.branch|type)=="string" and ($e.branch|length)>0) | not ) | "status entry for slice \($e.slice // "?") is missing a string branch" ]
      + [ .[] as $e | select( (($e | has("files")) and ($e.files|type)=="array") | not ) | "status entry for slice \($e.slice // "?") is missing a files array (may be empty)" ]
  ' "$status")"
  if [[ -n "$bad" && "$bad" != "[]" ]]; then
    printf '%s\n' "$(jq -nc --argjson e "$bad" '{valid:false, errors:$e}')"
    exit 1
  fi
  jq -c --argjson status "$(jq -c . "$status")" "$INTEGRATE_JQ" <<<"{}"
}

# ---------------------------------------------------------------------------
main() {
  local cmd="${1:-help}"
  shift || true
  case "$cmd" in
    convert)       cmd_convert "$@" ;;
    waves)         cmd_waves "$@" ;;
    integrate)     cmd_integrate "$@" ;;
    spec-validate) spec_validate "$@" ;;
    help|-h|--help) usage; exit 0 ;;
    *) die "unknown subcommand: $cmd (try: help)" ;;
  esac
}

main "$@"