#!/usr/bin/env bash
#
# pi-fleet · T-027 prompt-delivery ACK smoke — fully headless
#
# Drives the REAL bin/herdr-launch.sh with a MOCKED herdr + MOCKED treehouse
# (PATH shadowing — no real pane, daemon or worktree is ever touched) and an
# ISOLATED FLEET_STATE_HOME under /tmp (the real ~/.pi/fleet is NEVER touched).
#
#   A  nogrow child   — the child NEVER consumes (status stays idle, no pane
#                       output, no session-file growth): the launcher re-sends
#                       the brief FLEET_PROMPT_ATTEMPTS_MAX times, NEVER logs
#                       'brief delivered', writes the state record as failed,
#                       closes tab+pane, releases the worktree, exits nonzero.
#                       No done-marker is ever written.
#   B  grow (status)  — the child flips agent.get → working on the FIRST
#                       prompt: consumption ACKed at the FIRST poll, exactly
#                       ONE prompt send, 'brief delivered to the child
#                       (consumption ACKed)' logged, READINESS confirmed
#                       (interactive_ready), task completes done.
#   C  grow (session) — the child only grows its session file
#                       (~/.pi/agent/sessions/<encoded-cwd>/, agent state stays
#                       idle): consumption still ACKed at the FIRST poll via the
#                       session-file signal, still ONE send, task completes done.
#   D  baseline       — the OLD sequence (idle + sleep + prompt alone) is no
#                       longer the delivery path: the ACK machinery sits between
#                       the `agent prompt` call and the 'brief delivered' log.
#
# Real herdr/treehouse are shadowed by mocks at $SCRATCH/bin (see the mock
# headers); the launcher env knobs (FLEET_INPUT_READY_TRIES/SLEEP,
# FLEET_PROMPT_ATTEMPTS_MAX, FLEET_ACK_POLL_SECS/POLLS_MAX) drive the bounded
# windows down so the headless run stays fast (~10s total).
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
# Mock herdr CLI for the T-027 smoke — NEVER touches the real herdr daemon.
# Behavior driven by env (set by the test per run):
#   MOCK_MODE           grow | nogrow | sessionfile
#   MOCK_AGENT_STATE    path to the fake agent JSON (the mock owns/updates it)
#   MOCK_TERM           path to the fake pane terminal text (agent read)
#   MOCK_PROMPT_LOG     append one line per `agent prompt` call
#   MOCK_RECORD         append "MOCK <cmd> [args]" per call (cleanup assertions)
#   MOCK_SESSION_FILE   session file the mock appends to on prompt (sessionfile)
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
      start) echo '{"ok":true}' ;;
      wait)  echo '{"ok":true}' ;;
      list)  echo '{"result":{"agents":[{"agent":"pi","agent_status":"idle","pane_id":"p1"}]}}' ;;
      get)   cat "${MOCK_AGENT_STATE:?}" ;;
      read)  cat "${MOCK_TERM:?}" ;;
      prompt)
        shift   # consume the pane id; the rest is the prompt text
        printf '%s\n' "PROMPT_SENT" >> "${MOCK_PROMPT_LOG:?}"
        case "${MOCK_MODE:-nogrow}" in
          grow)
            cat > "${MOCK_AGENT_STATE:?}" <<'SJSON'
{"result":{"agent":{"agent_status":"working","revision":"5","interactive_ready":true,"pane_id":"p1"}}}
SJSON
            printf '%s\n' "$*" >> "${MOCK_TERM:?}" ;;
          sessionfile)
            mkdir -p "$(dirname "${MOCK_SESSION_FILE:?}")"
            printf '%s\n' "$(date +%s) session wrote turn state" >> "${MOCK_SESSION_FILE:?}" ;;
        esac
        echo '{"ok":true}' ;;
    esac ;;
esac
exit 0
EOF

cat > "$MOCK_BIN/treehouse" <<'EOF'
#!/usr/bin/env bash
# Mock treehouse for the T-027 smoke — records calls, returns the fake worktree
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

