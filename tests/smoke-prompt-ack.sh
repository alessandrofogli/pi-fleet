#!/usr/bin/env bash
#
# pi-fleet · gh-7 native-initial-request smoke — fully headless
# (replaces the T-027/T-029 prompt-delivery ACK smoke)
#
# Drives the REAL bin/herdr-launch.sh with a MOCKED herdr + MOCKED treehouse
# (PATH shadowing — no real pane, daemon or worktree is ever touched) and an
# ISOLATED FLEET_STATE_HOME under /tmp (the real ~/.pi/fleet is NEVER touched).
#
# Contract under test (gh-7): the complete CHILD_PROMPT is materialized BEFORE
# `agent start` to a private transient file `$STATE_HOME/<id>.child-prompt.md`
# (umask 077, atomic tmp+mv, EXIT-trap removal, per-task stale sweep, durable
# brief files never touched) and delivered as pi's NATIVE initial request —
# `agent start ... -- [--model provider/id] @<prompt-file>` carries EXACTLY ONE
# @-argv element, intact even with spaces/metacharacters. There is NO post-start
# `agent prompt`, no readiness/interactive_ready wait, no ACK retry, no
# session-file snapshot, no fallback delivery: delivery IS `agent start`
# returning OK; the done-wait liveness gate still catches frozen panes.
#
# Issue gh-7 test plan mapped to scenarios:
#   1-2  argv recording + exactly-one-@ (absolute, exists at invocation, bytes
#        == the complete expected CHILD_PROMPT)                → S1 (+S2 metachars)
#   3    model as a separate --model provider/id pair          → S3
#   4    path with spaces + shell metacharacters               → S2
#   5    no agent prompt / no interactive_ready wait / no ACK
#        retry / no 'brief delivered' log                      → S1/S2/S3 + S9 baseline
#   6    done-marker completion + cleanup (state, marker
#        consumption, tab/pane close, worktree release)        → S1
#   7    start failure + missing/unreadable prompt file →
#        failed state + cleanup (no task stranded in spawning) → S4, S5
#   8    concurrent tasks, distinct IDs, no prompt cross-
#        contamination, no duplicate agent names/panes         → S6 (3 concurrent)
#   9    --resume mocked relaunch: rebuilt prompt with the
#        resume notice, no second manual prompt                → S7
#  10    installed-Pi parseArgs fixture (read-only, no
#        credentials)                                          → S8
#
# Every waiting helper is explicitly bounded (rlimit/wait_pid/wait_log —
# background + kill loop; NO GNU timeout).
#
# Prereqs: bash + jq (node required only for the S8 parseArgs fixture —
# documents a skip when the installed pi package is not discoverable).
# Exit: 0 green / 1 failed / 2 missing prerequisites.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
LAUNCHER="$REPO_ROOT/bin/herdr-launch.sh"
TS="$(date +%s)"
SCRATCH="/tmp/fleet-native-init-$TS"
STATE="$SCRATCH/state"
PROJ="$SCRATCH/proj"
WT="$SCRATCH/wt"
HOME_DIR="$SCRATCH/home"
MOCK_BIN="$SCRATCH/bin"
KEEP="${SMOKE_KEEP:-0}"

log() { printf 'NATIVE [%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf 'NATIVE FAIL: %s\n' "$*" >&2; exit 1; }
die2() { printf 'NATIVE SKIP (exit 2): %s\n' "$*" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || die2 "jq not found in PATH (brew install jq)"
[[ -f "$LAUNCHER" ]] || die "launcher not found: $LAUNCHER"
bash -n "$0" 2>/dev/null || die "smoke-prompt-ack.sh does not pass bash -n (self-check)"
bash -n "$LAUNCHER" 2>/dev/null || die "bin/herdr-launch.sh does not pass bash -n"

cleanup() {
  [[ "$KEEP" == "1" ]] && { log "SMOKE_KEEP=1: keeping $SCRATCH"; return 0; }
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

mkdir -p "$STATE/tasks" "$PROJ" "$WT" "$HOME_DIR" "$MOCK_BIN"

OK=0
pass() { OK=$((OK + 1)); log "  OK   $*"; }
fail() { log "  FAIL $*"; }

# ----------------------------------------------------------------- mocks ----
cat > "$MOCK_BIN/herdr" <<'EOF'
#!/usr/bin/env bash
# Mock herdr CLI for the gh-7 native-initial-request smoke — NEVER touches the
# real herdr daemon. Behavior driven by env:
#   MOCK_RECORD         append command traces (argv/cleanup assertions); the
#                       `agent start` block is ARG-per-line: ARGn=<raw value>
#   MOCK_PANE_ID        pane id reported by `tab create` / `agent list`
#   MOCK_COPIED_PROMPT  `agent start` copies the @file bytes here (byte proof)
#   MOCK_START_FAIL=1   `agent start` ALWAYS fails (rc=1) — start-failure scenario
#   MOCK_NO_AGENTS      `agent list` reports no agents (liveness negative)
set -u
[[ "$1" == "--session" ]] && shift 2
cmd="$1"; shift
echo "MOCK $cmd $*" >> "${MOCK_RECORD:?}"
case "$cmd" in
  workspace)
    case "${1:-}" in
      list)   echo '{"result":{"workspaces":[{"label":"fleet","workspace_id":"w9"}]}}' ;;
      create) echo '{"result":{"workspace":{"workspace_id":"w9"}}}' ;;
    esac ;;
  tab)
    case "${1:-}" in
      create) echo "{\"result\":{\"tab\":{\"tab_id\":\"t1\"},\"root_pane\":{\"pane_id\":\"${MOCK_PANE_ID:-p1}\"}}}" ;;
      close)  echo '{"ok":true}' ;;
    esac ;;
  pane) echo '{"ok":true}' ;;
  agent)
    sub="${1:-}"; shift
    case "$sub" in
      start)
        {
          echo "MOCK agent start"
          echo "PANE=$MOCK_PANE_ID"
          i=0
          for a in "$@"; do
            printf 'ARG%d=%s\n' "$i" "$a"
            i=$((i + 1))
          done
          # locate the single @file argument (its argv index) and prove it
          # existed as a REGULAR file at invocation; copy its bytes verbatim
          # (that is exactly what pi's file-processor would read).
          at=""
          idx=0
          for a in "$@"; do
            if [[ "$a" == @* ]]; then
              at="${a#@}"
              printf 'ARG_AT_INDEX=%d\n' "$idx"
              printf 'ARG_AT=%s\n' "$a"
            fi
            idx=$((idx + 1))
          done
          if [[ "${MOCK_START_FAIL:-0}" == "1" ]]; then
            echo "PROMPT_EXISTS=skipped-start-fail"
          elif [[ -n "$at" && -f "$at" && -r "$at" ]]; then
            cp "$at" "${MOCK_COPIED_PROMPT:?}"
            echo "PROMPT_EXISTS=yes"
          else
            echo "PROMPT_EXISTS=no"
          fi
        } >> "${MOCK_RECORD:?}"
        if [[ "${MOCK_START_FAIL:-0}" == "1" ]]; then
          echo "agent start failed (mocked, MOCK_START_FAIL=1)" >&2
          exit 1
        fi
        echo '{"ok":true}' ;;
      list)
        if [[ -n "${MOCK_NO_AGENTS:-}" ]]; then
          echo '{"result":{"agents":[]}}'
        else
          echo "{\"result\":{\"agents\":[{\"agent\":\"pi\",\"agent_status\":\"idle\",\"pane_id\":\"${MOCK_PANE_ID:-p1}\"}]}}"
        fi ;;
      prompt)
        # MUST NEVER happen for the brief under gh-7 — recorded so the zero-
        # prompt assertions can prove it.
        echo '{"ok":true}' ;;
    esac ;;
