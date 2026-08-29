#!/usr/bin/env bash
#
# pi-fleet · T-015 helper smoke test — deterministic review-loop helpers
#
# Unit tests for bin/fleet-loop-helper.sh:
#   dedup     by (ID + location); same id different location kept
#   group     by review domain
#   partition hybrid (option c): parallel ONLY on disjoint files, sequential
#             otherwise, never mixing domains in one fixer
#   spec-validate  pipeline spec (docs/pipeline-spec.md schema)
# plus: determinism (same input -> identical output), severity filter,
# malformed/missing input tolerance, empty-input edge cases.
#
# Isolation: scratch fixtures in /tmp, real ~/.pi/fleet untouched.
# Usage:   bash tests/smoke-loop-helper.sh
# Exit:    0 green / 1 failed / 2 missing prerequisites
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
HELPER="$REPO_ROOT/bin/fleet-loop-helper.sh"
TS="$(date +%s)"
SCRATCH="/tmp/fleet-loop-helper-smoke-$TS"
KEEP="${SMOKE_KEEP:-0}"

log()  { printf 'HELPER [%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf 'HELPER FAIL: %s\n' "$*" >&2; exit 1; }
die2() { printf 'HELPER SKIP (exit 2): %s\n' "$*" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || die2 "jq not found in PATH (brew install jq)"
[[ -x "$HELPER" ]] || die "helper not found/executable: $HELPER"

cleanup() {
  [[ "$KEEP" == "1" ]] && { log "SMOKE_KEEP=1: keeping $SCRATCH"; return 0; }
  rm -rf "$SCRATCH"
}
trap cleanup EXIT
mkdir -p "$SCRATCH"

FAIL=0
check() { # check <name> <condition>
  if [[ "$2" == "OK" ]]; then printf '  OK   %s\n' "$1"
  else printf '  FAIL %s\n' "$1"; FAIL=1; fi
}
run() { # run <label> <expected-exit> <args...>  → captures stdout, sets OUT
  local label="$1" want="$2"; shift 2
  OUT="$( "$HELPER" "$@" 2>"$SCRATCH/err.log" )"
  local rc=$?
  if [[ "$rc" -eq "$want" ]]; then check "$label" OK
  else printf '  FAIL %s (exit %s, want %s)\n' "$label" "$rc" "$want"; FAIL=1; fi
}

# ------------------------------------------------------------------ fixtures
cat > "$SCRATCH/f1.json" <<'EOF'
{"findings":[
 {"id":"FINDING-SAMPLE-01","severity":"BLOCKING","domain":"SAMPLE","checklist":"SAMPLE-1: header comment","location":"src/shapes.sh:3","rule":"rule","problem":"problem","evidence":"ev","requiredFix":"rf","verification":"v"},
 {"id":"FINDING-SAMPLE-01","severity":"BLOCKING","domain":"SAMPLE","checklist":"SAMPLE-1: header comment","location":"src/shapes.sh:3","rule":"rule","problem":"problem","evidence":"ev","requiredFix":"rf","verification":"v"},
 {"id":"FINDING-SAMPLE-03","severity":"BLOCKING","domain":"SAMPLE","checklist":"SAMPLE-3: no TODO","location":"src/shapes.sh:4","rule":"rule","problem":"p","evidence":"e","requiredFix":"rf","verification":"v"},
 {"id":"FINDING-SAMPLE-04","severity":"BLOCKING","domain":"SAMPLE","checklist":"SAMPLE-4: documented functions","location":"src/shapes.sh:3, src/utils.sh:5","rule":"rule","problem":"p","evidence":"e","requiredFix":"rf","verification":"v"},
 {"id":"FINDING-OTHER-01","severity":"NON_BLOCKING","domain":"OTHER","checklist":"x","location":"src/utils.sh:9","rule":"rule","problem":"p","evidence":"e","requiredFix":"rf","verification":"v"},
 {"broken":true}
]}
EOF
# reviewer 2: overlapping finding (dup) + one new issue
cat > "$SCRATCH/f2.json" <<'EOF'
{"findings":[
 {"id":"FINDING-SAMPLE-04","severity":"BLOCKING","domain":"SAMPLE","checklist":"SAMPLE-4: documented functions","location":"src/shapes.sh:3, src/utils.sh:5","rule":"rule","problem":"p","evidence":"e","requiredFix":"rf","verification":"v"},
 {"id":"FINDING-SAMPLE-05","severity":"BLOCKING","domain":"SAMPLE","checklist":"SAMPLE-5","location":"src/shapes.sh:12","rule":"rule","problem":"p","evidence":"e","requiredFix":"rf","verification":"v"}
]}
EOF
cat > "$SCRATCH/spec-ok.json" <<'EOF'
{
  "scope": "fixture loop",
  "slices": [
    { "id": "core", "title": "Core", "impl_skills": [], "review_skills": ["sample-style-review"], "deps": [] },
    { "id": "cli", "title": "CLI", "impl_skills": [], "review_skills": [], "deps": ["core"] }
  ],
  "checks": [ { "name": "syntax", "cmd": "bash -n src/*.sh" } ]
}
EOF
cat > "$SCRATCH/spec-cycle.json" <<'EOF'
{
  "scope": "x",
  "slices": [
    { "id": "a", "title": "A", "impl_skills": [], "review_skills": [], "deps": ["b"] },
    { "id": "b", "title": "B", "impl_skills": [], "review_skills": [], "deps": ["a"] }
  ],
  "checks": []
}
EOF
cat > "$SCRATCH/spec-unknown.json" <<'EOF'
{ "scope": "x", "slices": [ { "id": "a", "bogus": 1 } ], "checks": [ { "name": "c", "cmd": "true", "extra": 2 } ], "nope": 3 }
EOF
printf '%s' '{"findings":[]}' > "$SCRATCH/empty.json"

# ------------------------------------------------------------------- dedup --
log "dedup: by (id + location)"
run "dedup single file, dup collapsed, malformed dropped" 0 dedup "$SCRATCH/f1.json"
OUT_DEDUP="$OUT"
[[ "$(jq length <<<"$OUT_DEDUP")" == "4" ]] || { printf '  FAIL dedup count (got %s want 4)\n' "$(jq length <<<"$OUT_DEDUP")"; FAIL=1; }
ids="$(jq -c '[.[].id]' <<<"$OUT_DEDUP")"
[[ "$ids" == '["FINDING-OTHER-01","FINDING-SAMPLE-01","FINDING-SAMPLE-03","FINDING-SAMPLE-04"]' ]] \
  || { printf '  FAIL dedup ids %s\n' "$ids"; FAIL=1; }
check "dedup: sorted by (id, location)" OK
run "dedup multiple reviewer files merged" 0 dedup "$SCRATCH/f1.json" "$SCRATCH/f2.json"
[[ "$(jq length <<<"$OUT")" == "5" ]] || { printf '  FAIL multi-file dedup count %s\n' "$(jq length <<<"$OUT")"; FAIL=1; }
run "dedup same id different location kept" 0 dedup "$SCRATCH/f2.json"
[[ "$(jq '[.[] | select(.id=="FINDING-SAMPLE-04")] | length' <<<"$OUT")" == "1" ]] || FAIL=1
check "dedup: FINDING-SAMPLE-04 (multi-file location) present once" OK
run "dedup missing file tolerated (empty output)" 0 dedup "$SCRATCH/nope.json"
[[ "$OUT" == "[]" ]] || { printf '  FAIL missing file tolerance %s\n' "$OUT"; FAIL=1; }
run "dedup empty findings" 0 dedup "$SCRATCH/empty.json"
[[ "$OUT" == "[]" ]] || FAIL=1
check "dedup: empty findings -> []" OK

# ------------------------------------------------------------------- group --
log "group: domain grouping"
run "group single file" 0 group "$SCRATCH/f1.json"
[[ "$(jq -r 'keys | join(",")' <<<"$OUT")" == "OTHER,SAMPLE" ]] \
  || { printf '  FAIL group keys %s\n' "$(jq -r 'keys | join(",")' <<<"$OUT")"; FAIL=1; }
check "group: sorted domain keys OTHER,SAMPLE" OK
[[ "$(jq '.SAMPLE | length' <<<"$OUT")" == "4" ]] || { printf '  FAIL group SAMPLE count\n'; FAIL=1; }
check "group: SAMPLE has 4 findings (dup preserved by design)" OK

# -------------------------------------------------------------- partition --
log "partition: hybrid (c) — parallel on disjoint files, sequential otherwise"
# fixture: 5 findings, files shapes.sh + utils.sh (SAMPLE-04 spans both),
#          OTHER-01 on utils.sh (cross-domain on a shared file)
run "partition blocking only" 0 partition --severity BLOCKING "$SCRATCH/f1.json"
[[ "$(jq -r '.findings' <<<"$OUT")" == "4" ]] || { printf '  FAIL partition blocking count %s\n' "$(jq -r '.findings' <<<"$OUT")"; FAIL=1; }
[[ "$(jq -r '.waves' <<<"$OUT")" == "1" ]] || { printf '  FAIL waves %s\n' "$(jq -r '.waves' <<<"$OUT")"; FAIL=1; }
[[ "$(jq -r '.batches | length' <<<"$OUT")" == "1" ]] || FAIL=1
check "partition: blocking-only -> 1 batch (SAMPLE), wave 1" OK
run "partition all (cross-domain on shared file -> chained waves)" 0 partition "$SCRATCH/f1.json"
[[ "$(jq -r '.waves' <<<"$OUT")" == "2" ]] || { printf '  FAIL all waves %s\n' "$(jq -r '.waves' <<<"$OUT")"; FAIL=1; }
[[ "$(jq -r '[.batches[].domain] | join(",")' <<<"$OUT")" == "OTHER,SAMPLE" ]] || FAIL=1  # group_by(.domain) sorts domains
w1="$(jq -r '.batches[0].wave' <<<"$OUT")"; w2="$(jq -r '.batches[1].wave' <<<"$OUT")"
[[ "$w1" != "$w2" ]] || { printf '  FAIL cross-domain shared file not sequential\n'; FAIL=1; }
check "partition: OTHER shares utils.sh -> different wave (sequential), single-domain batches" OK
cat > "$SCRATCH/disjoint.json" <<'EOF'
{"findings":[
 {"id":"A-01","severity":"BLOCKING","domain":"AAA","location":"src/a.sh:1","rule":"r","problem":"p","evidence":"e","requiredFix":"rf","verification":"v"},
 {"id":"B-01","severity":"BLOCKING","domain":"BBB","location":"src/b.sh:1","rule":"r","problem":"p","evidence":"e","requiredFix":"rf","verification":"v"}
]}
EOF
run "partition disjoint files -> same wave (parallel)" 0 partition "$SCRATCH/disjoint.json"
[[ "$(jq -r '.waves' <<<"$OUT")" == "1" && "$(jq -r '.batches | length' <<<"$OUT")" == "2" ]] \
  || { printf '  FAIL disjoint waves %s\n' "$(jq -r '.waves' <<<"$OUT")"; FAIL=1; }
check "partition: two disjoint-file batches in the SAME wave (parallel)" OK
run "partition empty" 0 partition "$SCRATCH/empty.json"
[[ "$OUT" == '{"findings":0,"batches":[],"waves":0}' ]] || FAIL=1
check "partition: empty -> no batches, no waves" OK
run "partition missing file" 0 partition "$SCRATCH/nope.json"
[[ "$(jq -r '.findings' <<<"$OUT")" == "0" ]] || FAIL=1
check "partition: missing file tolerated" OK

# -------------------------------------------------------------- determinism
log "determinism"
a="$("$HELPER" partition "$SCRATCH/f1.json" 2>/dev/null)"
b="$("$HELPER" partition "$SCRATCH/f1.json" 2>/dev/null)"
[[ "$a" == "$b" ]] || { printf '  FAIL partition not deterministic\n'; FAIL=1; }
check "partition: deterministic byte-identical" OK
c="$("$HELPER" dedup "$SCRATCH/f1.json" "$SCRATCH/f2.json" 2>/dev/null)"
d="$("$HELPER" dedup "$SCRATCH/f1.json" "$SCRATCH/f2.json" 2>/dev/null)"
[[ "$c" == "$d" ]] || FAIL=1
check "dedup: deterministic byte-identical" OK

# ------------------------------------------------------------ spec-validate
log "spec-validate"
run "spec-validate valid spec" 0 spec-validate "$SCRATCH/spec-ok.json"
[[ "$OUT" == '{"valid":true}' ]] || FAIL=1
check "spec-validate: valid -> true" OK
run "spec-validate cycle -> invalid" 1 spec-validate "$SCRATCH/spec-cycle.json"
[[ "$(jq -r '.valid' <<<"$OUT")" == "false" && "$(jq -r '.errors | join(",")' <<<"$OUT")" == *cycle* ]] || FAIL=1
check "spec-validate: cycle detected" OK
run "spec-validate unknown keys -> invalid" 1 spec-validate "$SCRATCH/spec-unknown.json"
errs="$(jq -r '.errors | join(" | ")' <<<"$OUT")"
[[ "$errs" == *"unknown top-level key(s): nope"* && "$errs" == *"slice has unknown key(s)"* && "$errs" == *"check has unknown key(s)"* ]] \
  || { printf '  FAIL unknown-key errors %s\n' "$errs"; FAIL=1; }
check "spec-validate: unknown keys rejected (slice, check, top-level)" OK

# ------------------------------------------------------------------ outcome
if [[ "$FAIL" -gt 0 ]]; then die "$FAIL check(s) failed — see FAIL lines above"; fi
log "OUTCOME: OK — loop helper: dedup (id+location), group, hybrid partition (disjoint->parallel, shared->sequential, single-domain), spec-validate, deterministic"
exit 0