# Seed the fake child fixtures for a scenario mode, then run the REAL launcher
# with the mocked herdr/treehouse + isolated state + fast ACK knobs.
#   launch_scenario <mode> <out-file> <task-id>
launch_scenario() {
  local mode="$1" out="$2" tid="$3"
  local agent_state="$SCRATCH/$tid.agent.json" term="$SCRATCH/$tid.term"
  : > "$term"
  case "$mode" in
    nogrow)
      # never ready, never consumes
      cat > "$agent_state" <<'SJSON'
{"result":{"agent":{"agent_status":"idle","revision":"2","interactive_ready":null,"pane_id":"p1"}}}
SJSON
      rm -f "$SCRATCH/$tid.session.jsonl" ;;
    grow)
      # input layer ready from the start; status flips to working on the prompt
      cat > "$agent_state" <<'SJSON'
{"result":{"agent":{"agent_status":"idle","revision":"2","interactive_ready":true,"pane_id":"p1"}}}
SJSON
      rm -f "$SCRATCH/$tid.session.jsonl" ;;
    sessionfile)
      # input layer NEVER ready (fail-soft readiness), agent stays idle; only
      # the session file grows when the prompt is received
      cat > "$agent_state" <<'SJSON'
{"result":{"agent":{"agent_status":"idle","revision":"2","interactive_ready":null,"pane_id":"p1"}}}
SJSON
      rm -f "$SCRATCH/$tid.session.jsonl" ;;
  esac
  # pre-create the session dir (the launcher's signal 4 needs it to exist)
  mkdir -p "$SESS_DIR"
  rlimit 90 "$out" env \
    FLEET_STATE_HOME="$STATE" \
    MOCK_MODE="$mode" \
    MOCK_AGENT_STATE="$agent_state" \
    MOCK_TERM="$term" \
    MOCK_PROMPT_LOG="$SCRATCH/$tid.prompts" \
    MOCK_RECORD="$SCRATCH/$tid.record" \
    MOCK_TREE_LOG="$SCRATCH/$tid.tree" \
    MOCK_SESSION_FILE="$SESS_DIR/session.jsonl" \
    MOCK_WT_PATH="$WT" \
    FLEET_INPUT_READY_TRIES=1 \
    FLEET_INPUT_READY_SLEEP=1 \
    FLEET_PROMPT_ATTEMPTS_MAX=2 \
    FLEET_ACK_POLL_SECS=1 \
    FLEET_ACK_POLLS_MAX=2 \
    HOME="$HOME_DIR" \
    PATH="$MOCK_BIN:$PATH" \
    "$LAUNCHER" "t027-$mode" "T-027 $mode scenario brief" \
      --project "$PROJ" --task-id "$tid" --timeout-min 1
  return $?
}

# For the growing scenarios: run the launcher in background, feed the
# done-marker as soon as the delivery ACK appears, then wait (bounded) for the
# launcher exit. Returns the launcher exit code.
launch_and_feed_done() {  # <mode> <out-file> <task-id>
  local mode="$1" out="$2" tid="$3"
  local pid rc
  env \
    FLEET_STATE_HOME="$STATE" \
    MOCK_MODE="$mode" \
    MOCK_AGENT_STATE="$SCRATCH/$tid.agent.json" \
    MOCK_TERM="$SCRATCH/$tid.term" \
    MOCK_PROMPT_LOG="$SCRATCH/$tid.prompts" \
    MOCK_RECORD="$SCRATCH/$tid.record" \
    MOCK_TREE_LOG="$SCRATCH/$tid.tree" \
    MOCK_SESSION_FILE="$SESS_DIR/session.jsonl" \
    MOCK_WT_PATH="$WT" \
    FLEET_INPUT_READY_TRIES=1 \
    FLEET_INPUT_READY_SLEEP=1 \
    FLEET_PROMPT_ATTEMPTS_MAX=2 \
    FLEET_ACK_POLL_SECS=1 \
    FLEET_ACK_POLLS_MAX=2 \
    HOME="$HOME_DIR" \
    PATH="$MOCK_BIN:$PATH" \
    "$LAUNCHER" "t027-$tid" "T-027 $tid scenario brief" \
      --project "$PROJ" --task-id "$tid" --timeout-min 1 >"$out" 2>&1 &
  pid=$!
  for ((i = 0; i < 120; i++)); do        # wait for the delivery ACK (≤60s)
    grep -q 'brief delivered to the child' "$out" 2>/dev/null && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
  done
  if [[ ! -f "$STATE/$tid.done.json" ]]; then
    jq -nc '{status:"done",summary:"consumption ack ok",changedFiles:[]}' > "$STATE/$tid.done.json"
  fi
  for ((i = 0; i < 180; i++)); do        # wait for the launcher exit (≤90s)
    kill -0 "$pid" 2>/dev/null || { wait "$pid"; rc=$?; return $rc; }
    sleep 0.5
  done
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  return 124
}

