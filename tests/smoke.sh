#!/usr/bin/env bash
#
# pi-fleet · end-to-end smoke test (T-008)
#
# Exercises the BASE CHAIN of the system on a temporary scratch repo:
#
#   launcher (bin/herdr-launch.sh) → pi child in the herdr pane ("fleet" workspace,
#   sidebar only) → done-marker on disk → final state on disk
#
# Isolation: FLEET_STATE_HOME points to /tmp/fleet-smoke-state-* → no file is
# written in the real fleet (~/.pi/fleet). The real herdr workspace is used
# (that's the point of the test: real chain), but the pane/tab is closed by the
# launcher at the end and the state on disk is never touched.
#
# Usage:
#   bash tests/smoke.sh
#
# Exit codes:
#   0  green — the whole chain ok (state done, esito.txt with SMOKE_OK, done-marker consumed)
#   1  failed — a check or the launcher failed
#   2  missing prerequisites — herdr absent or unreachable, jq absent
#      (documented skip, NEVER a false green)
#
# Environment (all optional):
#   HERDR_SESSION          herdr session to use (default: "default")
#   PI_FLEET_SMOKE_MODEL   child model override, full id "provider/id"
#                          (default: launcher env chain, e.g. PI_PROVIDER/PI_MODEL)
#   SMOKE_TIMEOUT_S        external launcher timeout, seconds (default: 480)
#   SMOKE_KEEP=1           do NOT remove scratch/state at the end (debug)
#
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
LAUNCHER="$REPO_ROOT/bin/herdr-launch.sh"

TS="$(date +%s)"
TASK_ID="smoke-$TS"
SCRATCH="/tmp/fleet-smoke-$TS"
STATE_DIR="/tmp/fleet-smoke-state-$TS"
BRIEF_FILE="$STATE_DIR/brief.md"
SESSION="${HERDR_SESSION:-default}"
LAUNCH_TIMEOUT_S="${SMOKE_TIMEOUT_S:-480}"
KEEP="${SMOKE_KEEP:-0}"

log()  { printf 'SMOKE [%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf 'SMOKE FAIL: %s\n' "$*" >&2; exit 1; }
die2() { printf 'SMOKE SKIP (exit 2): %s\n' "$*" >&2; exit 2; }

cleanup() {
  [[ "$KEEP" == "1" ]] && { log "cleanup: SMOKE_KEEP=1, lascio /tmp/fleet-smoke-$TS e /tmp/fleet-smoke-state-$TS"; return 0; }
  rm -rf "$SCRATCH" "$STATE_DIR"
}
trap cleanup EXIT

# Robust timeout: `timeout` (GNU) or `gtimeout` (coreutils on macOS) if present;
# otherwise a POSIX wrapper with background + kill.
run_with_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; return $?; fi
  if command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"; return $?; fi
  "$@" &
  local pid=$! rc
  ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null ) &
  local killer=$!
  wait "$pid"; rc=$?
  kill "$killer" 2>/dev/null
  wait "$killer" 2>/dev/null   # consume the job termination notification (no "Terminated" on stderr)
  return $rc
}

# ---------------------------------------------------------------- [1/6] preflight
log "[1/6] preflight: binaries, herdr reachable, scratch repo"

command -v herdr >/dev/null 2>&1 || die2 "herdr not found in PATH — start herdr and retry"
command -v jq   >/dev/null 2>&1 || die2 "jq not found in PATH (brew install jq)"
command -v git  >/dev/null 2>&1 || die2 "git not found in PATH"
[[ -f "$LAUNCHER" ]] || die "launcher not found: $LAUNCHER"

if ! herdr --session "$SESSION" workspace list >/dev/null 2>&1; then
  die2 "herdr not reachable (session '$SESSION'): workspace list failed — \
is the herdr daemon running? (the smoke test is SKIPPED, no false green)"
fi

mkdir -p "$SCRATCH" "$STATE_DIR"
( cd "$SCRATCH" \
    && git init -q \
    && git config user.name "fleet-smoke" \
    && git config user.email "fleet-smoke@localhost" \
    && printf '# fleet smoke scratch\n' > README.md \
    && git add README.md \
    && git commit -qm "init smoke" ) \
  || die "scratch repo creation failed: $SCRATCH"
log "scratch repo: $SCRATCH (initial commit ok)"

# ---------------------------------------------------------------- [2/6] isolated state
log "[2/6] isolated state: FLEET_STATE_HOME=$STATE_DIR (real fleet ~/.pi/fleet intact)"
export FLEET_STATE_HOME="$STATE_DIR"

# ---------------------------------------------------------------- [3/6] brief
log "[3/6] short brief for the child ($BRIEF_FILE)"
cat > "$BRIEF_FILE" <<'EOF'
# T-008 smoke — minimal child task

