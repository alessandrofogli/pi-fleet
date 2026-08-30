#!/usr/bin/env bash
#
# pi-fleet · T-019 pane-health watchdog acceptance smoke — fully headless
#
# Exercises bin/fleet-watch.sh (external watcher) + bin/fleet-relaunch.sh with
# a MOCKED herdr (a fake `herdr` binary in PATH serving a controlled agent list)
# and a recording launcher stub (FLEET_RELAUNCH_LAUNCHER). NO real herdr pane is
# ever touched, NO real ~/.pi/fleet: everything lives in /tmp scratch (state +
# repo + fakes). The kill is SIMULATED (fake herdr records tab/pane close) and
# the relaunch is recorded (fake launcher), exactly per the acceptance rule
# 'fixture-based, never kill a real live task in tests'.
#
# What this proves (T-019 acceptance fixtures):
#   A  hang detection: a running pane whose context (herdr `revision`, the
#      heartbeat — NOT the 'Working…' spinner) does not grow for >= bashTimeoutS
#      is classified `health: <id> bash-timeout` and the auto-steer is written
#      into the DURABLE inbox ('abort command + commit WIP') + delivered once.
#   B  kill+relaunch: when the steer is not ACKED within the kill window the
#      watcher exits `health: <id> relaunch` AFTER bin/fleet-relaunch.sh has
#      1) salvaged untracked files into the branch (WIP base = last commit),
#      2) written <id>.relaunch, 3) closed pane/tab (same teardown as the
#      launcher), 4) invoked launcher --resume (stub records it).
#   C  ack resets: an acked steer resets the timer — the next episode re-steers
#      (new seq) instead of killing (no relaunch: `relaunches` never fires).
#   D  pane-stale: an idle-but-static pane is `health: <id> pane-stale` after
#      the stale window (distinct reason; bash-timeout requires status working).
#   E  progress = alive: a growing revision is absorbed, never killed.
#   F  no false kills: needs_input and tasks without paneId are never touched.
#
# Isolation: scratch repo + state + PATH-shadowed herdr in /tmp. Real
# ~/.pi/fleet untouched. Exit: 0 green / 1 failed / 2 missing prerequisites.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
WATCHER="$REPO_ROOT/bin/fleet-watch.sh"
RELAUNCH="$REPO_ROOT/bin/fleet-relaunch.sh"
TS="$(date +%s)"
SCRATCH="/tmp/fleet-health-smoke-$TS"
STATE="$SCRATCH/state"
BIN="$SCRATCH/bin"
REPO="$SCRATCH/repo"
AGENTS="$SCRATCH/agents.json"
HERDR_LOG="$SCRATCH/herdr.log"
LAUNCHER_REC="$SCRATCH/launcher.rec"
KEEP="${SMOKE_KEEP:-0}"

log()  { printf 'HEALTH [%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf 'HEALTH FAIL: %s\n' "$*" >&2; exit 1; }
die2() { printf 'HEALTH SKIP (exit 2): %s\n' "$*" >&2; exit 2; }

command -v jq  >/dev/null 2>&1 || die2 "jq not found in PATH (brew install jq)"
command -v git >/dev/null 2>&1 || die2 "git not found in PATH"
[[ -x "$WATCHER" ]] || die "watcher not found: $WATCHER"
[[ -x "$RELAUNCH" ]] || die "relaunch script not found: $RELAUNCH"

cleanup() {
  [[ "$KEEP" == "1" ]] && { log "SMOKE_KEEP=1: keeping $SCRATCH"; return 0; }
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

mkdir -p "$STATE" "$BIN"   # BEFORE the fakes: the watcher must find OUR herdr in PATH

OK=0
pass() { OK=$((OK + 1)); log "  OK   $*"; }
fail() { log "  FAIL $*"; }

# -------------------------------------------------------------------- fakes --
# fake herdr: records every call; agent list serves $AGENTS; prompt/read/close ok.
cat > "$BIN/herdr" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_HERDR_LOG"
case "$*" in
  *" agent list"*)  cat "$FAKE_AGENTS" ;;
  *" agent prompt"*) echo '{"id":"cli:agent:prompt","result":{"ok":true}}' ;;
  *" agent read"*)  echo "transcript line" ;;
  *" tab close"*)   echo '{}' ;;
  *" pane close"*)  echo '{}' ;;