# seeded fixtures for the background-fed scenarios (launch_and_feed_done reuses
# the same paths launch_scenario would create)
seed_fixtures() {  # <mode> <task-id>
  local mode="$1" tid="$2"
  local agent_state="$SCRATCH/$tid.agent.json" term="$SCRATCH/$tid.term"
  : > "$term"
  case "$mode" in
    grow)
      cat > "$agent_state" <<'SJSON'
{"result":{"agent":{"agent_status":"idle","revision":"2","interactive_ready":true,"pane_id":"p1"}}}
SJSON
      ;;
    sessionfile)
      cat > "$agent_state" <<'SJSON'
{"result":{"agent":{"agent_status":"idle","revision":"2","interactive_ready":null,"pane_id":"p1"}}}
SJSON
      ;;
  esac
  rm -f "$SESS_DIR/session.jsonl"
  mkdir -p "$SESS_DIR"
}

# ============================================================ A nogrow ======
log "STEP A — child NEVER consumes → retries, fail-fast, no spurious 'brief delivered'"
launch_scenario nogrow "$SCRATCH/a.out" t027a
RC_A=$?
log "  launcher exit=$RC_A (expected 1)"
if [[ "$RC_A" -eq 1 ]]; then
  pass "A1 launcher exits non-zero on the fail-fast path (rc=1)"
else
  fail "A1 expected rc=1, got rc=$RC_A"
fi
if ! grep -q 'brief delivered to the child' "$SCRATCH/a.out" 2>/dev/null; then
  pass "A2 NO 'brief delivered to the child' logged (even though prompts were sent)"
else
  fail "A2 'brief delivered to the child' logged spuriously"
fi
A_PROMPTS="$(wc -l < "$SCRATCH/t027a.prompts" 2>/dev/null | tr -d ' ')"
if [[ "$A_PROMPTS" -eq 2 ]]; then
  pass "A3 brief re-sent exactly FLEET_PROMPT_ATTEMPTS_MAX=2 times (sends=$A_PROMPTS)"
else
  fail "A3 expected 2 prompt sends, got $A_PROMPTS"
fi
if [[ -f "$STATE/t027a.json" ]]; then
  A_ST="$(jq -r '.state // ""' "$STATE/t027a.json")"
  A_SUM="$(jq -r '.summary // ""' "$STATE/t027a.json")"
  if [[ "$A_ST" == "failed" ]] && [[ "$A_SUM" == *"brief not consumed"* ]]; then
    pass "A4 state record written as failed with the ACK reason (state=$A_ST)"
  else
    fail "A4 expected state=failed + 'brief not consumed' summary, got state=$A_ST summary='$A_SUM'"
  fi
else
  fail "A4 missing state record $STATE/t027a.json"
fi
if grep -q 'MOCK tab close' "$SCRATCH/t027a.record" && grep -q 'MOCK pane close' "$SCRATCH/t027a.record"; then
  pass "A5 cleanup: tab + pane closed"
else
  fail "A5 cleanup: tab/pane close not recorded"
fi
if grep -q 'TREEHOUSE get' "$SCRATCH/t027a.tree" && grep -q 'TREEHOUSE return' "$SCRATCH/t027a.tree"; then
  pass "A6 cleanup: worktree leased + released"
else
  fail "A6 cleanup: treehouse get/return not both recorded"
fi
if [[ ! -f "$STATE/t027a.done.json" && ! -f "$STATE/t027a.needs-input.json" ]]; then
  pass "A7 NO done-marker / needs-input written (fail-fast happened before the done-wait)"
else
  fail "A7 unexpected marker after fail-fast"
fi

# ======================================================== B grow (status) ===
log "STEP B — child consumes (status → working): ACK at first poll, one send, done"
seed_fixtures grow t027b
launch_and_feed_done grow "$SCRATCH/b.out" t027b
RC_B=$?
log "  launcher exit=$RC_B (expected 0)"
if [[ "$RC_B" -eq 0 ]]; then
  pass "B1 launcher exits 0 after a consumed brief"
else
  fail "B1 expected rc=0, got rc=$RC_B (out: $(tail -3 "$SCRATCH/b.out" 2>/dev/null | tr '\n' ' '))"
fi
if grep -q 'input layer ready (interactive_ready confirmed)' "$SCRATCH/b.out"; then
  pass "B2 stronger readiness: interactive_ready confirmed before the prompt"
else
  fail "B2 'interactive_ready confirmed' not logged"
fi
if grep -q 'brief delivered to the child (consumption ACKed)' "$SCRATCH/b.out"; then
  pass "B3 'brief delivered to the child (consumption ACKed)' logged (and only after the ACK)"
else
  fail "B3 delivery-ACK log missing"
fi
B_PROMPTS="$(wc -l < "$SCRATCH/t027b.prompts" 2>/dev/null | tr -d ' ')"
if [[ "$B_PROMPTS" -eq 1 ]]; then
  pass "B4 exactly ONE prompt send (consumption detected at the first poll)"
