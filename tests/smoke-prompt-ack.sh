#!/usr/bin/env bash
#
# pi-fleet · T-029 native-initial-request smoke — fully headless
#
# Drives the REAL bin/herdr-launch.sh with a MOCKED herdr + MOCKED treehouse
# (PATH shadowing — no real pane, daemon or worktree is ever touched) and an
# ISOLATED FLEET_STATE_HOME under /tmp (the real ~/.pi/fleet is NEVER touched).
#
# Contract under test (T-029): the CHILD_PROMPT is delivered as pi's NATIVE
# initial request — `agent start` carries `@<prompt-file>` in its argv and pi
# prompts its session before the main loop. The launcher NEVER calls
# `agent prompt` for the brief, so the delivery CANNOT be lost and there is no
# consumption-ACK/re-send machinery anymore. What remains is a fail-soft
# residual wait for the child to leave `idle`; a truly empty/frozen pane is
# caught by the §7 done-wait liveness gate (agent_alive), as before.
#
#   A  nogrow + pane dies — the child NEVER leaves idle / never grows and the
#      agent then DISAPPEARS from `agent list`: the residual wait logs its
#      fail-soft message (NO re-send, NO fail-fast), the done-wait liveness
#      gate trips → launcher exits 1, state record failed with the liveness
#      reason, tab+pane closed, worktree released.
#   B  grow (status)  — the child flips agent.get → working right after start:
#      the residual wait passes at the FIRST poll, launcher logs the native
#      delivery lines, task completes done with exactly ONE start and ZERO
#      `agent prompt`.
#   C  grow (session) — the child only grows its session file
#      (~/.pi/agent/sessions/<encoded-cwd>/, agent state stays idle): the
#      residual wait still passes via the session-file signal, done.
#   D  baseline       — static source checks: ZERO `agent prompt` CALLS left in
#      the launcher (only comments), `agent start` argv carries `@$PROMPT_PATH`,
#      and the CHILD_PROMPT is materialized to the prompt file.
#
# Real herdr/treehouse are shadowed by mocks at $SCRATCH/bin (see the mock
# headers); the launcher env knobs (FLEET_STARTUP_WAIT_TRIES/SLEEP) drive the
# bounded residual window down so the headless run stays fast.
#
# Prereqs: bash + jq only (no node/tsc, no herdr daemon).
# Exit: 0 green / 1 failed / 2 missing prerequisites.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
LAUNCHER="$REPO_ROOT/bin/herdr-launch.sh"
TS="$(date +%s)"
SCRATCH="/tmp/fleet-prompt-ack-$TS"
STATE="$SCRATCH/state"
PROJ="$SCRATCH/proj"
WT="$SCRATCH/wt"
HOME_DIR="$SCRATCH/home"
MOCK_BIN="$SCRATCH/bin"
KEEP="${SMOKE_KEEP:-0}"