esac
exit 0
EOF

cat > "$MOCK_BIN/treehouse" <<'EOF'
#!/usr/bin/env bash
# Mock treehouse — records calls, returns the fake worktree path as the LAST
# stdout line (exactly what the launcher parses for `get`).
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

# Single-quote a value for safe injection into `set -a` env lines (values may
# contain spaces, &, $, backticks, quotes, ;, * etc. — never a newline).
sq() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# write_envs: <out-file> KEY=VALUE... → single-quoted `KEY='value'` lines.
write_envs() {
  local out="$1"; shift
  : > "$out"
  local kv k v
  for kv in "$@"; do
    k="${kv%%=*}"
    v="${kv#*=}"
    printf '%s=%s\n' "$k" "$(sq "$v")" >> "$out"
  done
}

# Common env set for a mocked run (STATE = the standard isolated state).
envs_for() {  # <tid> <pane> [extra KEY=VALUE...] → files $SCRATCH/<tid>.env
  local tid="$1" pane="$2"; shift 2
  write_envs "$SCRATCH/$tid.env" \
    "FLEET_STATE_HOME=$STATE" \
    "MOCK_RECORD=$SCRATCH/$tid.record" \
    "MOCK_COPIED_PROMPT=$SCRATCH/$tid.copy" \
    "MOCK_PANE_ID=$pane" \
    "MOCK_WT_PATH=$WT" \
    "MOCK_TREE_LOG=$SCRATCH/$tid.tree" \
    "HOME=$HOME_DIR" \
    "PATH=$MOCK_BIN:$PATH" \
    "$@"
}

# Launch the REAL launcher in background from a RUNNER FILE (env lines are
# read verbatim, so values with backticks/$/quotes are never re-interpreted by
# the test shell); the bg job is a DIRECT child of this shell, so wait_pid can
# wait on it. Sets the global LAST_PID; launcher output → $SCRATCH/<tid>.out.
launch_bg() {  # <tid> <env-file> <launcher args...>
  local tid="$1" envf="$2"; shift 2
  local runner="$SCRATCH/$tid.runner"
  {
    printf 'set -a\n'
    cat "$envf"
    printf 'set +a\nexec "$@"\n'
  } > "$runner"
  env -i /usr/bin/env bash "$runner" bash "$LAUNCHER" "$@" >"$SCRATCH/$tid.out" 2>&1 &
  LAST_PID=$!
}

# Feed the done-marker early (the launcher picks it up when it reaches the
# done-wait loop — never before `agent start`, since the file it reads is
# written only after start).
feed_done() {  # <tid> <summary>
  jq -nc --arg s "$2" '{status:"done",summary:$s,changedFiles:[]}' > "$STATE/$1.done.json"
}

# --- argv-block extraction from a mock record -------------------------------
# The `MOCK agent start` block is: PAPANE line + ARGn= lines + ARG_AT_* /
# PROMPT_EXISTS lines, terminated by the next `MOCK ` line.
start_argvs() {  # <tid> → ARGn values in order, one per line
  awk 'BEGIN{f=0} /^MOCK agent start$/{f=1;next} /^MOCK /{f=0} f && /^ARG[0-9]+=/{sub(/^ARG[0-9]+=/,"");print}' "$SCRATCH/$1.record"
}
at_arg() { start_argvs "$1" | sed -n "$2p"; }         # 1-based line of ARGn
at_arg_count() { start_argvs "$1" | wc -l | tr -d ' '; }
at_arg_files() { start_argvs "$1" | grep -c '^@'; }   # count of @-args