else
  fail "B4 expected 1 prompt send, got $B_PROMPTS (would mean retries)"
fi
if [[ -f "$STATE/t027b.json" ]]; then
  B_ST="$(jq -r '.state // ""' "$STATE/t027b.json")"
  B_SUM="$(jq -r '.summary // ""' "$STATE/t027b.json")"
  if [[ "$B_ST" == "done" ]] && [[ "$B_SUM" == "consumption ack ok" ]]; then
    pass "B5 task completed: state=done, summary from the done-marker"
  else
    fail "B5 expected state=done + 'consumption ack ok', got state=$B_ST summary='$B_SUM'"
  fi
else
  fail "B5 missing state record $STATE/t027b.json"
fi
if [[ ! -f "$STATE/t027b.done.json" ]]; then
  pass "B6 done-marker consumed by the launcher"
else
  fail "B6 done-marker still present"
fi
if grep -q 'MOCK tab close' "$SCRATCH/t027b.record" && grep -q 'MOCK pane close' "$SCRATCH/t027b.record" \
   && grep -q 'TREEHOUSE return' "$SCRATCH/t027b.tree"; then
  pass "B7 cleanup: tab/pane closed + worktree released"
else
  fail "B7 cleanup incomplete (record: $(tail -2 "$SCRATCH/t027b.record" 2>/dev/null | tr '\n' ' '))"
fi

# ==================================================== C grow (session file) ==
log "STEP C — child only grows its session file: ACK via the session-file signal"
seed_fixtures sessionfile t027c
launch_and_feed_done sessionfile "$SCRATCH/c.out" t027c
RC_C=$?
log "  launcher exit=$RC_C (expected 0)"
if [[ "$RC_C" -eq 0 ]]; then
  pass "C1 launcher exits 0 after a session-file-consumed brief"
else
  fail "C1 expected rc=0, got rc=$RC_C (out: $(tail -3 "$SCRATCH/c.out" 2>/dev/null | tr '\n' ' '))"
fi
if grep -q 'input-ready signal not confirmed' "$SCRATCH/c.out"; then
  pass "C2 readiness fail-soft: interactive_ready absent → proceeds (the ACK is the gate)"
else
  fail "C2 fail-soft readiness log missing"
fi
if grep -q 'brief delivered to the child (consumption ACKed)' "$SCRATCH/c.out"; then
  pass "C3 delivery ACKed via session-file growth (interactive_ready was never true)"
else
  fail "C3 delivery-ACK log missing"
fi
C_PROMPTS="$(wc -l < "$SCRATCH/t027c.prompts" 2>/dev/null | tr -d ' ')"
if [[ "$C_PROMPTS" -eq 1 ]]; then
  pass "C4 exactly ONE prompt send (session-file signal fired at the first poll)"
else
  fail "C4 expected 1 prompt send, got $C_PROMPTS"
fi
if [[ -s "$SESS_DIR/session.jsonl" ]]; then
  pass "C5 the mock child session file actually grew (signal source present)"
else
  fail "C5 session file empty — the ACK could not have come from it"
fi
if [[ -f "$STATE/t027c.json" ]] && [[ "$(jq -r '.state // ""' "$STATE/t027c.json")" == "done" ]]; then
  pass "C6 task completed: state=done"
else
  fail "C6 expected state=done, got $(jq -r '.state // "<missing>"' "$STATE/t027c.json" 2>/dev/null)"
fi

# ==================================================== D baseline (textual) ==
log "STEP D — the OLD sequence (idle+sleep+prompt) is no longer the delivery path"
AWK_PROBE="$(awk '/herdr_cli agent prompt/{l=NR} /brief delivered to the child/{d=NR} END{print l+0, d+0}' "$LAUNCHER")"
P_LINE="${AWK_PROBE%% *}"
D_LINE="${AWK_PROBE##* }"
if grep -q 'prompt_consumed' "$LAUNCHER" \
   && grep -q 'FLEET_PROMPT_ATTEMPTS_MAX' "$LAUNCHER" \
   && [[ "$D_LINE" -gt "$P_LINE" ]] && [[ $((D_LINE - P_LINE)) -ge 30 ]]; then
  pass "D1 delivery path is now prompt → ACK loop → 'brief delivered' (lines $P_LINE → $D_LINE)"
else
  fail "D1 expected the ACK machinery (≥30 lines) between the prompt call and the 'brief delivered' log (got $P_LINE → $D_LINE)"
fi

# ---------------------------------------------------------------- result ---
log "OUTCOME: $OK/21 prompt-ACK smoke checks green"
[[ "$OK" -ge 21 ]] || die "not all prompt-ACK smoke checks passed"
exit 0