log() { printf 'ACK [%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf 'ACK FAIL: %s\n' "$*" >&2; exit 1; }
die2() { printf 'ACK SKIP (exit 2): %s\n' "$*" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || die2 "jq not found in PATH (brew install jq)"
[[ -f "$LAUNCHER" ]] || die "launcher not found: $LAUNCHER"
bash -n "$0" 2>/dev/null || die "smoke-prompt-ack.sh does not pass bash -n (self-check)"
bash -n "$LAUNCHER" 2>/dev/null || die "bin/herdr-launch.sh does not pass bash -n"

cleanup() {
  [[ "$KEEP" == "1" ]] && { log "SMOKE_KEEP=1: keeping $SCRATCH"; return 0; }
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

mkdir -p "$STATE/tasks" "$PROJ" "$WT" "$HOME_DIR/.pi/agent/sessions" "$MOCK_BIN"

OK=0
pass() { OK=$((OK + 1)); log "  OK   $*"; }
fail() { log "  FAIL $*"; }

# ----------------------------------------------------------------- mocks ----
cat > "$MOCK_BIN/herdr" <<'EOF'
#!/usr/bin/env bash
# Mock herdr CLI for the T-029 smoke — NEVER touches the real herdr daemon.
# Behavior driven by env (set by the test per run):
#   MOCK_MODE           grow | nogrow | sessionfile
#   MOCK_AGENT_STATE    path to the fake agent JSON (the mock owns/updates it)
#   MOCK_RECORD         append "MOCK <cmd> [args]" per call (cleanup assertions)
#   MOCK_STARTED        touched by `agent start` (ordering: the START call is
#                       the boundary — growth signals fire only AFTER start)
#   MOCK_GROW_DONE      one-shot stamp: the FIRST post-start `agent get`
#                       triggers the grow (status flip / session append)
#   MOCK_SESSION_FILE   session file the mock appends to on growth (sessionfile)
#   MOCK_KILL_FILE      when this file EXISTS, `agent list` reports NO agents
#                       (simulates the child/pane disappearing)
set -u
[[ "$1" == "--session" ]] && shift 2
cmd="$1"; shift
{
  printf 'MOCK %s' "$cmd"
  printf ' %s' "$@"
  printf '\n'
} >> "${MOCK_RECORD:?}"

case "$cmd" in
  workspace)
    case "${1:-}" in
      list)   echo '{"result":{"workspaces":[{"label":"fleet","workspace_id":"w9"}]}}' ;;
      create) echo '{"result":{"workspace":{"workspace_id":"w9"}}}' ;;
    esac ;;
  tab)
    case "${1:-}" in
      create) echo '{"result":{"tab":{"tab_id":"t1"},"root_pane":{"pane_id":"p1"}}}' ;;
      close)  echo '{"ok":true}' ;;
    esac ;;
  pane) echo '{"ok":true}' ;;
  agent)
    sub="${1:-}"; shift
    case "$sub" in
      start)
        : > "${MOCK_STARTED:?}"
        echo '{"ok":true}' ;;
      wait)  echo '{"ok":true}' ;;
      read)  echo "" ;;
      get)
        # one-shot post-start growth (ordering: PRE_START_REVISION get happens
        # BEFORE `agent start`, so it must NOT trigger the grow)
        if [[ "${MOCK_MODE:-nogrow}" != "nogrow" ]] \
           && [[ -f "${MOCK_STARTED:?}" ]] && [[ ! -f "${MOCK_GROW_DONE:?}" ]]; then
          : > "${MOCK_GROW_DONE:?}"
          case "${MOCK_MODE}" in
            grow)
              cat > "${MOCK_AGENT_STATE:?}" <<'SJSON'
{"result":{"agent":{"agent_status":"working","revision":"5","interactive_ready":true,"pane_id":"p1"}}}
SJSON
              ;;
            sessionfile)
              mkdir -p "$(dirname "${MOCK_SESSION_FILE:?}")"
              printf '%s\n' "$(date +%s) session wrote turn state" >> "${MOCK_SESSION_FILE:?}" ;;
          esac
        fi
        cat "${MOCK_AGENT_STATE:?}" ;;
      list)
        if [[ -n "${MOCK_KILL_FILE:-}" ]] && [[ -f "${MOCK_KILL_FILE:?}" ]]; then
          echo '{"result":{"agents":[]}}'
        else
          echo '{"result":{"agents":[{"agent":"pi","agent_status":"idle","pane_id":"p1"}]}}'
        fi ;;
      prompt)
        # MUST never be called for the brief under T-029; recorded so the
        # zero-prompt assertion can prove it (the smoke greps the record).
        echo '{"ok":true}' ;;
    esac ;;
esac
exit 0
EOF

cat > "$MOCK_BIN/treehouse" <<'EOF'
#!/usr/bin/env bash
# Mock treehouse for the T-029 smoke — records calls, returns the fake worktree
# path as the LAST stdout line (exactly what the launcher parses for `get`).
set -u
echo "TREEHOUSE $*" >> "${MOCK_TREE_LOG:?}"
case "${1:-}" in
  get) printf '%s\n' "${MOCK_WT_PATH:?}" ;;
esac
exit 0
EOF
chmod +x "$MOCK_BIN/herdr" "$MOCK_BIN/treehouse"
log "mocks in place: $MOCK_BIN (herdr + treehouse)"

# ------------------------------------------------------------- helpers ----
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

# encoded-cwd session dir — same sed bin/herdr-launch.sh uses for SESSION_DIR
enc_session_dir() {
  printf '%s' "$WT" | sed 's|^/||; s|/|-|g; s|.*|--&--|'
}
SESS_DIR="$HOME_DIR/.pi/agent/sessions/$(enc_session_dir)"

