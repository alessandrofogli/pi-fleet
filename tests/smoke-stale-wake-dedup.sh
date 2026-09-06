#!/usr/bin/env bash
#
# pi-fleet · issue-16/T-027 stale-wake dedup + throttle smoke — fully headless
#
# Verifies the stale-wake dedup contract of bin/fleet-watch.sh in an ISOLATED
# FLEET_STATE_HOME under /tmp (the real ~/.pi/fleet is NEVER touched):
#
#   A  first stale: a `running` task past its timeout emits `stale: <id> timeout`
#      ONCE (queue=1, throttle record .wake-stale-<id> written with count=1).
#      This is the issue-16 regression: before the fix every poll re-enqueued,
#      flooding the captain (~8k wakes).
#   B  dedup within interval: with the task STILL running (past timeout) and the
#      queue drained, the next poll is ABSORBED — no re-enqueue (min re-delivery
#      interval not elapsed).
#   C  re-deliver after interval: once the throttle `last` timestamp is past
#      FLEET_STALE_REDELIVER_MIN, the stale wake fires ONCE again (count=2) and
#      throttles again immediately after.
#   D  cap escalation: after FLEET_STALE_MAX deliveries the task is ESCALATED to
#      a single anchored `signal: <id> failed` wake (already_queued + the
#      .wake-stale-cap-<id> sentinel); the following polls are silent (no flood,
#      bounded stale stream).
#   E  regression: the `failed` dedup path still emits `signal: <id> failed` once.
#   F  benign: a plain `running` record with no timeout is absorbed (no wake).
#   G  regression: the done-wake dedup path still emits `signal: <id>.done` once.
#   H  prune: when the record <id>.json disappears, the stale throttle + cap
#      files (.wake-stale-<id>, .wake-stale-cap-<id>) are pruned (bounded set).
#
# Determinism: the re-delivery interval is NEVER tested via wall-clock sleep —
# the throttle file's `last` field is rewritten directly (|last| = now - Δ). The
# only sleeps are 0.3s lock-release gaps between sequential watcher runs (the
# watcher is a singleton).
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
SCRATCH="/tmp/fleet-stale-wake-smoke-$TS"
STATE="$SCRATCH/state"
KEEP="${SMOKE_KEEP:-0}"
POLL="${FLEET_POLL:-1}"
GRACE=3                     # absorb-window kill grace (s)
# Bounded test values: interval large enough to make B a certain absorb without
# wall-clock, cap large enough to leave one delivery of margin (STALE_MAX=3 →
# stale#1 (A), stale#2 (C), stale#3 (D1), then escalation (D2)).
REDELIVER_MIN=600           # watcher default; deterministic via manual `last`
STALE_MAX=3                 # escalation after 3 stale deliveries

