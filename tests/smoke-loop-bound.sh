#!/usr/bin/env bash
#
# pi-fleet · T-019 loop-bound acceptance smoke — mechanical cycle refusal
#
# Exercises the deterministic cycle bound of bin/fleet-loop-helper.sh against a
# SCRATCH state home (FLEET_STATE_HOME=/tmp/...): the loop-state file
# ~/.pi/fleet/<loop>.loop.json is read/updated by the helper every cycle and the
# helper REFUSES (exit 1) beyond maxCycles and on early-exit verdict attempts.
# Purely mechanical: no AI, no herdr, no repo — the same guarantees the
# orchestrator template (templates/fleet-loop-orchestrator.brief.md) relies on.
#
# Acceptance fixtures (T-019):
#   A  fresh bound: loop-init creates {cycle:1, maxCycles:N}; refusing re-init.
#   B  mechanical entry: loop-next bumps 1→2→3 then REFUSES the 4th
#     (\`refused:"maxCycles"\`, exit 1) — a fourth cycle cannot start.
#   C  early-exit refusal: loop-final before cycle==maxCycles returns
#     \`refused:"early-exit"\` (exit 1) — a terminal verdict cannot be written
#     before the bound; at cycle==maxCycles it returns ok.
#   D  sanitization: a loopId with path separators/whitespace is neutralized
#     (no path traversal out of the state home) and unknown ids refuse.
#   E  determinism/idempotence: repeated same-state reads are byte-identical;
#     maxCycles shrinking below the current cycle also refuses.
#
# Isolation: scratch FLEET_STATE_HOME in /tmp. Exit: 0 green / 1 failed /
# 2 missing prerequisites (jq).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
HELPER="$REPO_ROOT/bin/fleet-loop-helper.sh"
TS="$(date +%s)"
SCRATCH="/tmp/fleet-loop-bound-smoke-$TS"
KEEP="${SMOKE_KEEP:-0}"