# Suffix byte-compare: the complete expected CHILD_PROMPT ENDS with
# "The task is: <brief>\n" (brief without its trailing newline, exactly as the
# launcher embeds it). Build the reference suffix and cmp the copy's tail.
assert_prompt_suffix() {  # <copy-file> <brief-file>
  local copy="$1" brief="$2"
  local ref="$SCRATCH/ref.suffix"
  # $(cat ...) strips trailing newlines — exactly how the launcher embeds the
  # brief; the prompt then adds exactly one '\n'.
  { printf 'The task is: '; printf '%s' "$(cat "$brief")"; printf '\n'; } > "$ref"
  local flen rlen
  flen="$(wc -c < "$copy" | tr -d ' ')"
  rlen="$(wc -c < "$ref" | tr -d ' ')"
  [[ "$flen" -ge "$rlen" ]] || return 1
  cmp -s "$ref" <(tail -c "$rlen" "$copy")
}

# Standard absence assertions (issue test-plan point 5) for a completed run.
assert_no_delivery_machinery() {  # <tid> <out-file>
  local tid="$1" out="$2"
  local rc=0
  if grep -q 'MOCK agent prompt' "$SCRATCH/$tid.record" 2>/dev/null; then log "  FAIL no-prompt: 'agent prompt' was called"; rc=1; fi
  if grep -q 'MOCK agent get' "$SCRATCH/$tid.record" 2>/dev/null; then log "  FAIL no-poll: 'agent get' was called (readiness polling)"; rc=1; fi
  if grep -qi 'brief delivered' "$out" 2>/dev/null; then log "  FAIL no-log: 'brief delivered' found in launcher output"; rc=1; fi
  if grep -q 'interactive_ready' "$out" 2>/dev/null; then log "  FAIL no-wait: 'interactive_ready' found in launcher output"; rc=1; fi
  if grep -qE "not out of idle|didn't leave idle|startup" "$out" 2>/dev/null; then log "  FAIL no-wait: residual idle-wait log found"; rc=1; fi
  if grep -q 'agent wait' "$out" 2>/dev/null; then log "  FAIL no-wait: 'agent wait' used"; rc=1; fi
  if grep -q 'MOCK agent wait' "$SCRATCH/$tid.record" 2>/dev/null; then log "  FAIL no-wait: 'agent wait' called"; rc=1; fi
  return $rc
}

# ========================================================== S1 argv + done + cleanup ====
log "S1 — happy path: exactly one @argv (absolute, exists at start, complete bytes), done + cleanup"
S1_BRIEF="$SCRATCH/s1-brief.md"
cat > "$S1_BRIEF" <<'EOF'
S1 brief — plain text with some structure.
1. Be trivial. 2. Write the done marker.
EOF
envs_for s1 p1
launch_bg s1 "$SCRATCH/s1.env" "s1-title" "@$S1_BRIEF" --project "$PROJ" --task-id s1 --timeout-min 2
PID="$LAST_PID"
feed_done s1 "native ok s1"
wait_pid "$PID" 120; RC=$?
if [[ "$RC" -eq 0 ]]; then pass "S1.1 launcher exits 0 after the native-request task completes"; else fail "S1.1 rc=$RC (expected 0); out tail: $(tail -4 "$SCRATCH/s1.out" 2>/dev/null | tr '\n' ' ')"; fi
grep -q "native initial request handed to the child" "$SCRATCH/s1.out" \
  && pass "S1.2 native delivery log after start (no second prompt)" \
  || fail "S1.2 delivery log missing"
AT=$(at_arg s1 7)   # ARG6 (line 7) = the @file for the 7-arg start (no model)
AAC=$(at_arg_count s1); AFC=$(at_arg_files s1)
[[ "$AAC" -eq 7 ]] && pass "S1.3 start block has exactly 7 argv elements (got $AAC)" || fail "S1.3 argv count=$AAC (expected 7)"
[[ "$AFC" -eq 1 ]] && pass "S1.4 exactly one @ argument (got $AFC)" || fail "S1.4 @-arg count=$AFC (expected 1)"
[[ "$AT" == @"$STATE/s1.child-prompt.md" ]] \
  && pass "S1.5 @arg is the absolute per-task prompt path (intact)" \
  || fail "S1.5 @arg='$AT' (expected '@$STATE/s1.child-prompt.md')"
grep -q '^ARG_AT_INDEX=6$' "$SCRATCH/s1.record" \
  && pass "S1.6 the @file is the LAST argv element after --" \
  || fail "S1.6 ARG_AT_INDEX missing/not 6"
grep -q '^PROMPT_EXISTS=yes$' "$SCRATCH/s1.record" \
  && pass "S1.7 prompt file existed (regular) at agent start invocation" \
  || fail "S1.7 PROMPT_EXISTS != yes"
