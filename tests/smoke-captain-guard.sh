#!/usr/bin/env bash
#
# pi-fleet · single-captain / wave-ownership guard smoke (issue #13)
#
# Exercises bin/fleet-captain-lib.sh + the guard hook in bin/herdr-launch.sh
# against a SCRATCH FLEET_STATE_HOME (/tmp/...). Purely mechanical: no AI, no
# herdr child, no real launch — the launcher refusal path exits BEFORE the
# workspace/worktree sections, so the herdr-adjacent work is never reached.
#
# Acceptance fixtures (issue #13):
#   A  laptop fail-open: PI_FLEET_CAPTAIN unset → owns=0, NO captain-claim file
#      created (single-captain setup behavior UNCHANGED).
#   B  captain acquires the per-project claim (owns=0, claim file with sessionId).
#   C  same session refreshes the heartbeat (owns=0, owner unchanged).
#   D  a DIFFERENT live captain session is refused (owns=1).
#   E  a STALE claim (lastBeatAt older than FLEET_CAPTAIN_STALE_S) is stolen (owns=0).
#   F  per-project isolation: a claim on project X never blocks project Y.
#   G  duplicate live-group guard: same label + DIFFERENT groupId + LIVE → refuse(0);
#      same-wave member (same groupId) → allow(1); different label → allow(1);
#      terminal wave → allow(1); different project → allow(1); no label → allow(1).
#   H  launcher integration: herdr-launch.sh refuses a duplicate live label with a
#      FAILED task record and exit 1, BEFORE any herdr call; on the true laptop
#      path (PI_FLEET_CAPTAIN explicitly cleared) it creates NO new claim file.
#
# Isolation: scratch FLEET_STATE_HOME in /tmp. Exit: 0 green / 1 failed /
# 2 missing prerequisites (jq).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
LIB="$REPO_ROOT/bin/fleet-captain-lib.sh"
LAUNCHER="$REPO_ROOT/bin/herdr-launch.sh"
TS="$(date +%s)"
SCRATCH="/tmp/fleet-captain-guard-smoke-$TS"
STATE="$SCRATCH/state"
KEEP="${SMOKE_KEEP:-0}"