log()  { printf 'LBOUND [%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf 'LBOUND FAIL: %s\n' "$*" >&2; exit 1; }
die2() { printf 'LBOUND SKIP (exit 2): %s\n' "$*" >&2; exit 2; }

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

# ================================================================== A ====
log "SCENARIO A — loop-init: create the bound, refuse overwrite"
out="$(ref loop-init loop-a1 3)"
[[ "$(echo "$out" | head -1)" == "0" ]] \
  && jq -e '.ok==true and .cycle==1 and .maxCycles==3' <(echo "$out" | tail -1) >/dev/null 2>&1 \
  && pass "A loop-init created {cycle:1, maxCycles:3}" \
  || fail "A loop-init create: $out"
out2="$(ref loop-init loop-a1 3)"
[[ "$(echo "$out2" | head -1)" == "1" ]] \
  && jq -e '.ok==false and .refused=="exists"' <(echo "$out2" | tail -1) >/dev/null 2>&1 \
  && pass "A loop-init refuses to overwrite an existing bound" \
  || fail "A loop-init overwrite refusal: $out2"
[[ -f "$SCRATCH/state/loop-a1.loop.json" ]] && pass "A bound file on disk (loop-a1.loop.json)" \
  || fail "A bound file missing"

# ================================================================== B ====
log "SCENARIO B — loop-next: 1→2→3, then mechanical refusal of a 4th cycle"
n1="$(ref loop-next loop-b1 3)"; [[ "$(echo "$n1" | head -1)" == "0" ]] \
  && jq -e '.ok==true and .cycle==1' <(echo "$n1" | tail -1) >/dev/null 2>&1 \
  && pass "B missing bound → first cycle (cycle 1)" || fail "B first cycle: $n1"
n2="$(ref loop-next loop-b1 3)"; jq -e '.ok==true and .cycle==2' <(echo "$n2" | tail -1) >/dev/null 2>&1 \
  && pass "B cycle 2 entered" || fail "B cycle 2: $n2"
n3="$(ref loop-next loop-b1 3)"; jq -e '.ok==true and .cycle==3' <(echo "$n3" | tail -1) >/dev/null 2>&1 \
  && pass "B cycle 3 entered" || fail "B cycle 3: $n3"
n4="$(ref loop-next loop-b1 3)"
[[ "$(echo "$n4" | head -1)" == "1" ]] \
  && jq -e '.ok==false and .refused=="maxCycles" and .cycle==3 and .maxCycles==3' <(echo "$n4" | tail -1) >/dev/null 2>&1 \
  && pass "B 4th cycle MECHANICALLY refused (refused:maxCycles, exit 1)" \
  || fail "B 4th cycle refusal: $n4"
[[ "$(jq -r '.cycle // 0' "$SCRATCH/state/loop-b1.loop.json")" == "3" ]] \
  && pass "B cycle counter stays at 3 after refusal" || fail "B counter moved past the refusal"

# ================================================================== C ====
log "SCENARIO C — loop-final: early-exit refusal, verdict ok only at the bound"
f="$(ref loop-final loop-c1 3)"
[[ "$(echo "$f" | head -1)" == "1" ]] \
  && jq -e '.ok==false and .refused=="unstarted"' <(echo "$f" | tail -1) >/dev/null 2>&1 \
  && pass "C verdict before any cycle refused (unstarted)" || fail "C unstarted: $f"
bash "$HELPER" loop-next loop-c1 3 >/dev/null 2>&1
f2="$(ref loop-final loop-c1 3)"
[[ "$(echo "$f2" | head -1)" == "1" ]] \
  && jq -e '.ok==false and .refused=="early-exit" and .cycle==1' <(echo "$f2" | tail -1) >/dev/null 2>&1 \
  && pass "C early-exit verdict MECHANICALLY refused (cycle 1/3)" \
  || fail "C early-exit refusal: $f2"
bash "$HELPER" loop-next loop-c1 3 >/dev/null 2>&1
f3="$(ref loop-final loop-c1 3)"
[[ "$(echo "$f3" | head -1)" == "1" ]] \
  && jq -e '.ok==false and .refused=="early-exit" and .cycle==2' <(echo "$f3" | tail -1) >/dev/null 2>&1 \
  && pass "C early-exit verdict refused again (cycle 2/3)" || fail "C cycle 2: $f3"
bash "$HELPER" loop-next loop-c1 3 >/dev/null 2>&1   # now cycle 3
f4="$(ref loop-final loop-c1 3)"
[[ "$(echo "$f4" | head -1)" == "0" ]] \
  && jq -e '.ok==true and .cycle==3' <(echo "$f4" | tail -1) >/dev/null 2>&1 \
  && pass "C terminal verdict allowed ONLY at cycle == maxCycles (3/3)" \
  || fail "C final gate: $f4"

# ================================================================== D ====
log "SCENARIO D — sanitization + unknown ids (no path traversal)"
"$HELPER" loop-next 'a/b c.d..e' 2 >/dev/null 2>&1
[[ -f "$SCRATCH/state/a_b_c.d..e.loop.json" ]] \
  && pass "D loopId sanitized to [A-Za-z0-9._-] (a_b_c.d..e.loop.json)" \
  || fail "D sanitized file missing: $(ls "$SCRATCH/state" | grep loop || true)"
u="$(ref loop-state 'nope/x')"
[[ "$(echo "$u" | head -1)" == "1" ]] \
  && jq -e '.ok==false and .refused=="missing"' <(echo "$u" | tail -1) >/dev/null 2>&1 \
  && pass "D unknown loop id refuses (missing)" || fail "D unknown id: $u"
# the sanitized id's file must NOT be creatable outside the state home
[[ -e "/tmp/loop-bound-smoke-nope-x.loop.json" || -e "$SCRATCH/state/../../loop-bound-smoke-nope-x.loop.json" ]] \
  && fail "D path traversal attempt escaped the state home" || pass "D no path traversal out of the state home"

# ================================================================== E ====
log "SCENARIO E — determinism + shrinking maxCycles"
s1="$(bash "$HELPER" loop-state loop-c1 2>/dev/null)"
s2="$(bash "$HELPER" loop-state loop-c1 2>/dev/null)"
[[ "$s1" == "$s2" ]] && pass "E loop-state read is deterministic (byte-identical)" \
  || fail "E nondeterministic read: $s1 vs $s2"
shr="$(ref loop-next loop-c1 2)"   # file has cycle 3, maxCycles requested 2
[[ "$(echo "$shr" | head -1)" == "1" ]] \
  && jq -e '.ok==false and .refused=="maxCycles"' <(echo "$shr" | tail -1) >/dev/null 2>&1 \
  && pass "E shrinking maxCycles below the current cycle refuses" \
  || fail "E shrink refusal: $shr"

# ---------------------------------------------------------------- result ---
log "OUTCOME: $OK/17 acceptance checks green"
[[ "$OK" -ge 17 ]] || die "not all loop-bound acceptance checks passed ($OK/17)"
exit 0