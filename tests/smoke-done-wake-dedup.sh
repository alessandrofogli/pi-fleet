#!/usr/bin/env bash
#
# pi-fleet · T-025 done-wake dedup smoke — fully headless
#
# Verifies the done-wake dedup contract of bin/fleet-watch.sh in an ISOLATED
# FLEET_STATE_HOME under /tmp (the real ~/.pi/fleet is NEVER touched):
#
#   A  wake-once: with a PERSISTENT <id>.done.json present, a bounded watch
#      loop emits `signal: <id>.done` exactly ONCE; subsequent polls absorb
#      and the .wake-queue stays FLAT (no flood — D1 hot-loop regression).
#   B  audit integrity: the record <id>.json is byte-identical before/after
#      the whole flood window (the watcher never touches the audit record).
#   C  consumed marker: removing <id>.done.json (what dispatch-cmd.sh
#      --cleanup / the launcher does after reading the answer) lets the watch
#      loop prune the per-record sentinel (.wake-done-<id>) — the event is
#      consumed, no wake is re-emitted for a gone marker.
#   D  re-fire once (delivery contract preserved): a FRESH <id>.done.json for
#      the same id (new dispatch / task completion) wakes the captain ONCE
#      again — the sentinel never permanently blocks an id.
#   E  regression: the needs-input channel (dispatch pair) still wakes exactly
#      `signal: <id>.needs-input` (same path smoke-dispatch.sh STEP B covers).
#   F  benign: a plain running record with NO marker is absorbed (no wake, no
#      queue growth, watcher keeps looping until the bounded kill).
#
# The bounded watch runs are SEQUENTIAL (the watcher is a singleton: two live
# runs would exit `watcher: healthy` without classifying). Each run either
# exits on its own (actionable) or is killed after a grace window (absorb);
# the EXIT trap releases the singleton lock before the next run.
#
# Prereqs: bash + jq only (no node/tsc). bash -n clean on itself + watcher.
# Exit: 0 green / 1 failed / 2 missing prerequisites.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
WATCHER="$REPO_ROOT/bin/fleet-watch.sh"
TS="$(date +%s)"
SCRATCH="/tmp/fleet-done-wake-smoke-$TS"
STATE="$SCRATCH/state"
KEEP="${SMOKE_KEEP:-0}"
POLL="${FLEET_POLL:-1}"
GRACE=3                     # absorb-window kill grace (s)

