#!/usr/bin/env bash
#
# pi-fleet · T-017 pipeline helper unit smoke — converter, waves, integrate
#
# Deterministic assertions over bin/fleet-pipeline-helper.sh (no fleet
# layer, no LLM, no state): md→yaml converter (valid projection + strict
# line-numbered errors), DAG wave ordering (deps written in the tickets,
# blocking honored, no-deps -> one wave), hybrid integration plan
# (file-disjoint -> parallel, shared -> sequential, proof flag), spec
# validation passthrough, byte-determinism.
#
# Usage:    bash tests/smoke-pipeline-helper.sh
# Exit:     0 green / 1 failed / 2 missing prerequisites
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
H="$REPO_ROOT/bin/fleet-pipeline-helper.sh"
LH="$REPO_ROOT/bin/fleet-loop-helper.sh"
TICKETS="$REPO_ROOT/fixtures/pipeline-sample/tickets.md"
TS="$(date +%s)"
SCRATCH="/tmp/fleet-pipeline-helper-smoke-$TS"
KEEP="${SMOKE_KEEP:-0}"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1"; }
check() { if "$@" >/dev/null 2>&1; then ok "$*"; else bad "$*"; fi; }

command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq not found" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not found" >&2; exit 2; }
[[ -x "$H" ]]  || { echo "SKIP: helper not found: $H" >&2; exit 2; }
[[ -f "$TICKETS" ]] || { echo "SKIP: fixture tickets missing: $TICKETS" >&2; exit 2; }