Goal: verify the launcher → child → done-marker → on-disk state chain.
Nothing else is needed: this task is deliberately trivial.

1. Create the file `esito.txt` at the ROOT of the cwd (no subfolders) and write
   EXACTLY one line: `SMOKE_OK` + the pi version (run `pi --version` if useful
   and append it). Example: `SMOKE_OK pi 0.84.x`

2. Finish by writing the done-marker to the DONE_PATH file indicated by the
   launcher, in JSON format:
   {"status":"done","summary":"...","changedFiles":["esito.txt"]}
   - summary: short and self-contained, with the real outcome (e.g. "SMOKE_OK on pi x.y.z — esito.txt written").
   - changedFiles: ["esito.txt"] (path relative to the cwd).

3. Do NOT commit, do NOT pull/push of any kind, do NOT ask for input:
   write the two files and finish.
EOF
log "brief written"

# ---------------------------------------------------------------- [4/6] launcher
MODEL_FLAG=()
if [[ -n "${PI_FLEET_SMOKE_MODEL:-}" ]]; then
  MODEL_FLAG=(--model "$PI_FLEET_SMOKE_MODEL")
  log "child model (env override): $PI_FLEET_SMOKE_MODEL"
else
  log "child model: launcher env chain (PI_PROVIDER/PI_MODEL or default)"
fi

log "[4/6] launching the launcher: internal timeout 5min, external timeout ${LAUNCH_TIMEOUT_S}s"
run_with_timeout "$LAUNCH_TIMEOUT_S" \
  "$LAUNCHER" "smoke-$TS" "@$BRIEF_FILE" \
  --project "$SCRATCH" --no-worktree --task-id "$TASK_ID" --timeout-min 5 \
  "${MODEL_FLAG[@]+"${MODEL_FLAG[@]}"}"
RC=$?
log "[4/6] launcher exited with code: $RC"
if [[ $RC -ne 0 ]]; then
  if [[ $RC -eq 143 || $RC -eq 137 ]]; then
    die "launcher terminated by the wrapper after ${LAUNCH_TIMEOUT_S}s (external timeout): \
the task did not reach the done-marker in time — check herdr and the pane"
  fi
  die "launcher failed (exit $RC) — see the [fleet] logs above"
fi

# ---------------------------------------------------------------- [5/6] verifications
log "[5/6] verifying outcome (state json, esito.txt, done-marker consumed)"

STATE_JSON="$STATE_DIR/$TASK_ID.json"
DONE_JSON="$STATE_DIR/$TASK_ID.done.json"
ESITO_FILE="$SCRATCH/esito.txt"
FAILS=0

# 5.1 state json: exists, state == done, non-empty summary
if [[ ! -f "$STATE_JSON" ]]; then
  FAILS=$((FAILS + 1)); log "FAIL: missing state json: $STATE_JSON"
else
  S="$(jq -r '.state // ""' "$STATE_JSON")"
  SUM="$(jq -r '.summary // ""' "$STATE_JSON")"
  FILES="$(jq -c '.changedFiles // []' "$STATE_JSON")"
  log "  state json: state=$S changedFiles=$FILES"
  [[ "$S" == "done" ]] || { FAILS=$((FAILS + 1)); log "FAIL: state='$S', expected 'done'"; }
  [[ -n "$SUM" ]] || { FAILS=$((FAILS + 1)); log "FAIL: empty summary in the state json"; }
fi

# 5.2 esito.txt in the scratch repo contains SMOKE_OK
if [[ -f "$ESITO_FILE" ]]; then
  if grep -q "SMOKE_OK" "$ESITO_FILE" 2>/dev/null; then
    log "  esito.txt: ok (content: $(tr '\n' ' ' < "$ESITO_FILE"))"
  else
    FAILS=$((FAILS + 1)); log "FAIL: esito.txt does not contain SMOKE_OK: $(cat "$ESITO_FILE")"
  fi
else
  FAILS=$((FAILS + 1)); log "FAIL: esito.txt missing in $SCRATCH"
fi

# 5.3 done-marker consumed (the launcher removes it after writing the state)
if [[ -f "$DONE_JSON" ]]; then
  FAILS=$((FAILS + 1)); log "FAIL: done-marker still present (not consumed): $DONE_JSON"
else
  log "  done-marker: consumed (removed by the launcher)"
fi

if [[ $FAILS -gt 0 ]]; then
  die "verifications failed: $FAILS checks not passed"
fi

# ---------------------------------------------------------------- [6/6] outcome
log "[6/6] all checks green"
log "OUTCOME: OK — launcher → child → done-marker → state chain verified (task $TASK_ID)"