if [[ -f "$SCRATCH/s1.copy" ]]; then
  H1="$(head -1 "$SCRATCH/s1.copy")"
  [[ "$H1" == "You are a fleet sub-agent (task s1). Read the brief in:" ]] \
    && pass "S1.8 prompt bytes start with the fleet header (task id)" \
    || fail "S1.8 header line: '$H1'"
  L2="$(sed -n '2p' "$SCRATCH/s1.copy")"
  [[ "$L2" == "$STATE/tasks/s1.brief.md" ]] \
    && pass "S1.9 prompt names the durable brief file on line 2" \
    || fail "S1.9 line2='$L2'"
  grep -q "DELIVERY POSTURE: no-mistakes" "$SCRATCH/s1.copy" && grep -q "RUNTIME RULES (T-019)" "$SCRATCH/s1.copy" \
    && grep -q "FORMATTING RULE" "$SCRATCH/s1.copy" \
    && pass "S1.10 wrapper blocks present (posture/runtime/formatting)" \
    || fail "S1.10 wrapper blocks incomplete"
  grep -qF "$STATE/s1.done.json" "$SCRATCH/s1.copy" && grep -qF "$STATE/s1.needs-input.json" "$SCRATCH/s1.copy" \
    && pass "S1.11 done/needs-input paths embedded with the task id" \
    || fail "S1.11 path substitution missing"
  assert_prompt_suffix "$SCRATCH/s1.copy" "$S1_BRIEF" \
    && pass "S1.12 prompt bytes END byte-identical with 'The task is: <brief>'" \
    || fail "S1.12 brief suffix not byte-identical (content mangled?)"
else
  fail "S1.8-12 mock prompt copy missing (start block broken?)"
fi
assert_no_delivery_machinery s1 "$SCRATCH/s1.out" \
  && pass "S1.13 NO agent prompt / NO readiness wait / NO ACK retry / NO 'brief delivered'" \
  || fail "S1.13 leftover delivery machinery detected"
if [[ -f "$STATE/s1.json" ]]; then
  ST="$(jq -r '.state // ""' "$STATE/s1.json")"
  SM="$(jq -r '.summary // ""' "$STATE/s1.json")"
  [[ "$ST" == "done" && "$SM" == "native ok s1" ]] \
    && pass "S1.14 state=done with the done-marker summary" \
    || fail "S1.14 state=$ST summary='$SM'"
else
  fail "S1.14 state json missing"
fi
[[ ! -f "$STATE/s1.done.json" ]] && pass "S1.15 done-marker consumed" || fail "S1.15 done-marker still present"
grep -q 'MOCK tab close' "$SCRATCH/s1.record" && grep -q 'MOCK pane close' "$SCRATCH/s1.record" \
  && pass "S1.16 tab + pane closed" || fail "S1.16 tab/pane cleanup missing"
grep -q 'TREEHOUSE return' "$SCRATCH/s1.tree" && pass "S1.17 worktree released" || fail "S1.17 treehouse return missing"
[[ ! -e "$STATE/s1.child-prompt.md" ]] && pass "S1.18 transient prompt file removed at exit (EXIT trap)" \
  || fail "S1.18 prompt file left behind"
[[ -f "$STATE/tasks/s1.brief.md" ]] && pass "S1.19 durable brief file kept" || fail "S1.19 brief file removed (must NEVER happen)"

# ================================================ S2 path/brief metacharacters ====
log "S2 — FLEET_STATE_HOME + brief with spaces & shell metacharacters (argv intact, bytes exact)"
S2_STATE="$SCRATCH/s2 dir & \$'q;uote' \`tick\` *?x"
mkdir -p "$S2_STATE/tasks"
S2_BRIEF="$SCRATCH/s2-brief.md"
cat > "$S2_BRIEF" <<'EOF'
S2 metachar brief: dollars $HOME $VAR, backticks `date`, quotes 'and "both",
semicolons ; ampersands & pipes |, stars *, brackets [x], newline here.
Second line with {braces} and (parens).
EOF
write_envs "$SCRATCH/s2.env" \
  "FLEET_STATE_HOME=$S2_STATE" \
  "MOCK_RECORD=$SCRATCH/s2.record" \
  "MOCK_COPIED_PROMPT=$SCRATCH/s2.copy" \
  "MOCK_PANE_ID=p2" \
  "MOCK_WT_PATH=$WT" \
  "MOCK_TREE_LOG=$SCRATCH/s2.tree" \
  "HOME=$HOME_DIR" \
  "PATH=$MOCK_BIN:$PATH"
launch_bg s2 "$SCRATCH/s2.env" "s2-title" "@$S2_BRIEF" --project "$PROJ" --task-id s2 --timeout-min 2
PID="$LAST_PID"
jq -nc --arg s "native ok s2" '{status:"done",summary:$s,changedFiles:[]}' > "$S2_STATE/s2.done.json"
wait_pid "$PID" 120; RC=$?
[[ "$RC" -eq 0 ]] && pass "S2.1 launcher exits 0 with a metacharacter state path" || fail "S2.1 rc=$RC"
AT=$(at_arg s2 7)
[[ "$AT" == "@$S2_STATE/s2.child-prompt.md" ]] \
  && pass "S2.2 @arg intact (spaces+metachars, one argv element)" \
  || fail "S2.2 @arg='$AT' (expected '@$S2_STATE/s2.child-prompt.md')"
[[ "$(at_arg_count s2)" -eq 7 && "$(at_arg_files s2)" -eq 1 ]] \
  && pass "S2.3 still exactly one @ element, no splitting" \
  || fail "S2.3 argv count/@{count} wrong"
grep -q '^PROMPT_EXISTS=yes$' "$SCRATCH/s2.record" \
  && pass "S2.4 file with metachar path existed at invocation" || fail "S2.4 PROMPT_EXISTS != yes"
assert_prompt_suffix "$SCRATCH/s2.copy" "$S2_BRIEF" \
  && pass "S2.5 brief bytes with metacharacters round-trip byte-identical" \
  || fail "S2.5 metachar brief mangled"
[[ "$(head -1 "$SCRATCH/s2.copy")" == "You are a fleet sub-agent (task s2). Read the brief in:" ]] \
  && pass "S2.6 header intact" || fail "S2.6 header missing"