# Common scenario fixtures. mode: grow|nogrow|sessionfile, tid: task id.
scenario_env() {  # <mode> <tid> → prints the env list for the launcher run
  local mode="$1" tid="$2"
  printf '%s\n' \
    "FLEET_STATE_HOME=$STATE" \
    "MOCK_MODE=$mode" \
    "MOCK_AGENT_STATE=$SCRATCH/$tid.agent.json" \
    "MOCK_RECORD=$SCRATCH/$tid.record" \
    "MOCK_TREE_LOG=$SCRATCH/$tid.tree" \
    "MOCK_STARTED=$SCRATCH/$tid.started" \
    "MOCK_GROW_DONE=$SCRATCH/$tid.growdone" \
    "MOCK_SESSION_FILE=$SESS_DIR/session.jsonl" \
    "MOCK_KILL_FILE=$SCRATCH/$tid.kill" \
    "MOCK_WT_PATH=$WT" \
    "FLEET_STARTUP_WAIT_TRIES=2" \
    "FLEET_STARTUP_WAIT_SLEEP=1" \
    "HOME=$HOME_DIR" \
    "PATH=$MOCK_BIN:$PATH"
}

# Seed the fake child fixtures for a scenario and launch the REAL launcher.
launch_scenario() {  # <mode> <out-file> <tid> [--bg]
  local mode="$1" out="$2" tid="$3" bg="${4:-}"
  seed_fixtures "$mode" "$tid"
  local envs
  envs="$(scenario_env "$mode" "$tid")"
  if [[ "$bg" == "--bg" ]]; then
    env -i /usr/bin/env bash -c "
      set -a
      $envs
      set +a
      exec \"\$@\"
    " bash "$LAUNCHER" "t029-$mode" "T-029 $mode scenario brief" \
      --project "$PROJ" --task-id "$tid" --timeout-min 1 >"$out" 2>&1 &
    echo $!
    return 0
  fi
  rlimit 120 "$out" env -i /usr/bin/env bash -c "
    set -a
    $envs
    set +a
    exec \"\$@\"
  " bash "$LAUNCHER" "t029-$mode" "T-029 $mode scenario brief" \
    --project "$PROJ" --task-id "$tid" --timeout-min 1
  return $?
}

# Seed the fake child fixtures for a scenario mode.
seed_fixtures() {  # <mode> <tid>
  local mode="$1" tid="$2"
  local agent_state="$SCRATCH/$tid.agent.json"
  case "$mode" in
    nogrow)
      # never leaves idle, never grows
      cat > "$agent_state" <<'SJSON'
{"result":{"agent":{"agent_status":"idle","revision":"2","interactive_ready":null,"pane_id":"p1"}}}
SJSON
      rm -f "$SESS_DIR/session.jsonl" "$SCRATCH/$tid.started" "$SCRATCH/$tid.growdone" "$SCRATCH/$tid.kill" ;;
    grow)
      # input layer ready from the start; mock flips status to working post-start
      cat > "$agent_state" <<'SJSON'
{"result":{"agent":{"agent_status":"idle","revision":"2","interactive_ready":true,"pane_id":"p1"}}}
SJSON
      rm -f "$SESS_DIR/session.jsonl" "$SCRATCH/$tid.started" "$SCRATCH/$tid.growdone" "$SCRATCH/$tid.kill" ;;
    sessionfile)
      # input layer NEVER ready (fail-soft), agent stays idle; the mock grows
      # only the session file post-start
      cat > "$agent_state" <<'SJSON'
{"result":{"agent":{"agent_status":"idle","revision":"2","interactive_ready":null,"pane_id":"p1"}}}
SJSON
      rm -f "$SESS_DIR/session.jsonl" "$SCRATCH/$tid.started" "$SCRATCH/$tid.growdone" "$SCRATCH/$tid.kill" ;;
  esac
  mkdir -p "$SESS_DIR"
}

# Wait (bounded) for a launcher pid to exit; returns the exit code.
wait_pid() {  # <pid> <secs>
  local pid="$1" secs="$2" rc
  for ((i = 0; i < secs * 2; i++)); do
    kill -0 "$pid" 2>/dev/null || { wait "$pid"; rc=$?; return $rc; }
    sleep 0.5
  done
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  return 124
}

# Wait (bounded) for a pattern in the launcher out file.
wait_log() {  # <out-file> <pattern> <secs>
  local out="$1" pat="$2" secs="$3"
  for ((i = 0; i < secs * 2; i++)); do
    grep -q -- "$pat" "$out" 2>/dev/null && return 0
    sleep 0.5
  done
  return 1
}

# The task brief must already be materialized as <tid>.prompt.md by the
# launcher — used by the prompt-file assertions.
prompt_file() { echo "$STATE/tasks/$1.prompt.md"; }

