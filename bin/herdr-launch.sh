#!/usr/bin/env bash
# pi-fleet · task launcher (CLI for M1, called by the extension for M2+).
#
# Spawns a "visible" sub-agent: creates a real herdr pane (lateral split in the
# caller's current tab) with pi inside, hands it a brief, and on completion
# (disk done-marker) reports the result, closes the pane and releases the worktree.
#
# Usage:
#   bin/herdr-launch.sh "<title>" "<brief>" [flags]
#   bin/herdr-launch.sh "<title>" @file-brief.md [flags]
#
# Flags:
#   --project <path>     working repo (default: current dir)
#   --no-worktree        disable treehouse (default: worktree YES)
#   --timeout-min <n>    done-marker wait timeout (default: 360 = 6h)
#   --task-id <id>       explicit task id (default: generated)
#   --model <prov/mod>   child model override (default: inherited from parent)
#   --session <name>     herdr session (default: HERDR_SESSION | "default")
#   --delivery-posture <p>  task delivery posture (no-mistakes|direct-PR|local-only|yolo, default: no-mistakes)
#   --group-fail-policy <p>  waitAll (default) | immediate: a failed group task wakes the captain immediately
#   --nested              T-013: nested orchestrator opt-in — the child session gets the
#                         fleet_* tools + a subtree-scoped watcher (fleet_notice/group digests)
#   --depth <n>           T-013: the child's own depth (captain=0; +1 per nesting level; default 1)
#   --parent-task-id <id> T-013: task id that launched this child (empty for captain launches)
#   --gate              mechanical gate active (T-011): the launcher re-runs the anti-fraud gate itself
#                       at task end; the child receives the GATE section in the prompt (only no-mistakes posture)
#   --auto-pr <bool>    automatic PR on green gate (true|false, from gate.yaml). Merge NEVER automatic.
#   --bash-timeout-s <n> per-command bash tolerance for the child (T-019): the pane-health
#                        watchdog reports 'command timeout' when a single command has no
#                        context growth for this many seconds. Range 120..300, default 300.
#                        Legit long commands = explicit `timeout` wrapper in the brief or
#                        a higher configured tolerance.
#   --resume <taskId>    T-019 watchdog relaunch: REUSES the existing worktree (state.cwd),
#                        re-aligns the fleet/<taskid>-* branch on the last WIP commit, opens
#                        a FRESH pane/tab with the SAME brief and preserves the task registry
#                        (groupId, nested, depth — untouched). The small plan lives in
#                        <id>.relaunch (written by bin/fleet-relaunch.sh before the kill).
#   --debug              print raw output of herdr commands
set -u

# ---------------------------------------------------------------- config ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE_RUN="$SCRIPT_DIR/gate-run.sh"   # resolved relative to its own dir: no hardcoded absolute paths
FM_DEBUG=0
SESSION="${HERDR_SESSION:-default}"
PROJECT="$(pwd)"
USE_WORKTREE=1
TIMEOUT_MIN=360
TASK_ID_OVERRIDE=""
MODEL_OVERRIDE=""
BASH_TIMEOUT_S=300
RESUME_TASK_ID=""
GROUP_ID=""
GROUP_LABEL=""
GROUP_MODE="barrier"
KIND="ship"
DELIVERY_POSTURE="no-mistakes"
GROUP_FAIL_POLICY="waitAll"
NESTED=0
CHILD_DEPTH=1
PARENT_TASK_ID=""
GATE_ACTIVE=0
AUTO_PR="false"
TITLE=""
BRIEF=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --no-worktree) USE_WORKTREE=0; shift ;;
    --timeout-min) TIMEOUT_MIN="$2"; shift 2 ;;
    --task-id) TASK_ID_OVERRIDE="$2"; shift 2 ;;
    --model) MODEL_OVERRIDE="$2"; shift 2 ;;
    --session) SESSION="$2"; shift 2 ;;
    --group-id) GROUP_ID="$2"; shift 2 ;;
    --group-label) GROUP_LABEL="$2"; shift 2 ;;
    --group-mode) GROUP_MODE="$2"; shift 2 ;;
    --kind) KIND="$2"; shift 2 ;;
    --delivery-posture) DELIVERY_POSTURE="$2"; shift 2 ;;
    --group-fail-policy) GROUP_FAIL_POLICY="$2"; shift 2 ;;
    --nested) NESTED=1; shift ;;
    --depth) CHILD_DEPTH="$2"; shift 2 ;;
    --parent-task-id) PARENT_TASK_ID="$2"; shift 2 ;;
    --gate) GATE_ACTIVE=1; shift ;;
    --auto-pr) AUTO_PR="$2"; shift 2 ;;
    --bash-timeout-s) BASH_TIMEOUT_S="$2"; shift 2 ;;
    --resume) RESUME_TASK_ID="$2"; shift 2 ;;
    --debug) FM_DEBUG=1; shift ;;
    -h|--help) sed -n '1,24p' "$0"; exit 0 ;;
    *)
      if [[ -z "$TITLE" ]]; then TITLE="$1"; shift
      elif [[ -z "$BRIEF" ]]; then BRIEF="$1"; shift
      else echo "error: unexpected arguments: $*" >&2; exit 2; fi ;;
  esac
done

[[ -z "$TITLE" ]] && [[ -z "$RESUME_TASK_ID" ]] && { echo "error: missing title" >&2; exit 2; }
if [[ "$PROJECT" == "$HOME" ]]; then
  echo "warning: no explicit --project, cwd = HOME. Pass --project <path>." >&2
fi
[[ -z "$BRIEF" ]] && [[ -z "$RESUME_TASK_ID" ]] && { echo "error: missing brief" >&2; exit 2; }

STATE_HOME="${FLEET_STATE_HOME:-$HOME/.pi/fleet}"
mkdir -p "$STATE_HOME/tasks"

log()  { printf '[fleet] %s\n' "$*"; }
herr() { printf '[fleet] ERROR: %s\n' "$*" >&2; }

# T-019: clamp the per-command bash tolerance to the 120..300s range (default 300).
case "$BASH_TIMEOUT_S" in ''|*[!0-9]*) BASH_TIMEOUT_S=300 ;;
  *) if [ "$BASH_TIMEOUT_S" -lt 120 ] || [ "$BASH_TIMEOUT_S" -gt 300 ]; then
       herr "--bash-timeout-s $BASH_TIMEOUT_S out of range (120..300): falling back to 300"
       BASH_TIMEOUT_S=300
     fi ;;
esac