assert_no_delivery_machinery s2 "$SCRATCH/s2.out" \
  && pass "S2.7 zero delivery machinery on the metachar run" || fail "S2.7 leftover machinery"
if [[ -f "$S2_STATE/s2.json" && "$(jq -r '.state' "$S2_STATE/s2.json")" == "done" ]]; then
  pass "S2.8 state=done"
else
  fail "S2.8 state != done"
fi
[[ ! -e "$S2_STATE/s2.child-prompt.md" ]] && pass "S2.9 transient prompt removed" || fail "S2.9 prompt file left behind"

# ====================================================== S3 model separate pair ====
log "S3 — model arrives as a separate --model provider/id pair (not merged with @file)"
S3_BRIEF="$SCRATCH/s3-brief.md"
printf 'S3 brief\n' > "$S3_BRIEF"
envs_for s3 p3
launch_bg s3 "$SCRATCH/s3.env" "s3-title" "@$S3_BRIEF" --project "$PROJ" --task-id s3 --timeout-min 2 --model opencode/kimi-k2.6
PID="$LAST_PID"
feed_done s3 "native ok s3"
wait_pid "$PID" 120; RC=$?
[[ "$RC" -eq 0 ]] && pass "S3.1 launcher exits 0 with --model override" || fail "S3.1 rc=$RC"
[[ "$(at_arg_count s3)" -eq 9 ]] && pass "S3.2 start block has 9 argv elements (name,kind,pane,pair,file)" || fail "S3.2 argv count=$(at_arg_count s3) (expected 9)"
[[ "$(at_arg s3 7)" == "--model" && "$(at_arg s3 8)" == "opencode/kimi-k2.6" ]] \
  && pass "S3.3 --model provider/id is a clean separate pair" \
  || fail "S3.3 pair wrong: '$(at_arg s3 7)' '$(at_arg s3 8)'"
[[ "$(at_arg s3 9)" == "@$STATE/s3.child-prompt.md" && "$(at_arg_files s3)" -eq 1 ]] \
  && pass "S3.4 @file is a SEPARATE argv element (one @ total)" \
  || fail "S3.4 @file merged into the model pair?"
grep -q 'child model (override): opencode/kimi-k2.6' "$SCRATCH/s3.out" \
  && pass "S3.5 launcher logged the qualified override" || fail "S3.5 override log missing"
assert_no_delivery_machinery s3 "$SCRATCH/s3.out" \
  && pass "S3.6 zero delivery machinery (with model pair too)" || fail "S3.6 leftover machinery"

# ==================================================== S4 start failure ====
log "S4 — agent start failure → failed state, cleanup, NOT stranded in spawning"
S4_BRIEF="$SCRATCH/s4-brief.md"
printf 'S4 brief\n' > "$S4_BRIEF"
write_envs "$SCRATCH/s4.env" \
  "FLEET_STATE_HOME=$STATE" \
  "MOCK_RECORD=$SCRATCH/s4.record" \
  "MOCK_COPIED_PROMPT=$SCRATCH/s4.copy" \
  "MOCK_PANE_ID=p4" \
  "MOCK_WT_PATH=$WT" \
  "MOCK_TREE_LOG=$SCRATCH/s4.tree" \
  "HOME=$HOME_DIR" \
  "PATH=$MOCK_BIN:$PATH" \
  "MOCK_START_FAIL=1"
launch_bg s4 "$SCRATCH/s4.env" "s4-title" "@$S4_BRIEF" --project "$PROJ" --task-id s4 --timeout-min 2
PID="$LAST_PID"
wait_pid "$PID" 120; RC=$?
[[ "$RC" -eq 1 ]] && pass "S4.1 launcher exits 1 after 4 failed start attempts" || fail "S4.1 rc=$RC (expected 1)"
[[ "$(grep -c '^MOCK agent start$' "$SCRATCH/s4.record")" -eq 4 ]] \
  && pass "S4.2 start retried 4× (same agent name, no dupes)" \
  || fail "S4.2 start attempt count=$(grep -c '^MOCK agent start$' "$SCRATCH/s4.record") (expected 4)"
grep -q 'agent start failed' "$SCRATCH/s4.out" && pass "S4.3 failure logged" || fail "S4.3 failure log missing"
ST="$(jq -r '.state // ""' "$STATE/s4.json" 2>/dev/null)"
SM="$(jq -r '.summary // ""' "$STATE/s4.json" 2>/dev/null)"
[[ "$ST" == "failed" && "$SM" == *"agent start failed"* ]] \
  && pass "S4.4 state=failed with the start-failure summary" \
  || fail "S4.4 state=$ST summary='$SM'"
grep -q 'MOCK tab close' "$SCRATCH/s4.record" && grep -q 'MOCK pane close' "$SCRATCH/s4.record" \
  && pass "S4.5 tab + pane closed after start failure" || fail "S4.5 cleanup missing"
grep -q 'TREEHOUSE return' "$SCRATCH/s4.tree" && pass "S4.6 worktree released" || fail "S4.6 treehouse return missing"
[[ ! -e "$STATE/s4.child-prompt.md" ]] && pass "S4.7 transient prompt removed on failure" || fail "S4.7 prompt file left behind"