log() { printf 'STALE-WAKE [%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf 'STALE-WAKE FAIL: %s\n' "$*" >&2; exit 1; }
die2() { printf 'STALE-WAKE SKIP (exit 2): %s\n' "$*" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || die2 "jq not found in PATH (brew install jq)"
[[ -x "$WATCHER" ]] || die "watcher not found: $WATCHER"
bash -n "$0" 2>/dev/null || die "smoke-stale-wake-dedup.sh does not pass bash -n (self-check)"
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

# gap: let the previous watcher run's EXIT trap release the singleton lock.
gap() { sleep 0.3; }

# One bounded watcher pass over the isolated state (STALE_MAX/interval test env).
# Returns: 0 + 'stale: ...' / 'signal: ...' on stdout when actionable (self-exit),
#          124 when absorbing (killed after GRACE, lock released by EXIT trap).
watch_pass() {
  rlimit "$GRACE" "$SCRATCH/watch.out" env \
    FLEET_STATE_HOME="$STATE" FLEET_POLL="$POLL" \
    FLEET_STALE_MAX="$STALE_MAX" \
    bash "$WATCHER"
  return $?
}
watch_emitted() { grep -q '^stale: \|^signal: ' "$SCRATCH/watch.out" 2>/dev/null; }
watch_emitted_stale() { grep -qx "stale: $1 timeout" "$SCRATCH/watch.out" 2>/dev/null; }
watch_emitted_signal() { grep -qx "$1" "$SCRATCH/watch.out" 2>/dev/null; }
queue_count() { find "$STATE/.wake-queue" -maxdepth 1 -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' '; }
drain_queue() { rm -f "$STATE/.wake-queue"/*.json 2>/dev/null || true; }
# Rewrite the throttle record with an arbitrary (past) delivery time: the ONLY
# deterministic way to cross the re-delivery interval without wall-clock sleep.
throttle_rewind() { # <tid> <count> <seconds-ago>
  local tid="$1" count="$2" ago="$3"
  local now_secs
  now_secs=$(date +%s 2>/dev/null || echo 0)
  jq -nc --argjson last "$((now_secs - ago))" --argjson c "$count" \
    '{last:$last, count:$c}' > "$STATE/.wake-stale-$tid" 2>/dev/null || return 1
}
# A running task JSON past its timeout (started 120s ago, timeout 1s).
mk_stale_task() { # <tid>
  local tid="$1" now_ms started
  now_ms=$(( $(date +%s 2>/dev/null || echo 0) * 1000 ))
  started=$((now_ms - 120000))
  jq -nc --arg id "$tid" --argjson st "$started" \
    '{id:$id, title:$id, state:"running", kind:"ship", startedAt:$st, timeoutMs:1000}' > "$STATE/$tid.json"
}

# ============================================= A first stale fires ONCE ======
log "STEP A — first stale detection: 'stale: S1 timeout' once, throttle count=1"
mk_stale_task S1
watch_pass; rcA=$?
gap
if [[ "$rcA" -eq 0 ]] && watch_emitted_stale S1 && [[ "$(queue_count)" -eq 1 ]]; then
  pass "A1 first stale emits 'stale: S1 timeout' (rc=0), queue=1"
else
  fail "A1 expected rc=0 + stale S1 + queue=1, got rc=$rcA out=$(cat "$SCRATCH/watch.out" 2>/dev/null | head -1) queue=$(queue_count)"
fi
if [ -f "$STATE/.wake-stale-S1" ] && [[ "$(jq -r '.count' "$STATE/.wake-stale-S1" 2>/dev/null)" == "1" ]]; then
  pass "A2 throttle record .wake-stale-S1 written with count=1"
else
  fail "A2 throttle record missing or count!=1 ($(cat "$STATE/.wake-stale-S1" 2>/dev/null))"
fi

# ========================== B dedup within interval (no re-enqueue) ==========
log "STEP B — task still stuck, queue drained: next poll is ABSORBED (interval)"
drain_queue
watch_pass; rcB=$?
gap
if [[ "$rcB" -eq 124 ]] && ! watch_emitted && [[ "$(queue_count)" -eq 0 ]]; then
  pass "B re-poll absorbed (rc=124, no stale, queue stays 0) — the issue-16 flood regression"
else
  fail "B expected absorb (rc=124), got rc=$rcB emitted=$(watch_emitted && echo yes || echo no) queue=$(queue_count)"
fi

# ======================== C re-deliver after the interval elapses ============
log "STEP C — throttle 'last' pushed past the interval → fires ONCE again (count=2)"
throttle_rewind S1 1 700 || die "throttle_rewind failed"
watch_pass; rcC=$?
gap
if [[ "$rcC" -eq 0 ]] && watch_emitted_stale S1 && [[ "$(queue_count)" -eq 1 ]] \
   && [[ "$(jq -r '.count' "$STATE/.wake-stale-S1" 2>/dev/null)" == "2" ]]; then
  pass "C after interval: fires 'stale: S1 timeout' once, count=2, queue=1"
else
  fail "C expected re-delivery (rc=0, stale S1, count=2), got rc=$rcC out=$(cat "$SCRATCH/watch.out" 2>/dev/null | head -1) count=$(jq -r '.count // "?"' "$STATE/.wake-stale-S1" 2>/dev/null)"
fi
# and immediately (no rewind) the throttle gates again
drain_queue
watch_pass; rcC2=$?
gap
if [[ "$rcC2" -eq 124 ]] && ! watch_emitted && [[ "$(queue_count)" -eq 0 ]]; then
  pass "C2 immediate re-poll after C absorbed again (interval gates)"
else
  fail "C2 expected absorb, got rc=$rcC2 emitted=$(watch_emitted && echo yes || echo no)"
fi

# ====================== D cap escalation → anchored failed wake =============
log "STEP D — count reaches FLEET_STALE_MAX=3 → stale#3, then escalation once"
throttle_rewind S1 2 700   # last delivery long ago, count=2 → next poll = #3 = MAX
watch_pass; rcD=$?
gap
if [[ "$rcD" -eq 0 ]] && watch_emitted_stale S1 && [[ "$(jq -r '.count' "$STATE/.wake-stale-S1" 2>/dev/null)" == "3" ]]; then
  pass "D1 delivery #3 fires stale once (count=3 = STALE_MAX reached)"
else
  fail "D1 expected stale delivery #3, got rc=$rcD out=$(cat "$SCRATCH/watch.out" 2>/dev/null | head -1) count=$(jq -r '.count // "?"' "$STATE/.wake-stale-S1" 2>/dev/null)"
fi
drain_queue
throttle_rewind S1 3 700   # already at max → escalate to failed
watch_pass; rcD2=$?
gap
if [[ "$rcD2" -eq 0 ]] && watch_emitted_signal 'signal: S1 failed' && [[ -f "$STATE/.wake-stale-cap-S1" ]] && [[ "$(queue_count)" -eq 1 ]]; then
  pass "D2 at cap: anchored 'signal: S1 failed' emitted once + .wake-stale-cap-S1 sentinel"
else
  fail "D2 expected 'signal: S1 failed' + cap sentinel, got rc=$rcD2 out=$(cat "$SCRATCH/watch.out" 2>/dev/null | head -1) cap=$([[ -f "$STATE/.wake-stale-cap-S1" ]] && echo yes || echo no)"
fi
# post-escalation: polls are SILENT (cap sentinel + already_queued) → no flood
drain_queue
watch_pass; rcD3=$?
gap
if [[ "$rcD3" -eq 124 ]] && ! watch_emitted && [[ "$(queue_count)" -eq 0 ]]; then
  pass "D3 post-escalation polls silent (no flood, queue 0)"
else
  fail "D3 expected silence, got rc=$rcD3 emitted=$(watch_emitted && echo yes || echo no) queue=$(queue_count)"
fi
rm -f "$STATE/S1.json" "$STATE/.wake-stale-S1" "$STATE/.wake-stale-cap-S1"

# =================================== E regression: failed path still wakes ==
log "STEP E — regression: a failed record emits 'signal: E1 failed' once"
jq -nc '{id:"E1",title:"E1",state:"failed",kind:"ship"}' > "$STATE/E1.json"
drain_queue
watch_pass; rcE=$?
gap
if [[ "$rcE" -eq 0 ]] && watch_emitted_signal 'signal: E1 failed' && [[ "$(queue_count)" -eq 1 ]]; then
  pass "E failed record emits 'signal: E1 failed' once"
else
  fail "E expected failed wake, got rc=$rcE out=$(cat "$SCRATCH/watch.out" 2>/dev/null | head -1) queue=$(queue_count)"
fi
rm -f "$STATE/E1.json"

# ========================================= F benign record: absorb only =====
log "STEP F — plain running record (no timeout) is absorbed"
drain_queue
jq -nc '{id:"F1",title:"F1",state:"running",kind:"ship"}' > "$STATE/F1.json"
Q_BEFORE="$(queue_count)"
watch_pass; rcF=$?
gap
if [[ "$rcF" -eq 124 ]] && ! watch_emitted && [[ "$(queue_count)" -eq "$Q_BEFORE" ]]; then
  pass "F benign running record absorbed (rc=124, no stale, queue unchanged)"
else
  fail "F expected absorb, got rc=$rcF emitted=$(watch_emitted && echo yes || echo no) queue=$(queue_count) before=$Q_BEFORE"
fi
rm -f "$STATE/F1.json"

# ============================== G regression: done-wake path still wakes ====
log "STEP G — regression: persisted done.json emits 'signal: G1.done' once"
jq -nc '{id:"G1",title:"G1",state:"done",kind:"ship"}' > "$STATE/G1.json"
jq -nc '{status:"done",summary:"answer"}' > "$STATE/G1.done.json"
drain_queue
watch_pass; rcG=$?
gap
if [[ "$rcG" -eq 0 ]] && watch_emitted_signal 'signal: G1.done' && [[ "$(queue_count)" -eq 1 ]]; then
  pass "G done marker emits 'signal: G1.done' once (T-025 dedup intact)"
else
  fail "G expected done wake, got rc=$rcG out=$(cat "$SCRATCH/watch.out" 2>/dev/null | head -1)"
fi
rm -f "$STATE/G1.json" "$STATE/G1.done.json" "$STATE/.wake-done-G1"

# ======================= H prune: throttle/cap files follow the record ======
log "STEP H — throttle + cap files pruned when the task record disappears"
mk_stale_task H1
drain_queue
watch_pass >/dev/null 2>&1            # fire the first stale → creates throttle
gap
drain_queue
throttle_rewind H1 1 700
watch_pass >/dev/null 2>&1            # stale#2 (count=2)
gap
drain_queue
throttle_rewind H1 2 700
watch_pass >/dev/null 2>&1            # stale#3 (count=3 = MAX)
gap
drain_queue
throttle_rewind H1 3 700
watch_pass >/dev/null 2>&1            # escalation → creates cap sentinel
gap
if [[ -f "$STATE/.wake-stale-H1" ]] && [[ -f "$STATE/.wake-stale-cap-H1" ]]; then
  rm -f "$STATE/H1.json"               # record gone (whatever the lifecycle)
  drain_queue
  watch_pass >/dev/null 2>&1           # prune pass
  gap
  if [[ ! -f "$STATE/.wake-stale-H1" ]] && [[ ! -f "$STATE/.wake-stale-cap-H1" ]]; then
    pass "H throttle + cap files pruned after record disappearance (bounded set)"
  else
    fail "H prune failed: throttle=$([[ -f "$STATE/.wake-stale-H1" ]] && echo present || echo gone) cap=$([[ -f "$STATE/.wake-stale-cap-H1" ]] && echo present || echo gone)"
  fi
else
  fail "H setup failed: throttle=$([[ -f "$STATE/.wake-stale-H1" ]] && echo present || echo gone) cap=$([[ -f "$STATE/.wake-stale-cap-H1" ]] && echo present || echo gone)"
fi

# ---------------------------------------------------------------- result ---
log "OUTCOME: $OK/12 stale-wake dedup checks green"
[[ "$OK" -ge 12 ]] || die "not all stale-wake dedup smoke checks passed"
exit 0