# T-029: the CHILD_PROMPT is delivered as pi's NATIVE initial request — `agent
# start` carries `@<prompt-file>` in its argv and pi's interactive mode reads the
# file and prompts the session BEFORE the main loop. `agent prompt` is never
# called for the brief, so there is no delivery race to ACK. The only residual
# check (fail-soft, NEVER re-sends) is that the child LEFT `idle` (started the
# initial request); a frozen/empty pane is caught by the §7 done-wait liveness
# gate. Env-overridable — the headless smoke tests/smoke-prompt-ack.sh drives
# them down to keep the run fast:
#   STARTUP_WAIT_TRIES × STARTUP_WAIT_SLEEP : bounded wait for the child to
#     leave idle (status/revision/session-file growth) after `agent start`.
STARTUP_WAIT_TRIES="${FLEET_STARTUP_WAIT_TRIES:-5}"
STARTUP_WAIT_SLEEP="${FLEET_STARTUP_WAIT_SLEEP:-3}"
clamp_int() {  # name min max — sanitize + clamp a numeric knob
  local name="$1" min="$2" max="$3" v
  eval "v=\${$name:-}"
  case "$v" in ''|*[!0-9]*) v="$min" ;; esac
  [[ "$v" -lt "$min" ]] && v="$min"
  [[ "$v" -gt "$max" ]] && v="$max"
  eval "$name=$v"
}
clamp_int STARTUP_WAIT_TRIES 1 20
clamp_int STARTUP_WAIT_SLEEP 1 10

# Marks failed on premature launcher exit (failed tab/agent/prompt):
# without this the state stays 'spawning' and the task dies SILENTLY (the watcher
# does not wake on spawning).
fail_task() {
  local why="${1:-launcher error}"
  jq --arg done "$(date +%s)000" --arg sum "$why" \
    '.state="failed" | .doneAt=($done|tonumber) | .summary=$sum' "$STATE_JSON" \
    > "$STATE_JSON.tmp" 2>/dev/null && mv "$STATE_JSON.tmp" "$STATE_JSON"
}

# Updates state on disk robustly (jq, not sed).
set_state() {
  local val="$1" done_ms="${2:-}"
  local patch=".state = \"$val\""
  [[ -n "$done_ms" ]] && patch="$patch | .doneAt = $done_ms"
  jq "$patch" "$STATE_JSON" > "$STATE_JSON.tmp" 2>/dev/null && mv "$STATE_JSON.tmp" "$STATE_JSON"
}

# Writes pane/tab/workspace into the json AFTER the tab create (atomic).
add_pane_ids() {
  jq --arg p "$PANE_ID" --arg t "$TAB_ID" --arg w "$WORKSPACE" \
    '.paneId=$p | .tabId=$t | .workspaceId=$w' "$STATE_JSON" \
    > "$STATE_JSON.tmp" 2>/dev/null && mv "$STATE_JSON.tmp" "$STATE_JSON"
}

# Enable debugging for herdr calls
herdr_cli() {
  if [[ "$FM_DEBUG" == 1 ]]; then
    echo "  → herdr $*" >&2
  fi
  herdr --session "$SESSION" "$@" 2>&1
}

# Reads a brief from a file if it starts with @
if [[ "$BRIEF" == @* ]]; then
  BRIEF_FILE="${BRIEF#@}"
  [[ -f "$BRIEF_FILE" ]] || { herr "brief file not found: $BRIEF_FILE"; exit 2; }
  BRIEF_CONTENT="$(cat "$BRIEF_FILE")"
else
  BRIEF_CONTENT="$BRIEF"
fi