# ============================ S5 missing/unreadable prompt file → failed state ====
log "S5 — prompt-file cannot be installed (destination blocked) → failed state, no start, cleanup"
mkdir -p "$STATE/s5.child-prompt.md"     # a DIRECTORY at the prompt path: mv cannot install over it
S5_BRIEF="$SCRATCH/s5-brief.md"
printf 'S5 brief\n' > "$S5_BRIEF"
envs_for s5 p5
launch_bg s5 "$SCRATCH/s5.env" "s5-title" "@$S5_BRIEF" --project "$PROJ" --task-id s5 --timeout-min 2
PID="$LAST_PID"
wait_pid "$PID" 120; RC=$?
[[ "$RC" -eq 1 ]] && pass "S5.1 launcher exits 1 when the prompt file is not installable" || fail "S5.1 rc=$RC (expected 1)"
grep -E 'cannot install the child prompt file|child prompt file missing/empty/unreadable|child prompt path not absolute' "$SCRATCH/s5.out" \
  && pass "S5.2 pre-start prompt-file guard message logged" \
  || fail "S5.2 prompt-file guard message missing"
grep -q 'MOCK agent start' "$SCRATCH/s5.record" \
  && fail "S5.3 agent start was called with a broken prompt file!" \
  || pass "S5.3 NO agent start with a missing/blocked prompt file"
ST="$(jq -r '.state // ""' "$STATE/s5.json" 2>/dev/null)"
[[ "$ST" == "failed" ]] && pass "S5.4 state=failed (never stranded in spawning)" || fail "S5.4 state=$ST (expected failed)"
grep -q 'MOCK tab close' "$SCRATCH/s5.record" && grep -q 'MOCK pane close' "$SCRATCH/s5.record" \
  && pass "S5.5 tab + pane closed" || fail "S5.5 cleanup missing"
grep -q 'TREEHOUSE return' "$SCRATCH/s5.tree" && pass "S5.6 worktree released" || fail "S5.6 treehouse return missing"

# ==================================================== S6 concurrency (3 tasks) ====
log "S6 — 3 concurrent tasks, shared state, distinct ids/panes/agents, NO prompt cross-contamination"
S6A_BRIEF="$SCRATCH/s6a-brief.md"; S6B_BRIEF="$SCRATCH/s6b-brief.md"; S6C_BRIEF="$SCRATCH/s6c-brief.md"
printf 'UNIQUE-MARKER-S6A alpha\n' > "$S6A_BRIEF"
printf 'UNIQUE-MARKER-S6B beta\n'  > "$S6B_BRIEF"
printf 'UNIQUE-MARKER-S6C gamma\n' > "$S6C_BRIEF"
for tid in s6a s6b s6c; do envs_for "$tid" "p6$tid"; done
launch_bg s6a "$SCRATCH/s6a.env" "s6a-title" "@$S6A_BRIEF" --project "$PROJ" --task-id s6a --timeout-min 2
PIDA="$LAST_PID"
launch_bg s6b "$SCRATCH/s6b.env" "s6b-title" "@$S6B_BRIEF" --project "$PROJ" --task-id s6b --timeout-min 2
PIDB="$LAST_PID"
launch_bg s6c "$SCRATCH/s6c.env" "s6c-title" "@$S6C_BRIEF" --project "$PROJ" --task-id s6c --timeout-min 2
PIDC="$LAST_PID"
feed_done s6a "s6a done"; feed_done s6b "s6b done"; feed_done s6c "s6c done"
wait_pid "$PIDA" 120; RCA=$?; wait_pid "$PIDB" 120; RCB=$?; wait_pid "$PIDC" 120; RCC=$?
[[ "$RCA" -eq 0 && "$RCB" -eq 0 && "$RCC" -eq 0 ]] \
  && pass "S6.1 all 3 launchers exit 0" || fail "S6.1 rc a/b/c = $RCA/$RCB/$RCC"
for tid in s6a s6b s6c; do
  AT=$(at_arg "$tid" 7)
  [[ "$AT" == "@$STATE/$tid.child-prompt.md" ]] \
    && pass "S6.2 [$tid] @arg points at its OWN prompt file" \
    || fail "S6.2 [$tid] @arg='$AT'"
  grep -q '^PROMPT_EXISTS=yes$' "$SCRATCH/$tid.record" \
    && pass "S6.3 [$tid] prompt file existed at start" || fail "S6.3 [$tid] PROMPT_EXISTS != yes"
done
grep -q 'UNIQUE-MARKER-S6A' "$SCRATCH/s6a.copy" && ! grep -q 'UNIQUE-MARKER-S6B\|UNIQUE-MARKER-S6C' "$SCRATCH/s6a.copy" \
  && pass "S6.4a s6a prompt contains only its own brief" || fail "S6.4a s6a cross-contaminated"
grep -q 'UNIQUE-MARKER-S6B' "$SCRATCH/s6b.copy" && ! grep -q 'UNIQUE-MARKER-S6A\|UNIQUE-MARKER-S6C' "$SCRATCH/s6b.copy" \
  && pass "S6.4b s6b prompt contains only its own brief" || fail "S6.4b s6b cross-contaminated"
grep -q 'UNIQUE-MARKER-S6C' "$SCRATCH/s6c.copy" && ! grep -q 'UNIQUE-MARKER-S6A\|UNIQUE-MARKER-S6B' "$SCRATCH/s6c.copy" \
  && pass "S6.4c s6c prompt contains only its own brief" || fail "S6.4c s6c cross-contaminated"
NA=$(grep '^ARG0=' "$SCRATCH/s6a.record" | head -1); NB=$(grep '^ARG0=' "$SCRATCH/s6b.record" | head -1); NC=$(grep '^ARG0=' "$SCRATCH/s6c.record" | head -1)
[[ -n "$NA" && "$NA" != "$NB" && "$NB" != "$NC" && "$NA" != "$NC" ]] \
  && pass "S6.5 distinct agent names per task ($NA / $NB / $NC)" \
  || fail "S6.5 duplicate agent names: $NA | $NB | $NC"
