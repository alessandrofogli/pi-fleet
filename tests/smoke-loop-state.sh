#!/usr/bin/env bash
#
# pi-fleet · gh-14 loop-state acceptance smoke — mechanical cycle bound, persisted
#
# Exercises the gh-14 additions to bin/fleet-loop-helper.sh against a SCRATCH
# state home (FLEET_STATE_HOME=/tmp/...): persistent per-loop state
# (<loopId>.loop.json now carries `rounds` + `verdict` on top of the T-019
# {cycle, maxCycles} counter), the live-group relaunch refusal (loop-guard
# against .wake-groups/) and the mechanically-surfaced round count in group
# labels (loop-label). Purely mechanical: no AI, no herdr, no repo.
#
# Acceptance fixtures (gh-14):
#   F  loop-record persists the CURRENT round's findings + verdict into
#      `rounds` (upsert, keyed by cycle); the TOP-LEVEL `verdict` is terminal
#      and is set ONLY at cycle == maxCycles (below the bound it stays empty);
#      refuses on an unstarted loop / bad verdict.
#   G  loop-guard refuses to (re)launch while a LIVE group with the same label
#      exists in .wake-groups/ (refused:"live-group") and refuses an
#      ALREADY-RECORDED round (refused:"round-done"); ok when the only live
#      group is a different round, and ok when nothing is live.
#   H  loop-label surfaces the round count mechanically: grp-<prefix>-r<N>
#      derived from the SAME counter loop-next bumps (missing loop -> r1).
#   I  loop-state now surfaces rounds + verdict (read-only, deterministic).
#
# Isolation: scratch FLEET_STATE_HOME in /tmp. Exit: 0 green / 1 failed /
# 2 missing prerequisites (jq).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
HELPER="$REPO_ROOT/bin/fleet-loop-helper.sh"
TS="$(date +%s)"
SCRATCH="/tmp/fleet-loop-state-smoke-$TS"
KEEP="${SMOKE_KEEP:-0}"