# ══════════════════════════════════════════════════════════ gate T-011 ════════════════
# Mechanical gate (T-011) scenario on dedicated scratch repos with gate.yaml and
# autoPr:false (NO remote → no real PR). The launcher receives --gate directly
# (the same flag the extension passes when posture=no-mistakes AND gate.yaml exists).
#
#   Case A — broken test → task failed, red gate, report present, no PR
#   Case B — green test  → task done, green gate, no PR (autoPr false)
#
# The real automatic PR (GitHub remote + gh-axi) is OUTSIDE this automatic smoke:
# manual procedure documented in the task summary and in the README.

GATE_RUN="$REPO_ROOT/bin/gate-run.sh"
[[ -f "$GATE_RUN" ]] || die "gate-run.sh non trovato: $GATE_RUN"

log "[7/9] gate (T-011): scratch setup gate.yaml + brief case A/B"
TSG="$(date +%s)"
SCRATCH_A="/tmp/fleet-gate-a-$TSG"
SCRATCH_B="/tmp/fleet-gate-b-$TSG"
STATE_A="/tmp/fleet-gate-state-a-$TSG"
STATE_B="/tmp/fleet-gate-state-b-$TSG"
BRIEF_A="$STATE_A/brief.md"
BRIEF_B="$STATE_B/brief.md"
TASK_A="gate-a-$TSG"
TASK_B="gate-b-$TSG"
mkdir -p "$STATE_A" "$STATE_B"   # needed before the briefs (heredoc above); the scratches are created by setup_gate_scratch

# extended cleanup: also the gate scratch/state — single EXIT trap that
# preserves the original base cleanup (in bash the last EXIT trap replaces the previous ones)
_cleanup_gate() {
  [[ "$KEEP" == "1" ]] && return 0
  rm -rf "$SCRATCH_A" "$SCRATCH_B" "$STATE_A" "$STATE_B"
}
trap 'cleanup; _cleanup_gate' EXIT

setup_gate_scratch() {
  local dir="$1" state="$2"
  mkdir -p "$dir" "$state"
  # gate.yaml written OUTSIDE the subshell (heredoc + &&-chain in ( ) is not
  # parseable by bash): content = gate with autoPr false (no remote → no PR)
  cat > "$dir/gate.yaml" <<'YEOF'
posture: no-mistakes
autoPr: false
loop:
  maxRounds: 3
checks:
  - { name: gate-test, cmd: bash gate-test.sh, kind: hard }
YEOF
  ( cd "$dir" \
      && git init -q \
      && git config user.name "fleet-smoke" \
      && git config user.email "fleet-smoke@localhost" \
      && printf '# fleet gate scratch\n' > README.md \
      && git add README.md gate.yaml \
      && git commit -qm "init gate smoke" ) \
    || die "gate scratch repo creation failed: $dir"
}

# ---- briefs of the two cases ----
cat > "$BRIEF_A" <<'EOF'
# T-011 smoke — RED gate (case A)

Scratch project with gate.yaml: the `gate-test` check runs `bash gate-test.sh` (hard).

1. Create at the root of the cwd the file `gate-test.sh` with this EXACT content
   (deliberately BROKEN test — it exits with 1):

       #!/usr/bin/env bash
       echo "red gate (intentional)"; exit 1

2. Do NOT fix it: this is the RED gate verification case. If the gate asks you
   to fix, do NOT fix (explicit instruction of the brief).

3. Run the gate (GATE section of your prompt) and then write the done-marker
   to the DONE_PATH file with status "failed" and in the summary the essential
   content of the gate report (check names + exit codes + overall).

4. Do NOT commit, do NOT push, do NOT open a PR.
EOF
cat > "$BRIEF_B" <<'EOF'
# T-011 smoke — GREEN gate (case B)

Scratch project with gate.yaml: the `gate-test` check runs `bash gate-test.sh` (hard).

1. Create at the root of the cwd the file `gate-test.sh` that exits with 0:

       #!/usr/bin/env bash
       echo "green gate"; exit 0

2. Run the gate (GATE section of your prompt): it must be GREEN at the
   first round (no fix needed).

3. On green write the done-marker to the DONE_PATH file with status "done" and
   in the JSON the gate field:
       "gate":{"passed":true,"rounds":1,"reportPath":"gate/report.json"}

4. Do NOT commit, do NOT push, do NOT open a PR.
EOF
log "  scratch A: $SCRATCH_A · scratch B: $SCRATCH_B (isolated states in /tmp)"