# ============================================================ A nogrow ======
log "STEP A — nogrow child + pane dies → fail-soft residual wait (NO re-send) then liveness fail"
launch_scenario nogrow "$SCRATCH/a.out" t029a --bg
PID_A=$!
log "  launcher pid=$PID_A"
wait_log "$SCRATCH/a.out" "child didn't leave idle within" 30 \
  && pass "A1 fail-soft residual wait logged (NO fail-fast on nogrow)" \
  || fail "A1 fail-soft residual wait message missing"
grep -q "brief delivered to the child (native initial request)" "$SCRATCH/a.out" \
  && pass "A2 'brief delivered to the child (native initial request)' logged after start" \
  || fail "A2 native delivery log missing"
touch "$SCRATCH/t029a.kill"   # the agent disappears → done-wait liveness trips
wait_pid "$PID_A" 120
RC_A=$?
log "  launcher exit=$RC_A (expected 1 via the §7 liveness gate)"
if [[ "$RC_A" -eq 1 ]]; then
  pass "A3 launcher exits 1 via the liveness gate (not fail-fast, no re-send)"
else
  fail "A3 expected rc=1 (liveness), got rc=$RC_A"
fi
if ! grep -q 'MOCK agent prompt' "$SCRATCH/t029a.record" 2>/dev/null; then
  pass "A4 ZERO 'agent prompt' calls for the brief (no re-send machinery)"
else
  fail "A4 'agent prompt' was called!"
fi
if [[ -f "$STATE/t029a.json" ]]; then
  A_ST="$(jq -r '.state // ""' "$STATE/t029a.json")"
  A_SUM="$(jq -r '.summary // ""' "$STATE/t029a.json")"
  if [[ "$A_ST" == "failed" ]] && [[ "$A_SUM" == *"without writing the done-marker"* ]]; then
    pass "A5 state=failed with the LIVENESS reason (summary: ${A_SUM:0:60}…)"
  else
    fail "A5 expected state=failed + liveness summary, got state=$A_ST summary='$A_SUM'"
  fi
else
  fail "A5 missing state record $STATE/t029a.json"
fi
if [[ -f "$(prompt_file t029a)" ]] \
   && grep -q "T-029 nogrow scenario brief" "$(prompt_file t029a)" \
   && grep -q "DELIVERY POSTURE:" "$(prompt_file t029a)"; then
  pass "A6 prompt file written with the full CHILD_PROMPT (brief + posture)"
else
  fail "A6 prompt file missing/incomplete ($(prompt_file t029a))"
fi
grep -q 'MOCK agent start .*@' "$SCRATCH/t029a.record" \
  && grep -q '@'"$STATE/tasks/t029a.prompt.md" "$SCRATCH/t029a.record" \
  && pass "A7 agent start argv carries @<prompt-file> (native initial request)" \
  || fail "A7 @<prompt-file> not found in the agent start argv record"
if grep -q 'MOCK tab close' "$SCRATCH/t029a.record" && grep -q 'MOCK pane close' "$SCRATCH/t029a.record" \
   && grep -q 'TREEHOUSE return' "$SCRATCH/t029a.tree"; then
  pass "A8 cleanup: tab + pane closed, worktree released"
else
  fail "A8 cleanup incomplete (record: $(tail -2 "$SCRATCH/t029a.record" 2>/dev/null | tr '\n' ' '))"
fi

# ======================================================== B grow (status) ===
log "STEP B — child leaves idle (status → working): residual wait passes, one start, done"
launch_scenario grow "$SCRATCH/b.out" t029b --bg
PID_B=$!
log "  launcher pid=$PID_B"
wait_log "$SCRATCH/b.out" "child left idle — processing the native initial request" 30 \
  && pass "B1 residual wait passed: 'child left idle' logged (first poll)" \
  || fail "B1 'child left idle' not logged"
grep -q "brief delivered to the child (native initial request)" "$SCRATCH/b.out" \
  && pass "B2 native delivery logged after start" \
  || fail "B2 native delivery log missing"
# feed the done-marker now that the delivery is confirmed
if [[ ! -f "$STATE/t029b.done.json" ]]; then
  jq -nc '{status:"done",summary:"native initial request ok, status-grow",changedFiles:[]}' > "$STATE/t029b.done.json"
fi
wait_pid "$PID_B" 90
RC_B=$?
log "  launcher exit=$RC_B (expected 0)"
if [[ "$RC_B" -eq 0 ]]; then
  pass "B3 launcher exits 0 after the native-request task completes"