log() { printf 'DONE-WAKE [%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf 'DONE-WAKE FAIL: %s\n' "$*" >&2; exit 1; }
die2() { printf 'DONE-WAKE SKIP (exit 2): %s\n' "$*" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || die2 "jq not found in PATH (brew install jq)"
[[ -x "$WATCHER" ]] || die "watcher not found: $WATCHER"
bash -n "$0" 2>/dev/null || die "smoke-done-wake-dedup.sh does not pass bash -n (self-check)"
bash -n "$WATCHER" 2>/dev/null || die "bin/fleet-watch.sh does not pass bash -n"

cleanup() {
  [[ "$KEEP" == "1" ]] && { log "SMOKE_KEEP=1: keeping $SCRATCH"; return 0; }
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

mkdir -p "$STATE"
OK=0
pass() { OK=$((OK + 1)); log "  OK   $*"; }
fail() { log "  FAIL $*"; }

# ----------------------------------------------------------------- helpers --
# rlimit: bounded run of an arbitrary command (no `timeout` on macOS):
#   rlimit <secs> <out-file> cmd...  → exit code of the command.
rlimit() {
  local secs="$1" out="$2"
  shift 2
  local pid rc
  ( "$@" >"$out" 2>&1 ) &
  pid=$!
  for ((i = 0; i < secs * 10; i++)); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    return 124
  fi
  wait "$pid"
  return $?
}

# One bounded watcher pass over the isolated state. Returns:
#   0 + 'signal: <id>' on stdout when actionable (watcher self-exits)
#   124 when absorbing (killed after GRACE, lock released by EXIT trap)
watch_pass() {
  rlimit "$GRACE" "$SCRATCH/watch.out" env FLEET_STATE_HOME="$STATE" FLEET_POLL="$POLL" bash "$WATCHER"
  return $?
}
watch_emitted() { grep -q '^signal: ' "$SCRATCH/watch.out" 2>/dev/null; }
watch_emitted_signal() { grep -qx "$1" "$SCRATCH/watch.out" 2>/dev/null; }
queue_count() { find "$STATE/.wake-queue" -maxdepth 1 -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' '; }

# =================================================== A wake-once / flood ====
log "STEP A — persistent done.json wakes ONCE; queue stays flat"
jq -nc '{id:"T1",title:"T1",state:"done",kind:"ship"}' > "$STATE/T1.json"
AUDIT_BEFORE="$(cksum < "$STATE/T1.json")"
jq -nc '{status:"done",summary:"the answer"}' > "$STATE/T1.done.json"

# A1 — first pass: the done event is actionable
watch_pass; rc1=$?
if [[ "$rc1" -eq 0 ]] && watch_emitted_signal 'signal: T1.done'; then
  pass "A1 first pass emits 'signal: T1.done' (rc=0)"
else
  fail "A1 first pass expected rc=0 + 'signal: T1.done', got rc=$rc1 out=$(cat "$SCRATCH/watch.out" 2>/dev/null | head -1)"
fi
c1="$(queue_count)"
[[ "$c1" -eq 1 ]] && pass "A2 exactly 1 wake queued (count=$c1)" || fail "A2 expected 1 queued wake, got $c1"
[[ -f "$STATE/.wake-done-T1" ]] && pass "A3 per-record sentinel .wake-done-T1 created" || fail "A3 sentinel missing"

# A4 — flood window: 5 more bounded passes with the done.json STILL present
FLOOD=0
for i in 1 2 3 4 5; do
  sleep 0.3   # let the previous pass's EXIT trap release the lock
  watch_pass
  if watch_emitted; then
    FLOOD=$((FLOOD + 1))
    log "      flood: pass #$i re-emitted $(cat "$SCRATCH/watch.out" 2>/dev/null | tr -d '\r\n')"
  fi
done
c5="$(queue_count)"
if [[ "$FLOOD" -eq 0 && "$c5" -eq 1 ]]; then
  pass "A4 flood window (5 passes, done.json persisted): 0 re-emits, queue FLAT at $c5"
else
  fail "A4 flood: $FLOOD re-emits and/or queue grew to $c5 (was 1) — done-wake dedup broken"
fi

# ============================================ B audit record untouched ======
log "STEP B — audit record <id>.json untouched"
AUDIT_AFTER="$(cksum < "$STATE/T1.json")"
if [[ "$AUDIT_BEFORE" == "$AUDIT_AFTER" ]]; then
  pass "B T1.json byte-identical across flood window + wakes"
else
  fail "B T1.json was modified (watcher must never touch the audit record)"
fi

# ====================================== C marker consumed (--cleanup) =======
log "STEP C — marker consumed (dispatch-cmd.sh --cleanup behavior) → sentinel pruned"
rm -f "$STATE/T1.done.json"     # exactly what --cleanup does after reading the answer
sleep 0.3
watch_pass
if ! watch_emitted && [[ ! -f "$STATE/.wake-done-T1" ]]; then
  pass "C consumed marker: no re-wake, sentinel .wake-done-T1 pruned"
else
  fail "C expected absorb + sentinel pruned (emitted=$(watch_emitted && echo yes || echo no), sentinel=$([[ -f "$STATE/.wake-done-T1" ]] && echo present || echo gone))"
fi

# =================================== D re-fire once (fresh event, same id) ==
log "STEP D — fresh done.json for the same id wakes ONCE (delivery contract)"
# the previous wake was delivered and the queue acked (captain drain), then the
# marker was cleaned; a NEW event for the id must wake the captain again.
rm -f "$STATE/.wake-queue"/*.json 2>/dev/null || true
jq -nc '{status:"done",summary:"answer #2"}' > "$STATE/T1.done.json"
sleep 0.3
watch_pass; rcD=$?
if [[ "$rcD" -eq 0 ]] && watch_emitted_signal 'signal: T1.done' && [[ "$(queue_count)" -eq 1 ]]; then
  pass "D re-fire wakes 'signal: T1.done' once, queue at 1"
else
  fail "D expected one re-wake, got rc=$rcD out=$(cat "$SCRATCH/watch.out" 2>/dev/null | head -1) queue=$(queue_count)"
fi
# and immediately after, the loop goes flat again
sleep 0.3
watch_pass
[[ "$(queue_count)" -eq 1 ]] && ! watch_emitted && pass "D2 re-fired event stays flat (no double-wake)" || fail "D2 re-fired event re-emitted / queue grew"

# ======================================== E regression: needs-input pair ====
log "STEP E — regression: dispatch pair still wakes needs-input once"
jq -nc '{id:"T2",title:"T2",state:"running",kind:"dispatch"}' > "$STATE/T2.json"
jq -nc '{question:"fleet_status",taskState:"needs_input"}' > "$STATE/T2.needs-input.json"
sleep 0.3
watch_pass; rcE=$?
if [[ "$rcE" -eq 0 ]] && watch_emitted_signal 'signal: T2.needs-input'; then
  pass "E dispatch pair emits 'signal: T2.needs-input' once"
else
  fail "E expected needs-input wake, got rc=$rcE out=$(cat "$SCRATCH/watch.out" 2>/dev/null | head -1)"
fi
# consume T2's marker the way dispatch-cmd.sh --cleanup does (audit T2.json kept):
# the needs-input channel is intentionally NOT sentinel-deduped (T-025 scope =
# done-wakes; a stale needs-input is bounded by the captain start-cleanup).
rm -f "$STATE/T2.needs-input.json"

# ======================================== F benign record: absorb only =====
log "STEP F — plain running record (no marker) is absorbed"
jq -nc '{id:"T3",title:"T3",state:"running",kind:"ship"}' > "$STATE/T3.json"
Q_BEFORE="$(queue_count)"
sleep 0.3
watch_pass; rcF=$?
if [[ "$rcF" -eq 124 ]] && ! watch_emitted && [[ "$(queue_count)" -eq "$Q_BEFORE" ]]; then
  pass "F benign record absorbed (bounded kill rc=124, no wake, queue unchanged)"
else
  fail "F expected absorb (rc=124, no signal, queue $Q_BEFORE), got rc=$rcF queue=$(queue_count) out=$(cat "$SCRATCH/watch.out" 2>/dev/null | head -1)"
fi

# ---------------------------------------------------------------- result ---
log "OUTCOME: $OK/10 done-wake dedup checks green"
[[ "$OK" -ge 10 ]] || die "not all done-wake dedup smoke checks passed"
exit 0