# ------------------------------------------------------------- [8/9] gate case A
log "[8/9] gate case A (broken test → expected failed, red gate, no PR)"
setup_gate_scratch "$SCRATCH_A" "$STATE_A"
export FLEET_STATE_HOME="$STATE_A"
run_with_timeout "$LAUNCH_TIMEOUT_S" \
  "$LAUNCHER" "gate-a-$TSG" "@$BRIEF_A" \
  --project "$SCRATCH_A" --no-worktree --task-id "$TASK_A" --timeout-min 8 \
  --gate --auto-pr false \
  "${MODEL_FLAG[@]+"${MODEL_FLAG[@]}"}" \
  >/dev/null 2>&1
RC_A=$?
log "  case A: launcher exit=$RC_A"
[[ $RC_A -eq 0 ]] || die "case A: launcher failed (exit $RC_A)"
SA="$STATE_A/$TASK_A.json"
FAILS=0
[[ -f "$SA" ]] || die "case A: missing state json: $SA"
ST_A="$(jq -r '.state // ""' "$SA")"
GP_A="$(jq -r '.gate.passed // false' "$SA")"
PR_A="$(jq -r '.prUrl // ""' "$SA")"
log "  case A: state=$ST_A gate.passed=$GP_A prUrl='$PR_A'"
[[ "$ST_A" == "failed" ]] || { FAILS=$((FAILS + 1)); log "  FAIL: state='$ST_A', expected failed"; }
[[ "$GP_A" == "false" ]] || { FAILS=$((FAILS + 1)); log "  FAIL: gate.passed='$GP_A', expected false"; }
[[ -z "$PR_A" ]] || { FAILS=$((FAILS + 1)); log "  FAIL: prUrl present='$PR_A', expected empty (autoPr false)"; }
if [[ -f "$SCRATCH_A/gate/report.json" ]]; then
  REP_A="$(jq -r '.overall // ""' "$SCRATCH_A/gate/report.json")"
  log "  case A: report present, overall=$REP_A"
  [[ "$REP_A" == "red" ]] || { FAILS=$((FAILS + 1)); log "  FAIL: report overall='$REP_A', expected red"; }
else
  FAILS=$((FAILS + 1)); log "  FAIL: missing gate report: $SCRATCH_A/gate/report.json"
fi
[[ $FAILS -eq 0 ]] || die "case A: $FAILS checks not passed"
log "  case A OK: failed + red gate + report present + no PR"

# ------------------------------------------------------------- [9/9] gate case B
log "[9/9] gate case B (green test → expected done, green gate, no PR)"
setup_gate_scratch "$SCRATCH_B" "$STATE_B"
export FLEET_STATE_HOME="$STATE_B"
run_with_timeout "$LAUNCH_TIMEOUT_S" \
  "$LAUNCHER" "gate-b-$TSG" "@$BRIEF_B" \
  --project "$SCRATCH_B" --no-worktree --task-id "$TASK_B" --timeout-min 8 \
  --gate --auto-pr false \
  "${MODEL_FLAG[@]+"${MODEL_FLAG[@]}"}" \
  >/dev/null 2>&1
RC_B=$?
log "  case B: launcher exit=$RC_B"
[[ $RC_B -eq 0 ]] || die "case B: launcher failed (exit $RC_B)"
SB="$STATE_B/$TASK_B.json"
FAILS=0
[[ -f "$SB" ]] || die "case B: missing state json: $SB"
ST_B="$(jq -r '.state // ""' "$SB")"
GP_B="$(jq -r '.gate.passed // false' "$SB")"
PR_B="$(jq -r '.prUrl // ""' "$SB")"
log "  case B: state=$ST_B gate.passed=$GP_B prUrl='$PR_B'"
[[ "$ST_B" == "done" ]] || { FAILS=$((FAILS + 1)); log "  FAIL: state='$ST_B', expected done"; }
[[ "$GP_B" == "true" ]] || { FAILS=$((FAILS + 1)); log "  FAIL: gate.passed='$GP_B', expected true"; }
[[ -z "$PR_B" ]] || { FAILS=$((FAILS + 1)); log "  FAIL: prUrl present='$PR_B', expected empty (autoPr false)"; }
if [[ -f "$SCRATCH_B/gate/report.json" ]]; then
  REP_B="$(jq -r '.overall // ""' "$SCRATCH_B/gate/report.json")"
  log "  case B: report present, overall=$REP_B"
  [[ "$REP_B" == "green" ]] || { FAILS=$((FAILS + 1)); log "  FAIL: report overall='$REP_B', expected green"; }
else
  FAILS=$((FAILS + 1)); log "  FAIL: missing gate report: $SCRATCH_B/gate/report.json"
fi
[[ $FAILS -eq 0 ]] || die "case B: $FAILS checks not passed"
log "  case B OK: done + green gate + report present + no PR"

log "GATE OUTCOME (T-011): OK — case A (red→failed, no PR) and case B (green→done, no PR)"
exit 0