else
  fail "B3 expected rc=0, got rc=$RC_B (out: $(tail -3 "$SCRATCH/b.out" 2>/dev/null | tr '\n' ' '))"
fi
if ! grep -q 'MOCK agent prompt' "$SCRATCH/t029b.record" 2>/dev/null; then
  pass "B4 ZERO 'agent prompt' calls (single native start)"
else
  fail "B4 'agent prompt' was called!"
fi
if [[ -f "$STATE/t029b.json" ]] && [[ "$(jq -r '.state // ""' "$STATE/t029b.json")" == "done" ]] \
   && [[ "$(jq -r '.summary // ""' "$STATE/t029b.json")" == "native initial request ok, status-grow" ]]; then
  pass "B5 task completed: state=done, summary from the done-marker"
else
  fail "B5 expected state=done + summary, got $(jq -r '.state // "<missing>"' "$STATE/t029b.json" 2>/dev/null)"
fi
if [[ ! -f "$STATE/t029b.done.json" ]] \
   && grep -q 'TREEHOUSE return' "$SCRATCH/t029b.tree"; then
  pass "B6 done-marker consumed + worktree released"
else
  fail "B6 done-marker still present or treehouse not returned"
fi

# ==================================================== C grow (session file) ==
log "STEP C — child only grows its session file: residual wait passes via the session signal"
launch_scenario sessionfile "$SCRATCH/c.out" t029c --bg
PID_C=$!
log "  launcher pid=$PID_C"
wait_log "$SCRATCH/c.out" "child left idle — processing the native initial request" 30 \
  && pass "C1 residual wait passed via the SESSION-FILE signal (status stayed idle)" \
  || fail "C1 'child left idle' not logged for the session-file grow"
if [[ -s "$SESS_DIR/session.jsonl" ]]; then
  pass "C2 the mock child session file actually grew (signal source present)"
else
  fail "C2 session file empty — the signal could not have come from it"
fi
if [[ -f "$STATE/t029c.done.json" ]]; then :; else
  jq -nc '{status:"done",summary:"native initial request ok, session-grow",changedFiles:[]}' > "$STATE/t029c.done.json"
fi
wait_pid "$PID_C" 90
RC_C=$?
log "  launcher exit=$RC_C (expected 0)"
if [[ "$RC_C" -eq 0 ]]; then
  pass "C3 launcher exits 0 after a session-file-grow delivery"
else
  fail "C3 expected rc=0, got rc=$RC_C (out: $(tail -3 "$SCRATCH/c.out" 2>/dev/null | tr '\n' ' '))"
fi
if ! grep -q 'MOCK agent prompt' "$SCRATCH/t029c.record" 2>/dev/null \
   && [[ -f "$STATE/t029c.json" ]] && [[ "$(jq -r '.state // ""' "$STATE/t029c.json")" == "done" ]]; then
  pass "C4 zero prompt + task done (state=done)"
else
  fail "C4 zero-prompt or state!=done (got $(jq -r '.state // "<missing>"' "$STATE/t029c.json" 2>/dev/null))"
fi

# ==================================================== D baseline (textual) ==
log "STEP D — the launcher source carries NO agent-prompt CALL for the brief"
if ! grep -Eq 'herdr_cli agent prompt|agent prompt "\$PANE' "$LAUNCHER"; then
  pass "D1 ZERO 'agent prompt' CALLS in bin/herdr-launch.sh (comments only)"
else
  fail "D1 a 'agent prompt' call is still present"
fi
if grep -q 'agent start .*"@\$PROMPT_PATH"' "$LAUNCHER"; then
  pass "D2 agent start argv carries @\$PROMPT_PATH (native initial request)"
else
  fail "D2 @\$PROMPT_PATH not wired into agent start"
fi
if grep -q '> "\$PROMPT_PATH"' "$LAUNCHER"; then
  pass "D3 CHILD_PROMPT materialized to \$PROMPT_PATH before start"
else
  fail "D3 prompt-file write missing"
fi
if grep -q 'PROMPT_ATTEMPTS_MAX\|ACK_POLL\|consumption ACK' "$LAUNCHER"; then
  fail "D4 leftover T-027 send/ACK machinery found"
else
  pass "D4 no leftover T-027 send/ACK machinery"
fi

# ---------------------------------------------------------------- result ---
log "OUTCOME: $OK/22 prompt-ACK smoke checks green"
[[ "$OK" -ge 22 ]] || die "not all prompt-ACK smoke checks passed"
exit 0