mkdir -p "$SCRATCH"
cleanup() {
  [[ "$KEEP" == "1" ]] && { echo "SMOKE_KEEP=1: keeping $SCRATCH"; return 0; }
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

# ------------------------------------------------------------------ convert
echo "== convert: valid projection =="
"$H" convert "$TICKETS" --out "$SCRATCH/pipeline.yaml" --json-out "$SCRATCH/pipeline.spec.json" \
  > "$SCRATCH/convert.json" 2>/dev/null
[[ $? -eq 0 ]] && ok "convert exit 0" || bad "convert exit 0"
"$LH" spec-validate "$SCRATCH/pipeline.spec.json" | grep -q '{"valid":true}' \
  && ok "json mirror spec-valid" || bad "json mirror spec-valid"
jq -e '.slices | length == 2 and .[0].id == "lib" and .[1].id == "cli"' "$SCRATCH/pipeline.spec.json" >/dev/null \
  && ok "slices lib+cli projected" || bad "slices lib+cli projected"
jq -e '.slices[1].deps == ["lib"]' "$SCRATCH/pipeline.spec.json" >/dev/null \
  && ok "cli deps [lib] (written in tickets)" || bad "cli deps [lib]"
jq -e '.checks == [{"name":"syntax","cmd":"bash bin/check.sh syntax"}]' "$SCRATCH/pipeline.spec.json" >/dev/null \
  && ok "1 check projected" || bad "1 check projected"
grep -q '^scope: |-' "$SCRATCH/pipeline.yaml" && ok "yaml scope block" || bad "yaml scope block"
grep -q '^  - id: lib$' "$SCRATCH/pipeline.yaml" && ok "yaml slice lib" || bad "yaml slice lib"
grep -q "deps: \[lib\]" "$SCRATCH/pipeline.yaml" && ok "yaml cli deps [lib]" || bad "yaml cli deps [lib]"
grep -q "^checks:" "$SCRATCH/pipeline.yaml" && ok "yaml checks section" || bad "yaml checks section"

echo "== convert: strict errors (unknown/duplicates/pattern) =="
cat > "$SCRATCH/e-unknown-field.md" <<'EOF'
## scope
x
## slice lib
title: L
bogus_field: y
EOF
"$H" convert "$SCRATCH/e-unknown-field.md" 2>&1 | grep -q "unknown field 'bogus_field' (line 5)" \
  && ok "unknown slice field rejected w/ line" || bad "unknown slice field rejected w/ line"

cat > "$SCRATCH/e-unknown-section.md" <<'EOF'
## scope
x
## slice lib
title: L
## bogus
y
EOF
"$H" convert "$SCRATCH/e-unknown-section.md" 2>&1 | grep -q "unknown section '## bogus'" \
  && ok "unknown section rejected" || bad "unknown section rejected"

cat > "$SCRATCH/e-dup-id.md" <<'EOF'
## scope
x
## slice lib
title: L
## slice lib
title: D
EOF
"$H" convert "$SCRATCH/e-dup-id.md" 2>&1 | grep -q "duplicate id" \
  && ok "duplicate slice id rejected" || bad "duplicate slice id rejected"

cat > "$SCRATCH/e-bad-id.md" <<'EOF'
## scope
x
## slice go_nogo
title: Bad id
EOF
"$H" convert "$SCRATCH/e-bad-id.md" 2>&1 | grep -q "must match" \
  && ok "bad slice id pattern rejected" || bad "bad slice id pattern rejected"

cat > "$SCRATCH/e-no-scope.md" <<'EOF'
## slice lib
title: L
EOF
"$H" convert "$SCRATCH/e-no-scope.md" 2>&1 | grep -q "missing '## scope' section" \
  && ok "missing scope rejected" || bad "missing scope rejected"

cat > "$SCRATCH/e-no-title.md" <<'EOF'
## scope
x
## slice lib
deps: other
EOF
"$H" convert "$SCRATCH/e-no-title.md" 2>&1 | grep -q "missing required field 'title'" \
  && ok "missing title rejected" || bad "missing title rejected"

echo "== convert: invalid spec semantics (deps refs / cycles) =="
cat > "$SCRATCH/e-bad-dep.md" <<'EOF'
## scope
x
## slice lib
title: L
deps: missing
EOF
"$H" convert "$SCRATCH/e-bad-dep.md" 2>&1 | grep -q "deps: must reference existing slice ids" \
  && ok "deps -> unknown id rejected" || bad "deps -> unknown id rejected"
cat > "$SCRATCH/cycle.json" <<'EOF'
{"scope":"s","slices":[
 {"id":"x","title":"X","impl_skills":[],"review_skills":["r"],"deps":["y"]},
 {"id":"y","title":"Y","impl_skills":[],"review_skills":["r"],"deps":["x"]}],
 "checks":[]}
EOF

cat > "$SCRATCH/e-cycle.md" <<'EOF'
## scope
x
## slice lib
title: L
deps: cli
## slice cli
title: C
deps: lib
EOF
"$H" convert "$SCRATCH/e-cycle.md" 2>&1 | grep -q "cycle detected" \
  && ok "deps cycle rejected" || bad "deps cycle rejected"

echo "== convert: checks strictness =="
cat > "$SCRATCH/e-chk-dup.md" <<'EOF'
## scope
x
## slice lib
title: L
## checks
c1: bash -c true
c1: bash -c false
EOF
"$H" convert "$SCRATCH/e-chk-dup.md" 2>&1 | grep -q "duplicate name 'c1'" \
  && ok "duplicate check name rejected" || bad "duplicate check name rejected"

cat > "$SCRATCH/e-chk-space.md" <<'EOF'
## scope
x
## slice lib
title: L
## checks
bad name: bash -c true
EOF
"$H" convert "$SCRATCH/e-chk-space.md" 2>&1 | grep -q "must not contain whitespace" \
  && ok "whitespace check name rejected" || bad "whitespace check name rejected"

cat > "$SCRATCH/e-chk-no-colon.md" <<'EOF'
## scope
x
## slice lib
title: L
## checks
just a line without colon
EOF
"$H" convert "$SCRATCH/e-chk-no-colon.md" 2>&1 | grep -q "expected 'name: cmd'" \
  && ok "non-field checks line rejected" || bad "non-field checks line rejected"

# ---------------------------------------------------------------- waves
echo "== waves: DAG ordering (deps written in the tickets) =="
W="$("$H" waves "$SCRATCH/pipeline.spec.json")"
[[ "$W" == '{"total":2,"waves":[["lib"],["cli"]],"order":["lib","cli"],"cycle":false}' ]] \
  && ok "fixture waves [[lib],[cli]] (blocking honored)" \
  || bad "fixture waves [[lib],[cli]]: got $W"

cat > "$SCRATCH/diamond.json" <<'EOF'
{"scope":"s","slices":[
 {"id":"a","title":"A","impl_skills":[],"review_skills":["r"],"deps":[]},
 {"id":"b","title":"B","impl_skills":[],"review_skills":["r"],"deps":[]},
 {"id":"c","title":"C","impl_skills":[],"review_skills":["r"],"deps":["a"]},
 {"id":"d","title":"D","impl_skills":[],"review_skills":["r"],"deps":["a","b"]}],
 "checks":[{"name":"c1","cmd":"true"}]}
EOF
W="$("$H" waves "$SCRATCH/diamond.json")"
[[ "$W" == '{"total":4,"waves":[["a","b"],["c","d"]],"order":["a","b","c","d"],"cycle":false}' ]] \
  && ok "diamond waves [[a,b],[c,d]]" || bad "diamond waves: got $W"

cat > "$SCRATCH/nodeps.json" <<'EOF'
{"scope":"s","slices":[
 {"id":"x","title":"X","impl_skills":[],"review_skills":["r"],"deps":[]},
 {"id":"y","title":"Y","impl_skills":[],"review_skills":["r"],"deps":[]}],
 "checks":[]}
EOF
W="$("$H" waves "$SCRATCH/nodeps.json")"
[[ "$W" == '{"total":2,"waves":[["x","y"]],"order":["x","y"],"cycle":false}' ]] \
  && ok "no deps -> ONE parallel wave [x,y]" || bad "no deps -> one wave: got $W"

cat > "$SCRATCH/chain.json" <<'EOF'
{"scope":"s","slices":[
 {"id":"a","title":"A","impl_skills":[],"review_skills":["r"],"deps":[]},
 {"id":"b","title":"B","impl_skills":[],"review_skills":["r"],"deps":["a"]},
 {"id":"c","title":"C","impl_skills":[],"review_skills":["r"],"deps":["b"]}],
 "checks":[]}
EOF
W="$("$H" waves "$SCRATCH/chain.json")"
[[ "$W" == '{"total":3,"waves":[["a"],["b"],["c"]],"order":["a","b","c"],"cycle":false}' ]] \
  && ok "chain waves [[a],[b],[c]]" || bad "chain waves: got $W"

# ------------------------------------------------------------- integrate
echo "== integrate: hybrid plan (parallel disjoint / sequential shared) =="
cat > "$SCRATCH/integ-spec.json" <<'EOF'
{"scope":"s","slices":[
 {"id":"a","title":"A","impl_skills":[],"review_skills":["r"],"deps":[]},
 {"id":"b","title":"B","impl_skills":[],"review_skills":["r"],"deps":[]},
 {"id":"c","title":"C","impl_skills":[],"review_skills":["r"],"deps":[]}],
 "checks":[{"name":"c1","cmd":"true"}]}
EOF
cat > "$SCRATCH/st-disjoint.json" <<'EOF'
[{"slice":"a","branch":"fleet/t1-a","files":["src/a.sh","src/a.md"]},
 {"slice":"b","branch":"fleet/t2-b","files":["src/b.sh"]}]
EOF
I="$("$H" integrate "$SCRATCH/integ-spec.json" "$SCRATCH/st-disjoint.json")"
jq -e '.waves == 1 and .disjoint == true and (.batches | length) == 2' <<<"$I" >/dev/null \
  && ok "disjoint files -> single integration wave, proof flag" || bad "disjoint -> wave1: $(echo "$I" | jq -c)"
jq -e '.batches[0].files == ["src/a.md","src/a.sh"]' <<<"$I" >/dev/null && ok "batch files sorted+deduped" || bad "batch files sorted+deduped"

cat > "$SCRATCH/st-shared.json" <<'EOF'
[{"slice":"a","branch":"fleet/t1-a","files":["src/x.sh","src/w.sh"]},
 {"slice":"b","branch":"fleet/t2-b","files":["src/x.sh"]},
 {"slice":"c","branch":"fleet/t3-c","files":["src/z.sh"]}]
EOF
I="$("$H" integrate "$SCRATCH/integ-spec.json" "$SCRATCH/st-shared.json")"
jq -e '.waves == 2 and .disjoint == true and (.batches[0].wave == 1) and (.batches[1].wave == 2) and (.batches[2].wave == 1)' <<<"$I" >/dev/null \
  && ok "shared file -> sequential (b in wave 2), disjoint proof" || bad "shared -> sequential: $(echo "$I" | jq -c)"
# same-wave batches must be file-disjoint (the coloring invariant)
jq -e '.batches as $B | [ range(0; $B|length) as $i | range($i + 1; $B|length) as $j | select($B[$i].wave == $B[$j].wave) | select( any($B[$i].files[]; . as $f | (($B[$j].files | index($f)) != null)) ) ] | length == 0' <<<"$I" >/dev/null \
  && ok "same-wave batches file-disjoint (invariant)" || bad "same-wave batches file-disjoint"

cat > "$SCRATCH/st-empty.json" <<'EOF'
[{"slice":"a","branch":"fleet/t1-a","files":[]}]
EOF
I="$("$H" integrate "$SCRATCH/integ-spec.json" "$SCRATCH/st-empty.json")"
jq -e '.waves == 1 and (.batches | length) == 1 and .disjoint == true' <<<"$I" >/dev/null \
  && ok "zero-file slice tolerated" || bad "zero-file slice tolerated"

cat > "$SCRATCH/st-unknown.json" <<'EOF'
[{"slice":"nope","branch":"fleet/t1-x","files":["src/a.sh"]}]
EOF
"$H" integrate "$SCRATCH/integ-spec.json" "$SCRATCH/st-unknown.json" 2>&1 | grep -q "unknown slice in status: nope" \
  && ok "unknown slice in status rejected" || bad "unknown slice in status rejected"
"$H" integrate "$SCRATCH/integ-spec.json" "$SCRATCH/st-unknown.json" >/dev/null 2>&1
[[ $? -eq 1 ]] && ok "integrate error exit 1" || bad "integrate error exit 1"

cat > "$SCRATCH/st-nobranch.json" <<'EOF'
[{"slice":"lib","files":["src/a.sh"]}]
EOF
"$H" integrate "$SCRATCH/integ-spec.json" "$SCRATCH/st-nobranch.json" 2>&1 | grep -q "missing a string branch" \
  && ok "missing branch rejected" || bad "missing branch rejected"

echo "== determinism (byte-identical outputs) =="
A="$("$H" convert "$TICKETS" 2>/dev/null)"; B="$("$H" convert "$TICKETS" 2>/dev/null)"
[[ "$A" == "$B" ]] && ok "convert deterministic" || bad "convert deterministic"
W1="$("$H" waves "$SCRATCH/diamond.json")"; W2="$("$H" waves "$SCRATCH/diamond.json")"
[[ "$W1" == "$W2" ]] && ok "waves deterministic" || bad "waves deterministic"
I1="$("$H" integrate "$SCRATCH/integ-spec.json" "$SCRATCH/st-shared.json")"
I2="$("$H" integrate "$SCRATCH/integ-spec.json" "$SCRATCH/st-shared.json")"
[[ "$I1" == "$I2" ]] && ok "integrate deterministic" || bad "integrate deterministic"

echo "== spec-validate passthrough =="
"$LH" spec-validate "$SCRATCH/pipeline.spec.json" | grep -q '{"valid":true}' \
  && ok "spec-validate valid" || bad "spec-validate valid"
"$LH" spec-validate "$SCRATCH/cycle.json" 2>/dev/null | grep -q '"valid":false' \
  && ok "spec-validate rejects cycle" || bad "spec-validate rejects cycle"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]