PA=$(grep '^PANE=' "$SCRATCH/s6a.record" | head -1); PB=$(grep '^PANE=' "$SCRATCH/s6b.record" | head -1); PC=$(grep '^PANE=' "$SCRATCH/s6c.record" | head -1)
[[ "$PA" == "PANE=p6s6a" && "$PB" == "PANE=p6s6b" && "$PC" == "PANE=p6s6c" ]] \
  && pass "S6.6 each task targeted its own pane (no pane sharing)" \
  || fail "S6.6 panes: $PA | $PB | $PC"
for tid in s6a s6b s6c; do
  grep -q 'MOCK agent prompt' "$SCRATCH/$tid.record" && fail "S6.7 [$tid] agent prompt called!" \
    || pass "S6.7 [$tid] zero agent prompt"
done
for tid in s6a s6b s6c; do
  ST="$(jq -r '.state // ""' "$STATE/$tid.json" 2>/dev/null)"
  [[ "$ST" == "done" ]] || fail "S6.8 [$tid] state=$ST"
done
[[ "$ST" == "done" ]] && pass "S6.8 all concurrent states=done"
[[ ! -e "$STATE/s6a.child-prompt.md" && ! -e "$STATE/s6b.child-prompt.md" && ! -e "$STATE/s6c.child-prompt.md" ]] \
  && pass "S6.9 all transient prompts removed after their own exits" \
  || fail "S6.9 some transient prompt left behind"
[[ -f "$STATE/tasks/s6a.brief.md" && -f "$STATE/tasks/s6b.brief.md" && -f "$STATE/tasks/s6c.brief.md" ]] \
  && pass "S6.10 all durable briefs kept" || fail "S6.10 durable brief lost"

# ==================================================== S7 --resume rebuild ====
log "S7 — --resume mocked relaunch: prompt REBUILT with the resume notice, no manual prompt"
RES_CWD="$SCRATCH/res-repo"
mkdir -p "$RES_CWD"
( cd "$RES_CWD" \
    && git init -q \
    && git config user.name "fleet-smoke" \
    && git config user.email "fleet-smoke@localhost" \
    && printf 'resume repo\n' > README.md \
    && git add README.md \
    && git commit -qm "wip base" \
    && git branch -M fleet/res-test ) || die "resume scratch repo failed"
RES_BASE="$(git -C "$RES_CWD" rev-parse HEAD)"
RES_BRIEF="$STATE/tasks/s7.brief.md"
printf 'RESUME-BRIEF-7 resume content\n' > "$RES_BRIEF"
jq -n --arg id s7 --arg title "s7 resume title" --arg proj "$RES_CWD" --arg cwd "$RES_CWD" --arg brief "$RES_BRIEF" \
  '{id:$id,title:$title,project:$proj,cwd:$cwd,briefFile:$brief,state:"running",groupId:"s7",nested:false,depth:1,deliveryPosture:"no-mistakes",timeoutMs:120000,bashTimeoutS:300}' \
  > "$STATE/s7.json"
jq -n --arg base "$RES_BASE" --arg branch fleet/res-test --arg reason "watchdog test" --arg at "1700000000000" \
  '{base:$base,branch:$branch,reason:$reason,at:($at|tonumber)}' > "$STATE/s7.relaunch"
envs_for s7 p7
launch_bg s7 "$SCRATCH/s7.env" --resume s7
PID="$LAST_PID"
feed_done s7 "resume ok s7"
wait_pid "$PID" 120; RC=$?
[[ "$RC" -eq 0 ]] && pass "S7.1 resumed launcher exits 0" || fail "S7.1 rc=$RC"
grep -q "resume: s7 on fleet/res-test" "$SCRATCH/s7.out" \
  && pass "S7.2 resume branch re-alignment logged" || fail "S7.2 resume log missing"
grep -q "resume: transient child prompt rebuilt for the resumed task" "$SCRATCH/s7.out" \
  && pass "S7.3 prompt REBUILT on resume (never reused a deleted file)" || fail "S7.3 rebuild log missing"
AT=$(at_arg s7 7)
[[ "$AT" == "@$STATE/s7.child-prompt.md" ]] \
  && pass "S7.4 fresh @file in the resumed agent start argv" || fail "S7.4 @arg='$AT'"
grep -q 'RESUME NOTICE (T-019' "$SCRATCH/s7.copy" \
  && grep -q "Continue the ORIGINAL brief: $RES_BRIEF" "$SCRATCH/s7.copy" \
  && grep -q 'RESUME-BRIEF-7 resume content' "$SCRATCH/s7.copy" \
  && pass "S7.5 rebuilt prompt carries the resume notice + original brief" \
  || fail "S7.5 resume prompt content incomplete"
grep -q '^PROMPT_EXISTS=yes$' "$SCRATCH/s7.record" \
  && pass "S7.6 rebuilt file existed at (re)start" || fail "S7.6 PROMPT_EXISTS != yes"
assert_no_delivery_machinery s7 "$SCRATCH/s7.out" \
  && pass "S7.7 no manual prompt on resume (single native start)" || fail "S7.7 leftover machinery on resume"
ST="$(jq -r '.state // ""' "$STATE/s7.json" 2>/dev/null)"
RL="$(jq -r '.relaunches | length // 0' "$STATE/s7.json" 2>/dev/null)"
[[ "$ST" == "done" && "$RL" -eq 1 ]] \
  && pass "S7.8 state=done + relaunches[] recorded once" \
  || fail "S7.8 state=$ST relaunches=$RL"