# ------------------------------------------------------- T-019 resume ----
# Watchdog relaunch (--resume <taskId>): the task state json already exists
# (state=running, groupId/nested/depth/gate untouched). We reuse the existing
# worktree (state.cwd), re-align the fleet/<taskid>-* branch on the last WIP
# commit (the salvage base recorded in <id>.relaunch), and open a FRESH pane/
# tab with the SAME brief. The task registry stays consistent: this launcher
# instance owns the pane teardown at the end and releases the worktree.
RESUME_BASE=""
RESUME_BRANCH=""
RESUME_REASON=""
RESUME_AT=""
if [[ -n "$RESUME_TASK_ID" ]]; then
  RESUME_STATE_JSON="$STATE_HOME/$RESUME_TASK_ID.json"
  [[ -f "$RESUME_STATE_JSON" ]] || { herr "--resume: task state not found: $RESUME_STATE_JSON"; exit 2; }
  TASK_ID="$RESUME_TASK_ID"
  TITLE="$(jq -r '.title // empty' "$RESUME_STATE_JSON" 2>/dev/null)"
  RESUME_CWD="$(jq -r '.cwd // empty' "$RESUME_STATE_JSON" 2>/dev/null)"
  [[ -n "$RESUME_CWD" && -d "$RESUME_CWD" ]] || { herr "--resume: worktree missing: '$RESUME_CWD' (treehouse released it?)"; exit 2; }
  [[ -d "$RESUME_CWD/.git" || -f "$RESUME_CWD/.git" ]] || { herr "--resume: not a git repo: $RESUME_CWD"; exit 2; }
  PROJECT="$(jq -r '.project // ""' "$RESUME_STATE_JSON" 2>/dev/null)"
  BRIEF="$(jq -r '.briefFile // empty' "$RESUME_STATE_JSON" 2>/dev/null)"
  [[ -n "$BRIEF" && -f "$BRIEF" ]] || { herr "--resume: brief file missing: $BRIEF"; exit 2; }
  BRIEF_CONTENT="$(cat "$BRIEF")"
  _tm="$(jq -r '.timeoutMs // 0' "$RESUME_STATE_JSON" 2>/dev/null || echo 0)"
  case "$_tm" in ''|*[!0-9]*) _tm=0 ;; esac
  [[ "$_tm" -gt 0 ]] && TIMEOUT_MIN=$(( _tm / 60000 ))
  _bt="$(jq -r '.bashTimeoutS // 0' "$RESUME_STATE_JSON" 2>/dev/null || echo 0)"
  case "$_bt" in ''|*[!0-9]*) _bt=0 ;; esac
  [[ "$_bt" -ge 120 && "$_bt" -le 300 ]] && BASH_TIMEOUT_S="$_bt"
  USE_WORKTREE=0
  TASK_CWD="$RESUME_CWD"
  WT_PATH="$RESUME_CWD"   # final cleanup releases the (pre-existing) lease
  # T-019: a resumed child keeps its registry identity: nested opt-in, depth and
  # the mechanical gate are derived from the existing state, not from new flags.
  _nested="$(jq -r '.nested // false' "$RESUME_STATE_JSON" 2>/dev/null || echo false)"
  [[ "$_nested" == "true" ]] && NESTED=1 || NESTED=0
  _depth="$(jq -r '.depth // 1' "$RESUME_STATE_JSON" 2>/dev/null || echo 1)"
  case "$_depth" in ''|*[!0-9]*) _depth=1 ;; esac
  CHILD_DEPTH="$_depth"
  _posture="$(jq -r '.deliveryPosture // "no-mistakes"' "$RESUME_STATE_JSON" 2>/dev/null || echo no-mistakes)"
  [[ "$_posture" == "no-mistakes" && -f "$PROJECT/gate.yaml" ]] && GATE_ACTIVE=1
  # the relaunch plan (written by bin/fleet-relaunch.sh BEFORE the pane kill)
  RESUME_PLAN="$STATE_HOME/$TASK_ID.relaunch"
  if [[ -f "$RESUME_PLAN" ]]; then
    RESUME_BASE="$(jq -r '.base // empty' "$RESUME_PLAN" 2>/dev/null)"
    RESUME_BRANCH="$(jq -r '.branch // empty' "$RESUME_PLAN" 2>/dev/null)"
    RESUME_REASON="$(jq -r '.reason // ""' "$RESUME_PLAN" 2>/dev/null)"
    RESUME_AT="$(jq -r '.at // empty' "$RESUME_PLAN" 2>/dev/null)"
  fi
  # re-align the branch on the last WIP commit (the salvage base)
  _cur_branch="$(git -C "$TASK_CWD" branch --show-current 2>/dev/null || true)"
  _target="$RESUME_BRANCH"
  if [[ -z "$_target" ]]; then
    _target="$(git -C "$TASK_CWD" branch --list --format='%(refname:short)' "fleet/$TASK_ID-*" 2>/dev/null | head -1)"
  fi
  if [[ -z "$_target" ]]; then
    _target="fleet/$TASK_ID-resume"
    git -C "$TASK_CWD" switch -q -c "$_target" 2>/dev/null \
      || { herr "--resume: cannot create branch $_target"; exit 2; }
  elif [[ "$_cur_branch" != "$_target" ]]; then
    git -C "$TASK_CWD" switch -q "$_target" 2>/dev/null \
      || { herr "--resume: cannot switch to $_target"; exit 2; }
  fi
  # HEAD on a NAMED branch at the WIP base (child commits continue the lineage).
  if [[ -n "$RESUME_BASE" ]]; then
    git -C "$TASK_CWD" checkout -q -B "$_target" "$RESUME_BASE" 2>/dev/null \
      || { herr "--resume: cannot align $_target on $RESUME_BASE"; exit 2; }
  fi
  log "resume: $TASK_ID on $_target @ ${RESUME_BASE:-HEAD} (reason: ${RESUME_REASON:-watchdog})"
  # record the relaunch in the task registry (append-only) and consume the plan
  if jq -e . "$RESUME_PLAN" >/dev/null 2>&1; then
    jq --argjson rel "$(jq -c --arg at "${RESUME_AT:-$(date +%s)000}" --arg reason "$RESUME_REASON" --arg base "$RESUME_BASE" --arg branch "$_target" '{at:($at|tonumber), reason:$reason, base:$base, branch:$branch}' "$RESUME_PLAN" 2>/dev/null || echo '{}')" \
      '.relaunches = (.relaunches // []) + [$rel]' "$RESUME_STATE_JSON" \
      > "$RESUME_STATE_JSON.tmp" 2>/dev/null && mv "$RESUME_STATE_JSON.tmp" "$RESUME_STATE_JSON"
  fi
  rm -f "$RESUME_PLAN" 2>/dev/null || true
fi

# ------------------------------------------------------- 1. herdr workspace ----
# The child runs in a "fleet" workspace DEDICATED per project: it NEVER touches the
# captain's workspace/tab. From there it is visible ONLY in herdr's agents sidebar
# on the left (roll-up state per workspace) and takes no room in the chat tab.
# Slug readable from the title (fallback when --task-id is not passed).
slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//; s/-$//' | cut -c1-30 | sed 's/-$//'
}

TASK_ID="${TASK_ID_OVERRIDE:-$(slugify "$TITLE")-$(printf '%03d' $((RANDOM % 1000)))}"
PANE_ID=""
TAB_ID=""
# Agent name: herdr constraint = 1-32 chars, starts with a lowercase letter.
# The task id (readable, long) and the agent name (short) are DELIBERATELY decoupled.
AGENT_NAME="f-$(printf '%s' "$(slugify "$TITLE")" | cut -c1-23)-$(printf '%04d' $((RANDOM % 10000)))"
# T-019 resume: the task id comes from --resume (stable identity for the registry).
if [[ -n "$RESUME_TASK_ID" ]]; then
  TASK_ID="$RESUME_TASK_ID"
fi
log "task: $TASK_ID — $TITLE"

resolve_fleet_workspace() {
  # DEDICATED "fleet" workspace (single one): children run here, NEVER in the
  # captain's workspace/tab → visible ONLY in herdr's agents sidebar
  # (roll-up per workspace). `workspace list` does NOT expose the cwd, so the
  # match is by label; if multiple "fleet" workspaces exist it takes the first
  # and always reuses it on subsequent launches.
  # NOTE clean stdout: the function is used inside $(...) → logs go to
  # stderr, ONLY the workspace id on stdout.
  local ws_out ws
  ws_out="$(herdr_cli workspace list)" || ws_out=""
  ws="$(printf '%s' "$ws_out" | jq -r --arg l "fleet" \
    '[.result.workspaces[]? | select(.label==$l)] | .[0].workspace_id // empty' 2>/dev/null)" \
    || ws=""
  [[ -n "$ws" ]] && { echo "$ws"; return 0; }
  for ((try = 1; try <= 3; try++)); do
    # `workspace create` responds with .result.workspace.workspace_id
    # (shape documentata: .result.workspace / .result.tab / .result.root_pane).
    ws="$(herdr_cli workspace create --label "fleet" --cwd "$PROJECT" --no-focus \
      | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)" || ws=""
    [[ -n "$ws" ]] && { log "fleet workspace created: $ws" >&2; echo "$ws"; return 0; }
    sleep 1
    ws_out="$(herdr_cli workspace list)" || continue
    ws="$(printf '%s' "$ws_out" | jq -r --arg l "fleet" \
      '[.result.workspaces[]? | select(.label==$l)] | .[0].workspace_id // empty' 2>/dev/null)" || ws=""
    [[ -n "$ws" ]] && { echo "$ws"; return 0; }
  done
  echo ""
}


