#!/usr/bin/env bash
# pi-fleet · T-019 standardized relaunch — salvage WIP → kill pane → resume launcher
#
# The pane-health watchdog (bin/fleet-watch.sh) calls this when a frozen pane has
# not acknowledged its auto-steer within the kill window (M min). It performs the
# recovery in the ORDER that makes it lossless:
#
#   1. SALVAGE — in the task's existing worktree (state.cwd): commit every
#      untracked/modified file onto the current fleet/<taskid>-* branch FIRST
#      ("WIP salvage before relaunch"), so the relaunch base = last WIP commit
#      and NO work is left untracked.
#   2. MARK    — write <taskid>.relaunch AFTER the salvage (the ORIGINAL launcher,
#      if still alive, sees it within its 2s wait-loop and exits 0 without failing
#      the task and without releasing the worktree — the resumed launcher owns both).
#   3. KILL    — close pane/tab with the SAME teardown the launcher uses
#      (tab close + pane close, idempotent).
#   4. RESUME  — invoke bin/herdr-launch.sh --resume <taskId> (fresh pane, same
#      brief, same registry identity: groupId/nested/gate preserved).
#
# Headless/fixture support: FLEET_RELAUNCH_LAUNCHER (path of the launcher, default
# bin/herdr-launch.sh) and HERDR_SESSION; PATH may shadow `herdr` with a mock.
# --dry-run prints the plan as JSON and performs nothing (for tests/audit).
#
# Usage:
#   bin/fleet-relaunch.sh <taskId> [--reason <text>] [--dry-run]
#
# Exit: 0 relaunched (or plan printed) · 1 no WIP base / task not found · 2 usage
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="${FLEET_STATE_HOME:-$HOME/.pi/fleet}"
LAUNCHER_BIN="${FLEET_RELAUNCH_LAUNCHER:-$SCRIPT_DIR/herdr-launch.sh}"
SESSION="${HERDR_SESSION:-default}"

usage() { sed -n '1,24p' "$0" | sed 's/^# \{0,1\}//'; }
log() { printf '[fleet-relaunch] %s\n' "$*" >&2; }
die() { printf '[fleet-relaunch] ERROR: %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq not found in PATH (brew install jq)"
[[ -x "$LAUNCHER_BIN" || -f "$LAUNCHER_BIN" ]] || die "launcher not found: $LAUNCHER_BIN"

TASK_ID="${1:-}"
shift || true
REASON="T-019 watchdog: frozen pane (no context growth, steer not acked)"
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reason) REASON="${2:-$REASON}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unexpected argument: $1" ;;
  esac
done
[[ -n "$TASK_ID" ]] || { usage; exit 2; }

STATE_JSON="$STATE/$TASK_ID.json"
[[ -f "$STATE_JSON" ]] || die "task state not found: $STATE_JSON"

CWD="$(jq -r '.cwd // empty' "$STATE_JSON" 2>/dev/null)"
PROJECT="$(jq -r '.project // ""' "$STATE_JSON" 2>/dev/null)"
PANE_ID="$(jq -r '.paneId // empty' "$STATE_JSON" 2>/dev/null)"
TAB_ID="$(jq -r '.tabId // empty' "$STATE_JSON" 2>/dev/null)"
[[ -n "$CWD" && -d "$CWD" ]] || die "worktree missing: $CWD (treehouse released it? base lost — do NOT kill)"
[[ -d "$CWD/.git" || -f "$CWD/.git" ]] || die "not a git repo: $CWD"

# ---------------------------------------------------------------- 1. salvage --
branch="$(git -C "$CWD" branch --show-current 2>/dev/null || true)"
if [[ -z "$branch" ]]; then
  branch="$(git -C "$CWD" branch --list --format='%(refname:short)' "fleet/$TASK_ID-*" 2>/dev/null | head -1)"
fi
if [[ -z "$branch" ]]; then
  branch="fleet/$TASK_ID-resume"
  git -C "$CWD" switch -q -c "$branch" >/dev/null 2>&1 \
    || die "cannot create salvage branch $branch in $CWD"
fi
dirty="$(git -C "$CWD" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
case "$dirty" in ''|*[!0-9]*) dirty=0 ;; esac
if [[ "$dirty" -gt 0 ]]; then
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "dry-run: would commit $dirty untracked/modified file(s) on $branch (salvage)"
  else
    git -C "$CWD" add -A
    git -C "$CWD" commit -q -m "chore(recovery): WIP salvage before relaunch (T-019)" \
      || log "salvage commit failed (dry repo?) — continuing with the current HEAD"
  fi
fi
base="$(git -C "$CWD" rev-parse HEAD 2>/dev/null || true)"
[[ -n "$base" ]] || die "no WIP base (empty repository): nothing to resume from"

if [[ "$DRY_RUN" -eq 1 ]]; then
  jq -nc --arg taskId "$TASK_ID" --arg branch "$branch" --arg base "$base" \
     --argjson dirty "$dirty" --arg paneId "$PANE_ID" --arg tabId "$TAB_ID" \
     --arg launcher "$LAUNCHER_BIN" --arg reason "$REASON" \
     '{ok:true, dryRun:true, taskId:$taskId, branch:$branch, base:$base,
       salvageDirty:$dirty, kill:{paneId:$paneId, tabId:$tabId},
       resume:{launcher:$launcher, args:["--resume", $taskId, "--project", $PROJECT]},
       reason:$reason}'
  exit 0
fi

# ---------------------------------------------------------------- 2. mark ---
PLAN="$STATE/$TASK_ID.relaunch"
jq -nc --arg at "$(date +%s)000" --arg reason "$REASON" --arg base "$base" --arg branch "$branch" \
  '{at:($at|tonumber), reason:$reason, base:$base, branch:$branch}' > "$PLAN.tmp.$$" \
  && mv "$PLAN.tmp.$$" "$PLAN" || die "cannot write the relaunch plan: $PLAN"
log "relaunch plan written: $PLAN (branch=$branch base=$base)"

# ---------------------------------------------------------------- 3. kill ---
# Same pane/tab teardown as the launcher's close_tab(): order tab first, then
# pane, both idempotent (fleet-watch.sh pane liveness then reports pane dead;
# the ORIGINAL launcher exits on the .relaunch marker without failing).
if [[ -n "$TAB_ID" ]]; then
  herdr --session "$SESSION" tab close "$TAB_ID" >/dev/null 2>&1 \
    && log "tab closed: $TAB_ID" || log "tab close: already closed ($TAB_ID)"
fi
if [[ -n "$PANE_ID" ]]; then
  herdr --session "$SESSION" pane close "$PANE_ID" >/dev/null 2>&1 \
    && log "pane closed: $PANE_ID" || log "pane close: already closed ($PANE_ID)"
fi

# ---------------------------------------------------------------- 4. resume ---
log "resuming via launcher: $LAUNCHER_BIN --resume $TASK_ID --project $PROJECT"
exec bash "$LAUNCHER_BIN" --resume "$TASK_ID" --project "$PROJECT"