esac
exit 0
EOF
chmod +x "$BIN/herdr"

# fake launcher: records the --resume invocation (what the real launcher would run)
cat > "$BIN/fake-launcher" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LAUNCHER_REC"
exit 0
EOF
chmod +x "$BIN/fake-launcher"

export PATH="$BIN:$PATH"
export FAKE_HERDR_LOG="$HERDR_LOG"
export FAKE_AGENTS="$AGENTS"
export FAKE_LAUNCHER_REC="$LAUNCHER_REC"
export FLEET_RELAUNCH_LAUNCHER="$BIN/fake-launcher"
export FLEET_STATE_HOME="$STATE"

mkdir -p "$STATE" "$BIN"
: > "$HERDR_LOG"; : > "$LAUNCHER_REC"
# scratch task repo: the worktree the frozen task lives in (with a WIP branch)
mkdir -p "$REPO"
( cd "$REPO" && git init -q \
  && git config user.name "health-smoke" && git config user.email "health-smoke@localhost" \
  && git switch -q -c fleet/hang-001-slug \
  && echo base > a.txt && git add -A && git commit -qm "base fixture" ) \
  || die "setup repo failed"

# agents.json default: ONE agent, pane p1, working, revision 1 (static).
agent_fixture() { # revision status
  jq -nc --argjson r "$1" --arg s "$2" \
    '{id:"cli:agent:list",result:{agents:[{agent:"pi",agent_status:$s,pane_id:"p1",revision:$r,tab_id:"t1"}]}}' > "$AGENTS"
}