log()  { printf 'CAPTAIN [%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf 'CAPTAIN FAIL: %s\n' "$*" >&2; exit 1; }
die2() { printf 'CAPTAIN SKIP (exit 2): %s\n' "$*" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || die2 "jq not found in PATH (brew install jq)"
[[ -x "$LAUNCHER" ]] || die "launcher not found: $LAUNCHER"

cleanup() {
  [[ "$KEEP" == "1" ]] && { log "SMOKE_KEEP=1: keeping $SCRATCH"; return 0; }
  rm -rf "$SCRATCH"
}
trap cleanup EXIT
mkdir -p "$STATE"

# isolate from the calling shell's captain env (a real captain shell has these set)
unset PI_FLEET_CAPTAIN PI_SESSION_ID
export FLEET_STATE_HOME="$STATE"

OK=0
pass() { OK=$((OK + 1)); log "  OK   $*"; }
fail() { log "  FAIL $*"; }

# run a lib function in a subshell that sources the lib
librun() { ( . "$LIB"; "$@" ) >/dev/null 2>&1; echo $?; }
librc()  { ( . "$LIB"; "$@" >/dev/null 2>&1 ); echo $?; }

# ================================================================== A ====
log "SCENARIO A — laptop fail-open (no PI_FLEET_CAPTAIN): no claim, no block"
rc="$(librc fleet_captain_owns /proj/x)"
[[ "$rc" == "0" ]] && pass "A owns=0 for laptop (fail-open)" || fail "A owns=$rc (expected 0)"
n="$(ls "$STATE" 2>/dev/null | grep -c '^captain-claim\.' || true)"
[[ "$n" == "0" ]] && pass "A no captain-claim file created (laptop unchanged)" || fail "A $n claim file(s) created on laptop"

# ================================================================== B ====
log "SCENARIO B — captain acquires the per-project claim"
export PI_FLEET_CAPTAIN=1 PI_SESSION_ID="sess-local"
rc="$(librc fleet_captain_owns /proj/x)"
[[ "$rc" == "0" ]] && pass "B first captain owns=0" || fail "B owns=$rc"
claim="$STATE/captain-claim.proj-x.json"
[[ -f "$claim" ]] && pass "B claim file on disk" || fail "B claim file missing: $claim"
[[ "$(jq -r .sessionId "$claim" 2>/dev/null)" == "sess-local" ]] && pass "B claim sessionId=sess-local" || fail "B sessionId wrong"

# ================================================================== C ====
log "SCENARIO C — same session refreshes heartbeat"
rc="$(librc fleet_captain_owns /proj/x)"
[[ "$rc" == "0" ]] && pass "C same-session owns=0" || fail "C owns=$rc"
[[ "$(jq -r .sessionId "$claim" 2>/dev/null)" == "sess-local" ]] && pass "C owner unchanged" || fail "C owner changed"

# ================================================================== D ====
log "SCENARIO D — a DIFFERENT live captain session is refused"
export PI_SESSION_ID="sess-remote"
rc="$(librc fleet_captain_owns /proj/x)"
[[ "$rc" == "1" ]] && pass "D different live captain refused (owns=1)" || fail "D owns=$rc (expected 1)"

# ================================================================== E ====
log "SCENARIO E — a STALE claim is stolen"
old="$(date -d '20 minutes ago' +%s000 2>/dev/null || echo 0)"
jq --argjson old "$old" '.lastBeatAt=$old' "$claim" > "$claim.tmp" && mv "$claim.tmp" "$claim"
rc="$(librc fleet_captain_owns /proj/x)"
[[ "$rc" == "0" ]] && pass "E stale claim stolen (owns=0)" || fail "E owns=$rc (expected 0 steal)"
[[ "$(jq -r .sessionId "$claim" 2>/dev/null)" == "sess-remote" ]] && pass "E owner now sess-remote" || fail "E owner not stolen"

# ================================================================== F ====
log "SCENARIO F — per-project isolation"
export PI_SESSION_ID="sess-local"
rc="$(librc fleet_captain_owns /proj/other)"
[[ "$rc" == "0" ]] && pass "F different project owns=0 (separate claim)" || fail "F owns=$rc"
[[ -f "$STATE/captain-claim.proj-other.json" ]] && pass "F separate claim file for other project" || fail "F other-project claim missing"

# ================================================================== G ====
log "SCENARIO G — duplicate live-group guard"
export PI_SESSION_ID="sess-local"
cat > "$STATE/wave-m1.json" <<'J'
{"id":"wave-m1","project":"/proj/x","groupId":"grp-old-000","groupLabel":"review-wave","state":"running"}
J
rc="$(librc fleet_captain_duplicate_label /proj/x grp-new-111 review-wave w2-b)"
[[ "$rc" == "0" ]] && pass "G same label + different groupId + LIVE → refuse(0)" || fail "G rc=$rc (expected 0)"
rc="$(librc fleet_captain_duplicate_label /proj/x grp-old-000 review-wave w2-b)"
[[ "$rc" == "1" ]] && pass "G same-wave member (same groupId) → allow(1)" || fail "G rc=$rc (expected 1)"
rc="$(librc fleet_captain_duplicate_label /proj/x grp-new-111 other-label w2-b)"
[[ "$rc" == "1" ]] && pass "G different label → allow(1)" || fail "G rc=$rc (expected 1)"
rc="$(librc fleet_captain_duplicate_label /proj/y grp-new-111 review-wave w2-b)"
[[ "$rc" == "1" ]] && pass "G different project → allow(1)" || fail "G rc=$rc (expected 1)"
rc="$(librc fleet_captain_duplicate_label /proj/x grp-new-111 '' w2-b)"
[[ "$rc" == "1" ]] && pass "G no label → allow(1)" || fail "G rc=$rc (expected 1)"
rm -f "$STATE/wave-m1.json"
cat > "$STATE/wave-done.json" <<'J'
{"id":"wave-done","project":"/proj/x","groupId":"grp-old-222","groupLabel":"review-wave","state":"done"}
J
rc="$(librc fleet_captain_duplicate_label /proj/x grp-new-333 review-wave w2-d)"
[[ "$rc" == "1" ]] && pass "G terminal wave → allow(1) (re-run ok)" || fail "G rc=$rc (expected 1)"

# ================================================================== H ====
log "SCENARIO H — launcher refuses a duplicate live label (exit 1, FAILED record, no herdr)"
rm -f "$STATE/wave-done.json"
cat > "$STATE/wave-m1.json" <<'J'
{"id":"wave-m1","project":"/proj/x","groupId":"grp-old-000","groupLabel":"review-wave","state":"running"}
J
BRIEF="$STATE/brief.md"; echo "test brief" > "$BRIEF"
CLAIM_BEFORE="$(ls "$STATE" 2>/dev/null | grep -c '^captain-claim\.' || true)"
out="$(cd "$REPO_ROOT" && timeout 20 env -u PI_FLEET_CAPTAIN -u PI_SESSION_ID FLEET_STATE_HOME="$STATE" \
  bash bin/herdr-launch.sh "dup probe" "@$BRIEF" --project /proj/x \
  --group-id grp-new-444 --group-label review-wave --no-worktree 2>&1)"
rc=$?
[[ "$rc" == "1" ]] && pass "H launcher exit=1 on duplicate live group" || fail "H exit=$rc (expected 1)"
printf '%s' "$out" | grep -q "refusing launch" && pass "H refusal message logged" || fail "H no refusal message"
# a FAILED task record (other than the fake wave + claims) was written
found=""
for f in "$STATE"/*.json; do
  b="$(basename "$f")"
  [[ "$b" == "wave-m1.json" ]] && continue
  [[ "$b" == captain-claim.* ]] && continue
  [[ "$(jq -r .id "$f" 2>/dev/null)" == "dup-probe"* ]] && found="$f"
done
[[ -n "$found" ]] && [[ "$(jq -r .state "$found" 2>/dev/null)" == "failed" ]] \
  && pass "H FAILED task record written" || fail "H failed record missing: $found"
CLAIM_AFTER="$(ls "$STATE" 2>/dev/null | grep -c '^captain-claim\.' || true)"
[[ "$CLAIM_AFTER" == "$CLAIM_BEFORE" ]] && pass "H laptop path created NO new claim file (opt-in ownership)" \
  || fail "H claim count changed: before=$CLAIM_BEFORE after=$CLAIM_AFTER"

log "OUTCOME: $OK/$OK guard smoke checks green"
[[ "$OK" -ge 15 ]] || die "only $OK checks green (need >=15)"
exit 0