[[ "$(jq -r '.relaunches[0].branch // ""' "$STATE/s7.json" 2>/dev/null)" == "fleet/res-test" ]] \
  && pass "S7.9 relaunch plan branch recorded" || fail "S7.9 relaunch branch missing"
[[ ! -f "$STATE/s7.relaunch" ]] && pass "S7.10 relaunch plan consumed" || fail "S7.10 plan not consumed"
grep -q 'MOCK tab close' "$SCRATCH/s7.record" && grep -q 'TREEHOUSE return' "$SCRATCH/s7.tree" \
  && pass "S7.11 resumed run cleaned up (tab + worktree)" || fail "S7.11 resume cleanup missing"
[[ ! -e "$STATE/s7.child-prompt.md" ]] && pass "S7.12 transient prompt removed after resume" || fail "S7.12 prompt file left behind"

# ==================================================== S8 installed-Pi parseArgs ====
log "S8 — installed-Pi parseArgs fixture (read-only, no credentials)"
PI_PKG="${PI_PKG:-}"
if [[ -z "$PI_PKG" ]] && [[ -d "/opt/nodejs/lib/node_modules/@earendil-works/pi-coding-agent" ]]; then
  PI_PKG="/opt/nodejs/lib/node_modules/@earendil-works/pi-coding-agent"
fi
if [[ -z "$PI_PKG" && -x "$(command -v pi)" ]]; then
  _p="$(readlink -f "$(command -v pi)" 2>/dev/null || command -v pi)"
  _dir="$(dirname "$(dirname "$_p")")"
  [[ -f "$_dir/dist/cli/args.js" ]] && PI_PKG="$_dir"
fi
if [[ -z "$PI_PKG" || ! -f "$PI_PKG/dist/cli/args.js" ]]; then
  log "  S8 SKIPPED (documented): installed pi package not discoverable — set PI_PKG=<pkg root> to force"
  pass "S8 (skipped-documented: installed pi package not found)"
elif ! command -v node >/dev/null 2>&1; then
  log "  S8 SKIPPED (documented): node not in PATH"
  pass "S8 (skipped-documented: node not found)"
else
  FIXTURE_PATH="$SCRATCH/fixture dir with spaces & \$'q' \`tick\`/p.child-prompt.md"
  mkdir -p "$(dirname "$FIXTURE_PATH")"
  node - "$PI_PKG" "$FIXTURE_PATH" <<'NEOF' && pass "S8 parseArgs: one @file (absolute+intact), model separate, no extra message" || fail "S8 parseArgs fixture failed"
const pkg = process.argv[2];
const expected = process.argv[3];
const { parseArgs } = require(pkg + '/dist/cli/args.js');
// the launcher invocation shape: -- [--model provider/id] @<absolute-file>
const r = parseArgs(['--model', 'opencode/kimi-k2.6', '--', '@' + expected]);
const ok =
  Array.isArray(r.fileArgs) && r.fileArgs.length === 1 &&
  r.fileArgs[0] === expected &&
  r.model === 'opencode/kimi-k2.6' &&
  (!r.messages || r.messages.length === 0);
if (!ok) { console.error(JSON.stringify(r)); process.exit(1); }
console.log('parsed: fileArgs=' + JSON.stringify(r.fileArgs) + ' model=' + r.model);
NEOF
fi

# ==================================================== S9 textual baseline ====
log "S9 — launcher source: native-only delivery, no leftover machinery"
if ! grep -Eq 'herdr_cli agent prompt|agent prompt "\$PANE' "$LAUNCHER"; then
  pass "S9.1 zero 'agent prompt' CALLS in the launcher (comments only)"
else
  fail "S9.1 a 'agent prompt' call is still present"
fi
if grep -q 'agent start .*-- "\${MODEL_ARGS\[@\]}" "@\$CHILD_PROMPT_PATH"' "$LAUNCHER"; then
  pass "S9.2 agent start argv: -- model-pair @\$CHILD_PROMPT_PATH (one @ element)"
else
  fail "S9.2 native argv wiring missing"
fi
for pat in 'agent wait' 'interactive_ready' 'FLEET_STARTUP_WAIT' 'PROMPT_ATTEMPTS_MAX' 'prompt_consumed' 'SESSION_SNAPSHOT' 'PRE_START_REVISION' 'startup_started' 'file_sizes'; do
  if grep -q "$pat" "$LAUNCHER"; then fail "S9.3 leftover '$pat' found"; else pass "S9.3 no leftover '$pat'"; fi
done
if ! grep -qi 'brief delivered' "$LAUNCHER"; then
  pass "S9.4 no 'brief delivered' log anywhere (test-plan point 5)"
else
  fail "S9.4 'brief delivered' still logged"
fi
if grep -q 'trap .remove_child_prompt. EXIT' "$LAUNCHER"; then
  pass "S9.5 EXIT-trap removal of the transient prompt present"
else
  fail "S9.5 EXIT trap missing"
fi
if grep -q 'CHILD_PROMPT_PATH="\$STATE_HOME/\$TASK_ID.child-prompt.md"' "$LAUNCHER"; then
  pass "S9.6 prompt path = \$STATE_HOME/<task-id>.child-prompt.md"
else
  fail "S9.6 prompt path naming missing"
fi
if grep -q 'umask 077' "$LAUNCHER"; then
  pass "S9.7 umask 077 on the prompt write"
else
  fail "S9.7 umask 077 missing"
fi

# ---------------------------------------------------------------- result ---
BK="$(basename "$0")"
log "OUTCOME: $OK checks green ($BK)"
[[ $OK -ge 84 ]] || die "not all native-initial-request smoke checks passed ($OK < 84)"
exit 0