# per-scenario isolation: only the current task json, health state and logs survive.
fresh_state() {
  rm -f "$STATE"/*.json "$STATE"/*.relaunch
  rm -rf "$STATE/.health" "$STATE"/*.inbox
  rm -f "$LAUNCHER_REC" "$HERDR_LOG"
  : > "$LAUNCHER_REC"; : > "$HERDR_LOG"
}

task_state() { # id extra-fields...
  local id="$1"; shift
  local st
  st=$(( $(date +%s) - 40 ))000
  jq -nc --arg id "$id" --arg cwd "$REPO" --argjson st "$st" \
    '{id:$id,title:$id,project:$cwd,cwd:$cwd,state:"running",paneId:"p1",tabId:"t1",
      startedAt:$st,lastBeatAt:$st,doneAt:null,timeoutMs:21600000,bashTimeoutS:300,
      groupId:$id,groupSize:1,briefFile:"n/a"}' "$@" > "$STATE/$id.json"
}

# run watcher with health env; expects (grep) a line; bounded (~6s) so a benign
# run cannot hang the suite.
run_watcher() { # <expect-regex> [extra env assignments...]
  local expect="$1" out pid i
  local envs=("${@:2}")
  out="$SCRATCH/watcher.out"
  ( env "${envs[@]}" bash "$WATCHER" > "$out" 2>/dev/null ) &
  pid=$!
  for ((i = 0; i < 40; i++)); do
    if grep -Eq "$expect" "$out" 2>/dev/null; then
      kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
      return 0
    fi
    sleep 0.2
  done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  return 1
}

# ================================================================= A.1 ====
log "SCENARIO A1 — hang detection: static context -> bash-timeout auto-steer"
fresh_state
agent_fixture 1 working
task_state hang-a1
if run_watcher '^health: hang-a1 bash-timeout$' \
    FLEET_POLL=1 FLEET_HEALTH_BASH_TIMEOUT_S=1 FLEET_HEALTH_STALE_S=600; then
  pass "A1 classified health: hang-a1 bash-timeout"
else
  fail "A1 expected 'health: hang-a1 bash-timeout' (output: $(cat "$SCRATCH/watcher.out" 2>/dev/null | head -3))"
fi
SEQ1="$(jq -r '.p1Seq // ""' "$STATE/.health/hang-a1.last" 2>/dev/null || true)"
[[ -n "$SEQ1" ]] && pass "A1 watchdog recorded p1Seq=$SEQ1" || fail "A1 .health/hang-a1.last missing p1Seq"
INB="$STATE/hang-a1.inbox/$SEQ1.json"
if [[ -f "$INB" ]] && jq -e '.seq == '"$SEQ1"' and .acked == false' "$INB" >/dev/null 2>&1 \
   && jq -r '.message' "$INB" | grep -q 'T-019 health watchdog'; then
  pass "A1 durable inbox steer written (seq $SEQ1, acked false, message present)"
else
  fail "A1 inbox steer missing/malformed: $INB"
fi
grep -q 'agent prompt' "$HERDR_LOG" && pass "A1 steer delivered once (herdr agent prompt)" \
  || fail "A1 no immediate prompt delivery"

# ================================================================= A.2 ====
log "SCENARIO A2 — no ack: kill + relaunch (salvage WIP -> marker -> teardown -> resume)"
fresh_state
agent_fixture 1 working
task_state hang-a1
echo "untracked-work.txt" > "$REPO/untracked-work.txt"   # must be salvaged first
# two watcher cycles: the fresh episode re-steers, then the kill window elapses
run_watcher '^health: hang-a1 bash-timeout$' \
  FLEET_POLL=1 FLEET_HEALTH_BASH_TIMEOUT_S=1 FLEET_HEALTH_STALE_S=600 \
  && pass "A2 fresh-episode steer fired (seq $(jq -r '.p1Seq' "$STATE/.health/hang-a1.last" 2>/dev/null))" \
  || fail "A2 initial steer did not fire"
if run_watcher '^health: hang-a1 relaunch$' \
    FLEET_POLL=1 FLEET_HEALTH_KILL_S=1 FLEET_HEALTH_BASH_TIMEOUT_S=1 FLEET_HEALTH_STALE_S=600; then
  pass "A2 classified health: hang-a1 relaunch (kill window elapsed, no ack)"
else
  fail "A2 expected 'health: hang-a1 relaunch'"
fi
# relaunch is detached: give the stub a moment, then assert the sequence
for ((i = 0; i < 25; i++)); do
  [[ -s "$LAUNCHER_REC" ]] && break
  sleep 0.2
done
grep -q -- "--resume hang-a1" "$LAUNCHER_REC" && pass "A2 resume launcher invoked (--resume hang-a1)" \
  || fail "A2 launcher stub not invoked: $(cat "$LAUNCHER_REC" 2>/dev/null)"
grep -qE 'tab close|pane close' "$HERDR_LOG" && pass "A2 pane/tab teardown sent to herdr (simulated kill)" \
  || fail "A2 no herdr close calls"
PLAN="$STATE/hang-a1.relaunch"
if [[ -f "$PLAN" ]] && jq -e '.base | length > 0' "$PLAN" >/dev/null 2>&1; then
  pass "A2 relaunch plan written (base=$(jq -r '.base' "$PLAN" | cut -c1-8))"
else
  fail "A2 relaunch plan missing: $PLAN"
fi
# the salvage commit: untracked file committed BEFORE the kill (WIP base)
SALVAGE="$(git -C "$REPO" log --format=%s -1 2>/dev/null || true)"
if [[ "$SALVAGE" == *"WIP salvage before relaunch"* ]] \
   && git -C "$REPO" ls-files | grep -q untracked-work.txt; then
  pass "A2 untracked work salvaged into the branch (base = last WIP commit)"
else
  fail "A2 salvage commit missing: '$SALVAGE'"
fi

# ================================================================== B ====
log "SCENARIO B — ack resets: no kill, re-steer on the next episode"
fresh_state
agent_fixture 1 working
task_state hang-b1
run_watcher '^health: hang-b1 bash-timeout$' \
  FLEET_POLL=1 FLEET_HEALTH_BASH_TIMEOUT_S=1 FLEET_HEALTH_STALE_S=600 \
  && pass "B initial steer fired" \
  || fail "B initial steer did not fire"
SEQ="$(jq -r '.p1Seq // ""' "$STATE/.health/hang-b1.last" 2>/dev/null || true)"
if [[ -z "$SEQ" ]]; then
  fail "B no p1Seq recorded (no steer?)"
else
  : > "$STATE/hang-b1.inbox/$SEQ.acked"
fi
if run_watcher '^health: hang-b1 bash-timeout$' \
    FLEET_POLL=1 FLEET_HEALTH_BASH_TIMEOUT_S=1 FLEET_HEALTH_STALE_S=600 FLEET_HEALTH_KILL_S=1; then
  NEWSEQ="$(jq -r '.p1Seq // ""' "$STATE/.health/hang-b1.last" 2>/dev/null || true)"
  if [[ "$NEWSEQ" != "$SEQ" ]]; then
    pass "B ack reset the kill timer: re-steer (seq $SEQ -> $NEWSEQ), no relaunch"
  else
    fail "B re-steer had the same seq ($NEWSEQ)"
  fi
else
  fail "B expected a NEW steer after the ack (relaunch instead? output: $(cat "$SCRATCH/watcher.out" 2>/dev/null | head -3))"
fi
[[ ! -f "$STATE/hang-b1.relaunch" ]] && pass "B no relaunch plan written" || fail "B relaunch plan exists (acked should forbid the kill)"
grep -q -- "--resume hang-b1" "$LAUNCHER_REC" 2>/dev/null && fail "B resume launcher invoked (must not)" || pass "B no resume invocation"

# ================================================================== C ====
log "SCENARIO C — pane-stale: idle agent, static context -> distinct reason"
fresh_state
agent_fixture 1 idle
task_state hang-c1
run_watcher '^health: hang-c1 pane-stale$' \
  FLEET_POLL=1 FLEET_HEALTH_STALE_S=1 FLEET_HEALTH_BASH_TIMEOUT_S=600 \
  && pass "C classified health: hang-c1 pane-stale (idle, static)" \
  || fail "C expected 'health: hang-c1 pane-stale'"

# ================================================================== D ====
log "SCENARIO D — progress = alive: growing revision is absorbed, no kill"
fresh_state
agent_fixture 1 working
task_state hang-d1
out="$SCRATCH/d.out"
( env FLEET_POLL=1 FLEET_HEALTH_BASH_TIMEOUT_S=1 FLEET_HEALTH_STALE_S=1 \
    bash "$WATCHER" > "$out" 2>/dev/null ) &
pid=$!
# rev 1 -> 2 mid-run: context grows
sleep 0.8
agent_fixture 2 working
sleep 1.2
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
grep -qE '^health:' "$out" && fail "D false positive on growing context: $(cat "$out")" \
  || pass "D revision growth absorbed (no health line, no kill)"
[[ ! -d "$STATE/hang-d1.inbox" || -z "$(ls "$STATE/hang-d1.inbox" 2>/dev/null | grep -v handled)" ]] \
  && pass "D no steer written for a growing pane" || fail "D steer written for a growing pane"

# ================================================================== F ====
log "SCENARIO F — needs_input (and paneless tasks) are never killed"
fresh_state
agent_fixture 1 working
task_state hang-f1
jq '.state="needs_input"' "$STATE/hang-f1.json" > "$STATE/hang-f1.json.tmp" && mv "$STATE/hang-f1.json.tmp" "$STATE/hang-f1.json"
out="$SCRATCH/f.out"
( env FLEET_POLL=1 FLEET_HEALTH_BASH_TIMEOUT_S=1 FLEET_HEALTH_STALE_S=1 \
    bash "$WATCHER" > "$out" 2>/dev/null ) &
pid=$!
sleep 2
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
grep -qE '^health:' "$out" && fail "F health fired on needs_input" \
  || pass "F needs_input task untouched (no health line)"

# ---------------------------------------------------------------- result ---
log "OUTCOME: $OK/18 acceptance checks green"
[[ "$OK" -ge 18 ]] || die "not all health acceptance checks passed ($OK/18)"
exit 0