# ------------------------------------------------------- 2. worktree ----
TASK_CWD="$PROJECT"
WT_PATH=""
# T-019 resume: the existing worktree (state.cwd) is reused — no new lease.
if [[ -n "$RESUME_TASK_ID" ]]; then
  TASK_CWD="$RESUME_CWD"
  WT_PATH="$RESUME_CWD"
fi
if [[ "$USE_WORKTREE" == 1 ]]; then
  WT_OUT="$(cd "$PROJECT" && treehouse get --lease --no-fetch --lease-holder "pi-fleet:$TASK_ID" 2>&1)" \
    || { herr "treehouse get failed for '$PROJECT': $WT_OUT"; exit 1; }
  WT_PATH="${WT_OUT##*$'\n'}"   # the path is the last line
  [[ -d "$WT_PATH" ]] || { herr "invalid worktree: $WT_PATH"; exit 1; }
  TASK_CWD="$WT_PATH"
  log "worktree: $WT_PATH"
fi

release_worktree() {
  [[ -z "$WT_PATH" ]] && return 0
  (cd "$PROJECT" && treehouse return "$WT_PATH" 2>&1 | sed 's/^/  treehouse: /' >&2) || true
  WT_PATH=""
}

# Child model: pi's default without --model is the first model of the
# catalog (here opencode/kimi-k2.6, without credit). We therefore inherit the main
# session's model with the LONG --model flag (pi has no -m; with -m it fails).
# RULE: ALWAYS pass the full id `provider/id` — the bare id (e.g.
# "deepseek-v4-flash") collides across providers and `pi --model <bare>` starts
# and exits in ~2.6s due to ambiguity. Never `pi --model <bare>`.
MODEL_ARGS=()
if [[ -n "$MODEL_OVERRIDE" ]]; then
  if [[ "$MODEL_OVERRIDE" == */* ]]; then
    MODEL_ARGS=(--model "$MODEL_OVERRIDE")
    log "child model (override): $MODEL_OVERRIDE"
  elif [[ -n "${PI_PROVIDER:-}" ]]; then
    # bare id override: qualified with PI_PROVIDER to avoid launching a bare id
    MODEL_ARGS=(--model "${PI_PROVIDER}/${MODEL_OVERRIDE}")
    log "child model (qualified bare id override): ${PI_PROVIDER}/${MODEL_OVERRIDE}"
  else
    # unusable override: ignore with a warning and continue with the env chain
    log "invalid override ignored: '$MODEL_OVERRIDE' is a bare id (PI_PROVIDER missing) — using the env chain"
  fi
fi
if [[ ${#MODEL_ARGS[@]} -eq 0 ]]; then
  if [[ -n "${PI_PROVIDER:-}" && -n "${PI_MODEL:-}" ]]; then
    MODEL_ARGS=(--model "${PI_PROVIDER}/${PI_MODEL}")
    log "child model: ${PI_PROVIDER}/${PI_MODEL}"
  elif [[ -n "${PI_DEFAULT_MODEL:-}" ]]; then
    MODEL_ARGS=(--model "$PI_DEFAULT_MODEL")
    log "child model: $PI_DEFAULT_MODEL"
  else
    log "child model: no model from parent, using global default"
  fi
fi

# ------------------------------------------------------- 3. state on disk ----
STATE_JSON="$STATE_HOME/$TASK_ID.json"
BRIEF_PATH="$STATE_HOME/tasks/$TASK_ID.brief.md"
PROMPT_PATH="$STATE_HOME/tasks/$TASK_ID.prompt.md"
DONE_PATH="$STATE_HOME/$TASK_ID.done.json"
NEEDS_INPUT_PATH="$STATE_HOME/$TASK_ID.needs-input.json"

if [[ -n "$RESUME_TASK_ID" ]]; then
  # T-019 resume: the registry state already exists (running, group/nested fields
  # preserved). The brief file is already on disk. Do NOT overwrite either.
  :
else
printf '%s\n' "$BRIEF_CONTENT" > "$BRIEF_PATH"
# L3.5 group fields — empty GROUP_ID → use TASK_ID (single), GROUP_SIZE placeholder 1
EFFECTIVE_GROUP_ID="${GROUP_ID:-$TASK_ID}"
cat > "$STATE_JSON.tmp" <<EOF
{
  "id": "$TASK_ID",
  "title": $(jq -Rn --arg v "$TITLE" '$v'),
  "project": "$PROJECT",
  "worktree": ${USE_WORKTREE},
  "cwd": "$TASK_CWD",
  "briefFile": "$BRIEF_PATH",
  "state": "spawning",
  "startedAt": $(date +%s)000,
  "lastBeatAt": $(date +%s)000,
  "doneAt": null,
  "timeoutMs": $((TIMEOUT_MIN * 60000)),
  "bashTimeoutS": ${BASH_TIMEOUT_S:-300},
  "groupId": $(jq -Rn --arg v "$EFFECTIVE_GROUP_ID" '$v'),
  "groupSize": 1,
  "groupLabel": $(jq -Rn --arg v "${GROUP_LABEL:-}" '$v'),
  "groupMode": "${GROUP_MODE:-barrier}",
  "kind": "${KIND:-ship}",
  "deliveryPosture": $(jq -Rn --arg v "${DELIVERY_POSTURE:-no-mistakes}" '$v'),
  "groupFailPolicy": "${GROUP_FAIL_POLICY:-waitAll}",
  "nested": $([ "${NESTED:-0}" = "1" ] && echo true || echo false),
  "depth": ${CHILD_DEPTH:-1},
  "parentTaskId": $(jq -Rn --arg v "$PARENT_TASK_ID" '$v')
}
EOF
mv "$STATE_JSON.tmp" "$STATE_JSON"  # atomic: no mid-reads by the watcher
fi
log "state: $STATE_JSON"
if [[ -n "${GROUP_ID:-}" ]]; then log "gruppo: $GROUP_ID ($GROUP_MODE)"; fi

# ------------------------------------------------------- 4. herdr tab (sidebar-only) ----
# Children run in the dedicated "fleet" workspace (never in the captain's tab) in a
# `--no-focus` tab: they don't steal focus, take no room in the chat tab and
# don't appear in the captain's tab bar — they are visible ONLY in herdr's agents
# sidebar on the left (roll-up state per workspace) until you open them.
# close_tab closes tab + pane (the fleet workspace tab is dedicated to the task;
# the captain's tab is NEVER touched).
close_tab() {
  if [[ -n "$TAB_ID" ]]; then
    herdr_cli tab close "$TAB_ID" >/dev/null 2>&1 && log "tab closed" || log "tab already closed"
    TAB_ID=""
  fi
  if [[ -n "$PANE_ID" ]]; then
    herdr_cli pane close "$PANE_ID" >/dev/null 2>&1 && log "pane closed" || log "pane already closed"
    PANE_ID=""
  fi
}
WORKSPACE="$(resolve_fleet_workspace)"
[[ -z "$WORKSPACE" ]] && { herr "unable to create/resolve the fleet workspace"; fail_task "fleet workspace not resolvable"; release_worktree; exit 1; }
log "fleet workspace: $WORKSPACE"
TB_OUT="$(herdr_cli tab create --workspace "$WORKSPACE" --cwd "$TASK_CWD" --label "$TASK_ID" --no-focus \
  --env "FLEET_TASK_ID=$TASK_ID" --env "FLEET_DEPTH=$CHILD_DEPTH" --env "FLEET_STATE_HOME=$STATE_HOME")"
TAB_ID="$(printf '%s' "$TB_OUT" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)"
PANE_ID="$(printf '%s' "$TB_OUT" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)"
[[ -z "$TAB_ID" || -z "$PANE_ID" ]] && { herr "tab create without tab/pane id: $TB_OUT"; fail_task "tab create failed: $TB_OUT"; release_worktree; exit 1; }
log "fleet tab (sidebar only): $TAB_ID | pane: $PANE_ID"
add_pane_ids

# Error cleanup: ALWAYS pane/tab before treehouse return (return kills
# the processes in the worktree, including the pane shell).
trap 'log "interrotto: pulisco..."; close_tab; release_worktree; exit 130' INT TERM

# ------------------------------------------------------- 5.1 CHILD_PROMPT build ----
# T-029: the brief is delivered as pi's NATIVE initial request — pi's interactive
# mode reads `@<file>` args and prompts the session BEFORE the main loop, so the
# full CHILD_PROMPT (rules + delivery posture + brief) is materialized on disk
# BEFORE `agent start` and passed to the agent as `@<prompt-file>` in its argv.
# herdr forwards agent args raw into pi's argv but REFUSES args that cannot be
# shell-encoded safely (multi-line text with quotes/$/backticks →
# invalid_agent_argument): hence the file indirection, NOT a direct positional
# message argument.
# Scout task (--kind scout): deliverable = report.md, no commit/push/PR;
# the extra rule enters the CHILD_PROMPT only when KIND == scout.
SCOUT_RULES=""
if [[ "$KIND" == "scout" ]]; then
  SCOUT_RULES="- YOU ARE A SCOUT TASK (report only). Your deliverable is a \`report.md\` file at the root of the cwd with the complete result of the analysis. Do NOT commit, do NOT push, do NOT open a PR. In the done-marker add \"reportPath\":\"report.md\" (relative path)."
  log "kind: scout (report only, no commit/PR)"
fi
# T-013: nested orchestrator rules (only with --nested): the child may use the
# fleet_* tools to launch/manage its OWN subtasks (review loops, pipelines). The
# depth cap is enforced by the extension at launch time; delivery is unchanged.
NESTED_RULES=""
if [[ "$NESTED" == "1" ]]; then
  NESTED_RULES="- YOU ARE A NESTED ORCHESTRATOR (launched with nested:true, depth ${CHILD_DEPTH:-1}): you MAY use the fleet_* tools (fleet_launch, fleet_status, fleet_peek, fleet_steer, fleet_abort) to spawn and manage YOUR OWN subtasks (review loops, pipelines). Your fleet view and targets are SCOPED to your own subtree — you can only manage tasks you launched. Depth is capped: a launch beyond the configured max (postures.json \$config.nestedMaxDepth, default 2) is denied with a clear message; treat that as a limit, not a bug. Do NOT use fleet_bootstrap / fleet_learn / fleet_captain_pref / fleet_stow (captain-only tools)."
  log "nested: orchestrator enabled (depth ${CHILD_DEPTH:-1})"
fi
# T-019 resume preamble: the child must know it was hard-reset and from where.
RESUME_RULES=""
if [[ -n "$RESUME_TASK_ID" ]]; then
  RESUME_RULES="- RESUME NOTICE (T-019 watchdog recovery): your pane was classified hard-frozen and was killed + relaunched automatically at ${RESUME_AT:-?} (reason: ${RESUME_REASON:-frozen pane}). The branch is aligned on the last WIP commit (${RESUME_BASE:-HEAD}); a 'WIP salvage before relaunch' commit may be present (untracked files were committed for you). Continue the ORIGINAL brief: $BRIEF_PATH. In the done-marker, briefly report what state you recovered and what still remains."
  log "resume: recovery preamble added to the child prompt"
fi
# T-019 runtime conventions (every task, launch or resume): per-command bash
# tolerance + WIP hygiene. Enforcement is the external pane-health watchdog
# (bin/fleet-watch.sh): static context for ${BASH_TIMEOUT_S}s → 'command timeout'
# report + auto-steer; still no ack → kill + relaunch from the last WIP commit.
RUNTIME_RULES="- RUNTIME RULES (T-019): (1) NEVER let a single bash command run unbounded — the pane-health watchdog reports 'command timeout' when a command shows no context growth for ${BASH_TIMEOUT_S}s (per-task tolerance). Wrap any command that may take longer than ~10s with an explicit \`timeout <seconds>\` wrapper, or state the configured tolerance in your brief and ack the watchdog steer if it fires (a legitimately long command is fine once acknowledged). (2) Leave NO untracked files behind: commit your work as you go (ONE COMMIT PER FILE), and before finishing/stopping commit or stash anything untracked so a kill+relaunch is lossless. (3) Commit a WIP commit right after recon. (4) Recursive commands (tests, searches, jq pipes) need a depth bound — no silent infinite loops."
  log "runtime: bash tolerance ${BASH_TIMEOUT_S}s"
# T-011 mechanical gate: conditional GATE section (only when --gate, i.e.
# no-mistakes posture AND project with gate.yaml). The child owns the self-fix
# loop (firstmate model: the worker owns run/fix). The anti-fraud is in the
# launcher (section 7.5): the child CANNOT cheat on the final green.
GATEROUNDS_MAX="5"
if [[ "$GATE_ACTIVE" == "1" ]]; then
  GATE_YAML_CFG="$TASK_CWD/gate.yaml"
  [[ -f "$GATE_YAML_CFG" ]] || GATE_YAML_CFG="$PROJECT/gate.yaml"
  if [[ -f "$GATE_YAML_CFG" ]]; then
    rounds="$(sed -n 's/^[[:space:]]*maxRounds:[[:space:]]*\([0-9]*\).*/\1/p' "$GATE_YAML_CFG" | head -1)"
    [[ -n "$rounds" ]] && GATEROUNDS_MAX="$rounds"
  fi
  GATE_RULES="GATE: the project has a deterministic gate ($GATE_RUN). After the implementation: 1) run the gate by executing \`bash \"$GATE_RUN\" --report gate/report.json\` at the root of the cwd (create the gate/ dir if needed); 2) if red, read the per-step report and fix ONLY what the report flags (no scope creep), then re-run the gate (max ${GATEROUNDS_MAX} rounds); 3) NEVER write the done-marker with a red gate — if the rounds end red, write the done-marker with status \"failed\" and the summary containing the report content; 4) on green put \`gate:{passed:true,rounds:N,reportPath:\"gate/report.json\"}\` in the done-marker; do NOT open PR/merge yourself: if the project configures it, the system does it."
  log "gate: active (maxRounds $GATEROUNDS_MAX)"
else
  GATE_RULES=""
fi
CHILD_PROMPT="You are a fleet sub-agent (task $TASK_ID). Read the brief in:
$BRIEF_PATH

Rules:
- Run the task inside the current cwd. Do NOT modify anything outside the cwd.
- The worktree is in detached HEAD state: if you need to commit, first create a branch (git switch -c fleet/<taskid>-<slug>). NEVER commit on detached HEAD or on the main branch.
- Do not interrupt the user: work autonomously to the end.
- If you need input from the captain, write the file $NEEDS_INPUT_PATH with {\"question\":\"...\",\"taskState\":\"needs_input\"} and STOP (no questions in chat).
- The captain can send you messages (fleet_steer): you find them in the directory $STATE_HOME/$TASK_ID.inbox/ (files <seq>.json). After READING and applying a message, create the ack file $STATE_HOME/$TASK_ID.inbox/<seq>.acked (e.g. : > <path>). If you don't ack, the message will be re-delivered and then the captain will be notified.
- When you are done, write the file $DONE_PATH in JSON format:
{\"status\":\"done\",\"summary\":\"...\",\"changedFiles\":[\"rel/path\"]}
(on an unpreventable error: {\"status\":\"failed\",\"summary\":\"...reason...\"})
- CRITICAL RULE about the summary: it is NOT an activity log. It must contain THE RESULT required by the brief (points, lists, answers, decisions), complete and self-contained. Whoever reads it (the captain) must understand the outcome WITHOUT opening other files. A line like \"done / read the files\" is INSUFFICIENT: report in detail what the brief asks you to produce.
- FORMATTING RULE: write the summary in structured Markdown — headings, bullets, numbered lists, tables where it makes sense. NO walls of continuous prose: if the text exceeds a few lines, split it into titled sections. Readable output is part of the deliverable.
- Then end the turn without asking anything (this script closes the tab and cleans up).
${SCOUT_RULES}
${GATE_RULES}
${NESTED_RULES}
${RESUME_RULES}
${RUNTIME_RULES}

DELIVERY POSTURE: $DELIVERY_POSTURE
Meaning:
- no-mistakes — commit only with tests/CI green; never push; deliver only on explicit captain request.
- direct-PR — at the end, if the brief authorizes it, prepare and OPEN the PR (gh pr create) from the branch fleet/<id>; never merge.
- local-only — commit locally; no push, no PR; the captain decides later.
- yolo — like local-only, but authorizes branch push and merge+PR only if the brief explicitly asks for it; never autonomously without a brief.
Respect it during delivery; if the brief asks for nothing explicit, behave according to the posture. NEVER run unauthorized push/merge.

The task is: $BRIEF_CONTENT"

# The full child prompt, materialized for the native `@<file>` initial request.
printf '%s\n' "$CHILD_PROMPT" > "$PROMPT_PATH"
log "child prompt file: $PROMPT_PATH"

# Portable "size<TAB>path" listing of the child session tree (used to detect
# session-file growth — pi appends per turn, so size strictly increases).
file_sizes() {  # <dir> → "size<TAB>path" per regular file (maxdepth 2)
  local dir="$1" f sz
  find "$dir" -type f -maxdepth 2 2>/dev/null | while IFS= read -r f; do
    if [[ "$(uname)" == "Darwin" ]]; then
      sz="$(stat -f '%z' "$f" 2>/dev/null)"
    else
      sz="$(stat -c '%s' "$f" 2>/dev/null)"
    fi
    [[ -n "$sz" ]] && printf '%s\t%s\n' "$sz" "$f"
  done
}

# ------------------------------------------------------- 5.2 start pi with the prompt ----
# T-029: the brief rides ALONG in the agent argv (`@$PROMPT_PATH`): pi reads the
# file and prompts the session natively before its main loop. ZERO `agent prompt`
# for the delivery. Pre-start evidence baselines (captured once — the native
# initial turn begins DURING `agent start`, so the residual check below needs a
# baseline to compare against).
PRE_START_REVISION="$(herdr_cli agent get "$PANE_ID" 2>/dev/null | jq -r '.result.agent.revision // 0' 2>/dev/null)"
SESSION_DIR="$HOME/.pi/agent/sessions/$(printf '%s' "$TASK_CWD" | sed 's|^/||; s|/|-|g; s|.*|--&--|')"
SESSION_SNAPSHOT_BEFORE="$(file_sizes "$SESSION_DIR")"
# UNIQUE agent name per task (herdr rejects duplicate names: agent_name_taken) and
# retry on transient races (agent_pane_busy: pane shell not yet available right
# after tab create, typical with closely-spaced parallel launches).
AS_OUT=""
OK=0
for ((try = 1; try <= 4; try++)); do
  AS_OUT="$(herdr_cli agent start "$AGENT_NAME" --kind pi --pane "$PANE_ID" -- "${MODEL_ARGS[@]}" "@$PROMPT_PATH")"
  if [[ $? -eq 0 ]]; then OK=1; break; fi
  herr "agent start: attempt $try/4 failed: ${AS_OUT:0:160}"
  sleep 3
done
if [[ $OK -ne 1 ]]; then
  herr "agent start failed ($AGENT_NAME): $AS_OUT"
  fail_task "agent start failed: ${AS_OUT:0:200}"
  close_tab
  release_worktree
  exit 1
fi
log "pi started in the pane (readiness ok)"
log "brief delivered to the child (native initial request)"

# -------------------------------------------------- 5.3 residual startup check (T-029) ----
# With the native initial request the prompt CANNOT get lost (it is born inside
# the pi process), so delivery is complete at `agent start` — the old send +
# consumption-ACK + re-send machinery (§6b T-027) is GONE. The only residual
# check is fail-soft and NEVER re-sends: a bounded wait for the child to leave
# `idle` (evidence it started working the initial request). If it never does,
# the launcher proceeds to the done-wait — a truly empty/frozen pane is caught
# there by the §7 liveness gate (agent_alive), as before.
startup_started() {  # evidence the child left idle (ANY one = started)
  local out st rev now
  out="$(herdr_cli agent get "$PANE_ID" 2>/dev/null)" || return 1
  st="$(printf '%s' "$out" | jq -r '.result.agent.agent_status // ""' 2>/dev/null)"
  [[ -n "$st" && "$st" != "idle" && "$st" != "unknown" ]] && return 0
  rev="$(printf '%s' "$out" | jq -r '.result.agent.revision // 0' 2>/dev/null)"
  if [[ "$rev" =~ ^[0-9]+$ ]] && [[ "$rev" -gt "$PRE_START_REVISION" ]] 2>/dev/null; then
    return 0
  fi
  if [[ -d "$SESSION_DIR" ]]; then
    now="$(file_sizes "$SESSION_DIR")"
    [[ -n "$now" && "$now" != "$SESSION_SNAPSHOT_BEFORE" ]] && return 0
  fi
  return 1
}
STARTED=0
for ((_try = 1; _try <= STARTUP_WAIT_TRIES; _try++)); do
  if startup_started; then STARTED=1; break; fi
  log "child not out of idle yet (attempt $_try/$STARTUP_WAIT_TRIES)"
  [[ "$_try" -lt "$STARTUP_WAIT_TRIES" ]] && sleep "$STARTUP_WAIT_SLEEP"
done
if [[ "$STARTED" -eq 1 ]]; then
  log "child left idle — processing the native initial request"
else
  log "child didn't leave idle within ${STARTUP_WAIT_TRIES}×${STARTUP_WAIT_SLEEP}s (fail-soft: no re-send; the done-wait §7 liveness gate flags an empty/frozen pane)"
fi

# ------------------------------------------------------- 7. done-marker wait ----
# Liveness: if the child (agent in the pane) disappears without writing a marker
# (crash, closed tab, session ended by the captain), do NOT keep waiting
# until the timeout: after ~30s without an active pane declare failed with reason.
agent_alive() {
  local out
  out="$(herdr_cli agent list 2>/dev/null)" || return 2   # herdr irraggiungibile: ignora
  jq -e --arg p "$PANE_ID" '[.result.agents[] | select(.pane_id==$p)] | length > 0' <<<"$out" >/dev/null 2>&1 && return 0
  return 1
}

set_state running
log "waiting for completion (timeout ${TIMEOUT_MIN}min)..."
DEADLINE=$(( $(date +%s) + TIMEOUT_MIN * 60 ))
LAST_LIVE=$(date +%s)
MISS=0
while :; do
  if [[ -f "$DONE_PATH" ]]; then
    RESULT="$(cat "$DONE_PATH")"
    # The done.json can arrive with a multi-line summary with LITERAL newlines
    # (non-escaped), hence invalid JSON: best-effort fallback parse → done
    # with the raw summary, so the state never gets stuck on 'running'.
    if ! printf '%s' "$RESULT" | jq -e . >/dev/null 2>&1; then
      log "done.json not valid JSON (likely literal newlines in the summary): best-effort fallback"
      STATUS="done"; SUMMARY="$RESULT"; FILES="[]"; REPORTPATH=""; CHILD_GATE_ROUNDS=0
    else
      STATUS="$(printf '%s' "$RESULT" | jq -r '.status // "failed"')"
      SUMMARY="$(printf '%s' "$RESULT" | jq -r '.summary // ""')"
      FILES="$(printf '%s' "$RESULT" | jq -c '.changedFiles // []')"
      REPORTPATH="$(printf '%s' "$RESULT" | jq -r '.reportPath // ""')"
      CHILD_GATE_ROUNDS="$(printf '%s' "$RESULT" | jq -r '.gate.rounds // 0' 2>/dev/null || echo 0)"
    fi
    log "completed: $STATUS"
    printf '
=== TASK RESULT %s ===
%s
=== END ===
' "$TASK_ID" "$RESULT"
    # writes state + result into the state json (the captain sees it in fleet_status)
    jq --arg st "$STATUS" --arg done "$(date +%s)000" --arg sum "$SUMMARY" --argjson files "$FILES" --arg rp "$REPORTPATH" \
      '.state=$st | .doneAt=($done|tonumber) | .summary=$sum | .changedFiles=$files | if $rp != "" then .reportPath=$rp else . end' "$STATE_JSON" \
      > "$STATE_JSON.tmp" 2>/dev/null && mv "$STATE_JSON.tmp" "$STATE_JSON"
    rm -f "$DONE_PATH"
    break
  fi
  if [[ -f "$NEEDS_INPUT_PATH" ]]; then
    log "the child ASKS FOR INPUT (tab left open, watcher keeps waiting)"
    set_state needs_input
    rm -f "$NEEDS_INPUT_PATH"
  fi
  if [[ -f "$STATE_HOME/$TASK_ID.abort" ]]; then
    log "abort requested by the captain"
    set_state aborted
    close_tab
    release_worktree
    exit 0
  fi
  # T-019: a .relaunch marker (written by bin/fleet-relaunch.sh BEFORE the pane
  # kill) means the watchdog is taking over: exit WITHOUT failing the task and
  # WITHOUT releasing the worktree — the resumed launcher (--resume) owns both.
  if [[ -f "$STATE_HOME/$TASK_ID.relaunch" ]]; then
    log "relaunch requested (T-019 watchdog): exiting without failing/releasing (resume owns pane+worktree)"
    exit 0
  fi
  if [[ $(date +%s) -gt $DEADLINE ]]; then
    herr "timeout after ${TIMEOUT_MIN}min: killing the task"
    set_state failed
    close_tab
    release_worktree
    exit 1
  fi
  # liveness: every 15s check that the pane still has an active agent
  if (( $(date +%s) - LAST_LIVE >= 15 )); then
    LAST_LIVE=$(date +%s)
    agent_alive
    case $? in
      0) MISS=0 ;;
      1) MISS=$((MISS + 1)); log "child not detected in the pane ($MISS/2)" ;;
      *) : ;;                                        # herdr down: do not count
    esac
    if (( MISS >= 2 )); then
      herr "the child ended without a done-marker (agent no longer detected): closing the task"
      jq --arg done "$(date +%s)000" --arg sum "The child ended without writing the done-marker (agent/pane no longer present)." \
        '.state="failed" | .doneAt=($done|tonumber) | .summary=$sum' "$STATE_JSON" \
        > "$STATE_JSON.tmp" 2>/dev/null && mv "$STATE_JSON.tmp" "$STATE_JSON"
      close_tab
      release_worktree
      exit 1
    fi
  fi
  sleep 2
done

# ------------------------------------------- 7.5 anti-fraud gate (T-011) ----
# The launcher re-runs the gate ITSELF on the worktree at the final state
# (HEAD = the child's final commit — after the done-marker, before finalizing).
# Anti-fraud: the child cannot cheat on the green. Merge NEVER automatic (F0 #6).
# Cases:
#   red/error               → task failed with the report; tab closed; NO PR.
#   green + autoPr:true    → gh-axi pr create; prUrl + gate in the state json.
#   green + autoPr:false   → done without PR (gate in the state json).
gh_axi() {
  if command -v gh-axi >/dev/null 2>&1; then
    gh-axi "$@"
  else
    log "gh-axi not in PATH → fallback npx -y gh-axi (documented)"
    npx -y gh-axi "$@"
  fi
}
run_pr_create() {
  local head="$1" body="$2" title="$3" out rc pr
  local try
  for ((try = 1; try <= 3; try++)); do   # light retries (2×3s) on busy
    out="$(cd "$PROJECT" && gh_axi pr create --head "$head" --base main --title "$title" --body-file "$body" 2>&1)"
    rc=$?
    if [[ $rc -eq 0 ]]; then
      pr="$(printf '%s' "$out" | jq -r '.url // .html_url // empty' 2>/dev/null)"
      [[ -z "$pr" ]] && pr="$(printf '%s' "$out" | tr -d '\n' | grep -oE 'https?://[^ )"]+' | head -1)"
      [[ -z "$pr" ]] && pr="$(printf '%s' "$out" | head -1)"   # fallback: output grezzo
      echo "$pr"; return 0
    fi
    log "gh-axi pr create: attempt $try/3 failed (rc=$rc): ${out:0:140}"
    sleep 3
  done
  echo ""
  return 1
}

if [[ "$GATE_ACTIVE" == "1" ]]; then
  GATE_REPORT_PATH="gate/report.json"
  log "gate: re-running the gate myself (anti-fraud) on $TASK_CWD ..."
  ( cd "$TASK_CWD" && bash "$GATE_RUN" --report "$GATE_REPORT_PATH" >/dev/null 2>&1 )
  GATE_RC=$?
  GATE_OVERALL="red"
  if [[ -f "$TASK_CWD/$GATE_REPORT_PATH" ]]; then
    GATE_OVERALL="$(jq -r '.overall // "red"' "$TASK_CWD/$GATE_REPORT_PATH" 2>/dev/null || echo red)"
  else
    herr "gate: missing report (${TASK_CWD}/${GATE_REPORT_PATH}) — treated as red"
  fi
  [[ "$GATE_RC" -eq 0 && "$GATE_OVERALL" == "green" ]] && GATE_PASSED=1 || GATE_PASSED=0
  GATE_ROUNDS="${CHILD_GATE_ROUNDS:-0}"
  GATE_OBJ="$(jq -nc --argjson p "$GATE_PASSED" --argjson r "$GATE_ROUNDS" --arg rp "$GATE_REPORT_PATH" \
    '{passed:($p==1), rounds:$r, reportPath:$rp}')"
  if [[ "$GATE_PASSED" -eq 1 ]]; then
    log "gate green (rc=$GATE_RC, overall=$GATE_OVERALL)"
    if [[ "$AUTO_PR" == "true" ]]; then
      PR_HEAD="$(git -C "$TASK_CWD" symbolic-ref --short HEAD 2>/dev/null || git -C "$TASK_CWD" rev-parse --abbrev-ref HEAD 2>/dev/null)"
      log "gate green + autoPr:true → creating PR (head=$PR_HEAD)"
      PR_URL="$(run_pr_create "$PR_HEAD" "$TASK_CWD/$GATE_REPORT_PATH" "$TITLE")"
      if [[ -n "$PR_URL" ]]; then
        jq --argjson gate "$GATE_OBJ" --arg pr "$PR_URL" \
          '.gate=$gate | .prUrl=$pr' "$STATE_JSON" \
          > "$STATE_JSON.tmp" 2>/dev/null && mv "$STATE_JSON.tmp" "$STATE_JSON"
        log "PR created: $PR_URL (merge NEVER automatic — authority = captain)"
      else
        herr "green gate but PR creation failed (gh-axi): task failed, never a half PR"
        jq --arg done "$(date +%s)000" --argjson gate "$GATE_OBJ" \
          --arg sum "Green gate but automatic PR creation failed (gh-axi did not respond). See report: $GATE_REPORT_PATH." \
          '.state="failed" | .doneAt=($done|tonumber) | .gate=$gate | .summary=$sum' "$STATE_JSON" \
          > "$STATE_JSON.tmp" 2>/dev/null && mv "$STATE_JSON.tmp" "$STATE_JSON"
      fi
    else
      jq --argjson gate "$GATE_OBJ" '.gate=$gate' "$STATE_JSON" \
        > "$STATE_JSON.tmp" 2>/dev/null && mv "$STATE_JSON.tmp" "$STATE_JSON"
      log "gate green, autoPr=false → done without PR"
    fi
  else
    herr "gate red at anti-fraud (rc=$GATE_RC, overall=$GATE_OVERALL): task failed, NO PR"
    jq --arg done "$(date +%s)000" --argjson gate "$GATE_OBJ" \
      --arg sum "Gate (launcher anti-fraud) RED after the child's done-marker: rc=$GATE_RC overall=$GATE_OVERALL. Report: $GATE_REPORT_PATH. PR NOT created." \
      '.state="failed" | .doneAt=($done|tonumber) | .gate=$gate | .summary=$sum' "$STATE_JSON" \
      > "$STATE_JSON.tmp" 2>/dev/null && mv "$STATE_JSON.tmp" "$STATE_JSON"
  fi
else
  log "gate not active (no --gate): no final verification"
fi

# ------------------------------------------------------- 8. cleanup ----
close_tab
release_worktree
log "fine $TASK_ID"