log()  { printf 'LSTATE [%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf 'LSTATE FAIL: %s\n' "$*" >&2; exit 1; }
die2() { printf 'LSTATE SKIP (exit 2): %s\n' "$*" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || die2 "jq not found in PATH (brew install jq)"
[[ -x "$HELPER" ]] || die "helper not found: $HELPER"

cleanup() {
  [[ "$KEEP" == "1" ]] && { log "SMOKE_KEEP=1: keeping $SCRATCH"; return 0; }
  rm -rf "$SCRATCH"
}
trap cleanup EXIT
mkdir -p "$SCRATCH/state"
export FLEET_STATE_HOME="$SCRATCH/state"

OK=0
pass() { OK=$((OK + 1)); log "  OK   $*"; }
fail() { log "  FAIL $*"; }

# ref: helper <cmd> ... → {rc} {stdout}
ref() {
  local rc out
  out="$(bash "$HELPER" "$@" 2>/dev/null)"
  rc=$?
  printf '%s\n%s\n' "$rc" "$out"
}

mkdir -p "$SCRATCH/findings"
printf '[{"id":"F1","severity":"BLOCKING","domain":"bash","location":"bin/x.sh:4","rule":"r","problem":"p"}]' \
  > "$SCRATCH/findings/f1.json"

# ================================================================== F ====
log "SCENARIO F — loop-record: persist round findings+verdict, terminal only at the bound"
bash "$HELPER" loop-init loop-f1 3 >/dev/null 2>&1
r="$(ref loop-record loop-f1 3 PASS "$SCRATCH/findings/f1.json")"
[[ "$(echo "$r" | head -1)" == "0" ]] \
  && jq -e '.ok==true and .cycle==1 and .verdict=="" and .roundVerdict=="PASS"' <(echo "$r" | tail -1) >/dev/null 2>&1 \
  && pass "F round 1 recorded (top-level verdict still empty below the bound)" \
  || fail "F round 1 record: $r"
jq -e '.rounds | length == 1 and .[0].cycle == 1 and .[0].verdict == "PASS" and (.[0].findings | length) == 1 and .[0].findings[0].id == "F1"' \
  "$SCRATCH/state/loop-f1.loop.json" >/dev/null 2>&1 \
  && pass "F rounds[] carries {cycle, verdict, findings} on disk" \
  || fail "F rounds[] content: $(jq -c . "$SCRATCH/state/loop-f1.loop.json" 2>/dev/null)"
# upsert: re-recording round 1 replaces, does not duplicate
bash "$HELPER" loop-record loop-f1 3 PASS >/dev/null 2>&1
[[ "$(jq '.rounds | length' "$SCRATCH/state/loop-f1.loop.json" 2>/dev/null)" == "1" ]] \
  && pass "F upsert: re-record does not duplicate round 1" \
  || fail "F upsert duplicated round 1"
# terminal verdict only at the bound: bump to 3 then record
bash "$HELPER" loop-next loop-f1 3 >/dev/null 2>&1
bash "$HELPER" loop-next loop-f1 3 >/dev/null 2>&1   # cycle 3
r3="$(ref loop-record loop-f1 3 FAILED_TO_CONVERGE)"
jq -e '.ok==true and .verdict=="FAILED_TO_CONVERGE"' <(echo "$r3" | tail -1) >/dev/null 2>&1 \
  && pass "F terminal verdict set ONLY at cycle == maxCycles" \
  || fail "F terminal verdict at the bound: $r3"
# unstarted + bad verdict refusal
u="$(ref loop-record loop-nope 3 PASS)"
[[ "$(echo "$u" | head -1)" == "1" ]] \
  && jq -e '.ok==false and .refused=="unstarted"' <(echo "$u" | tail -1) >/dev/null 2>&1 \
  && pass "F loop-record refuses an unstarted loop" || fail "F unstarted: $u"
b="$(ref loop-record loop-f1 3 BADVERDICT)"
[[ "$(echo "$b" | head -1)" == "2" ]] && pass "F loop-record refuses an invalid verdict (exit 2)" \
  || fail "F bad verdict accepted: $b"

# ================================================================== G ====
log "SCENARIO G — loop-guard: refuse relaunch while a live group with the same label exists"
bash "$HELPER" loop-init loop-g1 3 >/dev/null 2>&1
g="$(ref loop-guard loop-g1 pipeline)"     # no live group, no recorded round
[[ "$(echo "$g" | head -1)" == "0" ]] \
  && jq -e '.ok==true and .group=="grp-pipeline-r1"' <(echo "$g" | tail -1) >/dev/null 2>&1 \
  && pass "G guard ok when nothing live (group grp-pipeline-r1)" || fail "G clean guard: $g"
mkdir -p "$SCRATCH/state/.wake-groups"
printf '{"groupId":"grp-pipeline-r1","expected":2,"label":"grp-pipeline-r1","pending":["a","b"],"results":{}}' \
  > "$SCRATCH/state/.wake-groups/grp-pipeline-r1.json"
g2="$(ref loop-guard loop-g1 pipeline)"
[[ "$(echo "$g2" | head -1)" == "1" ]] \
  && jq -e '.ok==false and .refused=="live-group" and .group=="grp-pipeline-r1"' <(echo "$g2" | tail -1) >/dev/null 2>&1 \
  && pass "G LIVE group with the same label MECHANICALLY refuses the relaunch" \
  || fail "G live-group refusal: $g2"
# a live group of a DIFFERENT round is not a blocker
bash "$HELPER" loop-next loop-g1 3 >/dev/null 2>&1   # cycle 2
g3="$(ref loop-guard loop-g1 pipeline)"
[[ "$(echo "$g3" | head -1)" == "0" ]] \
  && jq -e '.ok==true and .group=="grp-pipeline-r2"' <(echo "$g3" | tail -1) >/dev/null 2>&1 \
  && pass "G live group of a DIFFERENT round does not block (r2 ok)" || fail "G different-round: $g3"
# an ALREADY-RECORDED round refuses too
bash "$HELPER" loop-record loop-g1 3 PASS >/dev/null 2>&1   # record round 2
g4="$(ref loop-guard loop-g1 pipeline)"
[[ "$(echo "$g4" | head -1)" == "1" ]] \
  && jq -e '.ok==false and .refused=="round-done" and .group=="grp-pipeline-r2"' <(echo "$g4" | tail -1) >/dev/null 2>&1 \
  && pass "G already-recorded round refuses (round-done)" || fail "G round-done: $g4"

# ================================================================== H ====
log "SCENARIO H — loop-label: surface the round count in the group label"
h1="$(bash "$HELPER" loop-label loop-h1 mypipe 2>/dev/null)"
jq -e '.ok==true and .cycle==1 and .group=="grp-mypipe-r1"' <<<"$h1" >/dev/null 2>&1 \
  && pass "H missing loop -> cycle 1 -> grp-mypipe-r1" || fail "H missing loop: $h1"
bash "$HELPER" loop-next loop-h1 3 >/dev/null 2>&1   # first call -> cycle 1
bash "$HELPER" loop-next loop-h1 3 >/dev/null 2>&1   # -> cycle 2
h2="$(bash "$HELPER" loop-label loop-h1 mypipe 2>/dev/null)"
jq -e '.ok==true and .cycle==2 and .group=="grp-mypipe-r2"' <<<"$h2" >/dev/null 2>&1 \
  && pass "H label tracks the SAME mechanical counter (r2 after loop-next)" || fail "H bumped: $h2"
bash "$HELPER" loop-next loop-h1 3 >/dev/null 2>&1   # -> cycle 3
h3="$(bash "$HELPER" loop-label loop-h1 mypipe 2>/dev/null)"
jq -e '.group=="grp-mypipe-r3"' <<<"$h3" >/dev/null 2>&1 \
  && pass "H label r3 at the bound" || fail "H r3: $h3"

# ================================================================== I ====
log "SCENARIO I — loop-state surfaces rounds + verdict (deterministic)"
bash "$HELPER" loop-record loop-h1 3 PASS >/dev/null 2>&1   # record round 3 (terminal)
s1="$(bash "$HELPER" loop-state loop-h1 2>/dev/null)"
s2="$(bash "$HELPER" loop-state loop-h1 2>/dev/null)"
jq -e '.cycle==3 and .maxCycles==3 and .verdict=="PASS" and (.rounds | length) == 1' <<<"$s1" >/dev/null 2>&1 \
  && pass "I loop-state surfaces rounds + terminal verdict" || fail "I loop-state: $s1"
[[ "$s1" == "$s2" ]] && pass "I loop-state read is deterministic (byte-identical)" \
  || fail "I nondeterministic read"

# ---------------------------------------------------------------- result ---
log "OUTCOME: $OK/15 acceptance checks green"
[[ "$OK" -ge 15 ]] || die "not all gh-14 loop-state checks passed ($OK/15)"
exit 0
