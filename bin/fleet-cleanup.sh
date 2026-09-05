#!/usr/bin/env bash
# pi-fleet · one shared idempotent worktree cleanup owner (gh-8)
#
# Resolves the durable cleanup of a task worktree with EXACT owner guards and
# persists every attempt. It is the SINGLE cleanup routine used by every
# lifecycle path: normal completion, direct fleet_abort, launcher-observed
# abort, failure, timeout, launcher-crash recovery and startup reconciliation
# (see issue #8, Phase 2).
#
# Usage:
#   bin/fleet-cleanup.sh <task-id> [--classify-only]
#     --classify-only : classify + persist only, NEVER invoke `treehouse
#                       return` (report-only reconciliation — the Phase-7
#                       rollout default).
#   env: FLEET_STATE_HOME (default ~/.pi/fleet)
#
# Contract (Phase 2):
#   1. Load the persisted path + exact lease identity from the task record.
#      A record WITHOUT a persisted lease identity (leaseId/leaseHolder) is
#      NOT safe to release automatically: result `pending` (operator review,
#      Phase 4.5).
#   2. Re-read `treehouse status --json` immediately before any return.
#   3. Caller ordering contract: the task UI (herdr pane/tab) MUST be closed
#      BEFORE this script runs — Treehouse's return kills the processes in
#      the worktree, so the process-termination ordering requires UI close
#      first. The launcher does close_tab && release_worktree in every path;
#      the extension's fleet_abort closes pane/tab first; the reconciler only
#      touches tasks whose pane is already gone.
#   4. Return ONLY with an exact owner guard: `--if-lease-id <persisted id>`
#      preferred; `--if-lease-holder 'pi-fleet:<task-id>'` when the lease id
#      is unavailable. NEVER an unguarded `treehouse return --force`.
#   5. NEVER suppress the real exit status/output: both are captured and
#      persisted (redacted). The result is one of
#      released | already_released | conflict | pending | failed.
#   6. Idempotent across crashes and concurrent callers: a per-task lock plus
#      the Treehouse-level guard make concurrent callers converge on ONE
#      durable record. Active tasks (spawning/running/needs_input) are NEVER
#      auto-released.
#
# Exit codes: 0 = classification persisted (read the record for the result);
#             1 = could not persist the record (callers must NOT claim release);
#             2 = usage / missing task record.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASK_ID="${1:-}"
CLASSIFY_ONLY=0
[[ "${2:-}" == "--classify-only" ]] && CLASSIFY_ONLY=1
STATE_HOME="${FLEET_STATE_HOME:-$HOME/.pi/fleet}"
STATE_JSON="$STATE_HOME/$TASK_ID.json"
CLEANUP_FILE="$STATE_HOME/$TASK_ID.cleanup.json"
LOCK_DIR="$STATE_HOME/$TASK_ID.cleanup.lock"
LOCK_STALE_S="${FLEET_CLEANUP_LOCK_STALE_S:-30}"
TREEHOUSE_BIN="${FLEET_TREEHOUSE_BIN:-treehouse}"

log() { printf '[fleet-cleanup] %s\n' "$*"; }
herr() { printf '[fleet-cleanup] ERROR: %s\n' "$*" >&2; }

[[ -n "$TASK_ID" ]] || { echo "usage: fleet-cleanup.sh <task-id> [--classify-only]" >&2; exit 2; }
[[ -f "$STATE_JSON" ]] || { herr "no task record: $STATE_JSON"; exit 2; }
case "$TASK_ID" in */*|*..*) herr "invalid task id: $TASK_ID"; exit 2 ;; esac

# ------------------------------------------------------------ record I/O ----
record="{}"
[[ -s "$CLEANUP_FILE" ]] && record="$(cat "$CLEANUP_FILE" 2>/dev/null || echo '{}')"

_record_save() {  # <result> <reason> <guard> <guard_value> <exit_status> <output>
  local result="$1" reason="$2" guard="$3" guard_val="$4" exit_st="$5" out="$6"
  local now_m attempt
  now_m="$(date +%s)000"
  attempt="$(jq -nc --arg at "$now_m" --arg result "$result" --arg guard "$guard" \
    --arg guardVal "$guard_val" --argjson exitStatus "$exit_st" --arg out "$out" --arg reason "$reason" \
    '{at:($at|tonumber), result:$result, guard:$guard, guardValue:$guardVal,
      exitStatus:$exitStatus, output:$out, reason:$reason}' 2>/dev/null)" || exit 1
  # one record shape hosts task identity + the append-only attempt log; the
  # lastResult always converges on the NEWEST persisted attempt (atomic tmp+mv
  # per write — a crash between attempts leaves the previous valid record).
  record="$(jq --argjson a "$attempt" --arg taskId "$TASK_ID" --arg path "${path:-}" \
    --arg leaseId "${lease_id:-}" --arg holder "${holder:-}" --arg guardKind "${guard_kind:-}" \
    '{taskId:$taskId, path:$path, leaseId:(if $leaseId == "" then null else $leaseId end),
      leaseHolder:$holder, guardKind:$guardKind,
      lastResult:$a.result, lastResultAt:$a.at,
      attempts:((.attempts // []) + [$a])}' <<<"$record" 2>/dev/null)" || record="{}"
  printf '%s\n' "$record" > "$CLEANUP_FILE.tmp" 2>/dev/null || return 1
  mv "$CLEANUP_FILE.tmp" "$CLEANUP_FILE" 2>/dev/null || return 1
  # mirror into the task state json (extension reads .cleanup from the record)
  jq --argjson rec "$record" '.cleanup = $rec' "$STATE_JSON" \
    > "$STATE_JSON.tmp" 2>/dev/null && mv "$STATE_JSON.tmp" "$STATE_JSON" 2>/dev/null
  return 0
}

# ------------------------------------------------------------------ lock ----
_acquire_lock() {
  local i pid
  for ((i = 0; i < 20; i++)); do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      printf '%s\n' "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
      return 0
    fi
    # stale lock takeover: the holder pid is gone or the lock is aged
    if [[ -f "$LOCK_DIR/pid" ]]; then
      pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || echo 0)"
      if ! kill -0 "$pid" 2>/dev/null; then
        rmdir "$LOCK_DIR" 2>/dev/null || rm -rf "$LOCK_DIR" 2>/dev/null || true
        continue
      fi
    fi
    if [[ -d "$LOCK_DIR" ]] && [[ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +$((LOCK_STALE_S / 60)) 2>/dev/null)" ]]; then
      rmdir "$LOCK_DIR" 2>/dev/null || true
      continue
    fi
    sleep 0.2
  done
  return 1
}
_release_lock() { rmdir "$LOCK_DIR" 2>/dev/null || rm -rf "$LOCK_DIR" 2>/dev/null || true; }

# ----------------------------------------------------------- redaction ----
_redact() {  # truncate + strip obvious secrets from raw tool output
  local s="$1"
  s="$(printf '%s' "$s" | sed -E 's/(token|secret|password|key|auth)[=:][^ ]{4,}/\1=<redacted>/Ig' | tr '\n' ' ')"
  printf '%s' "${s:0:300}"
}

# --------------------------------------------------------------- classify ----
# classify <result> <reason...> — persists and exits 0 (unless save fails).
classify() {
  local result="$1"; shift
  local reason="$*" rc
  _record_save "$result" "$reason" "${guard_kind:-none}" "${guard_value:-}" "${exit_status:-null}" "${_output:-}"
  rc=$?
  log "$result: $reason"
  return $rc
}

# ---------------------------------------------------------------- main ----
path="$(jq -r '.worktreePath // .cwd // ""' "$STATE_JSON" 2>/dev/null)"
lease_id="$(jq -r '.leaseId // ""' "$STATE_JSON" 2>/dev/null)"
holder="$(jq -r '.leaseHolder // ""' "$STATE_JSON" 2>/dev/null)"
task_state="$(jq -r '.state // ""' "$STATE_JSON" 2>/dev/null)"
project="$(jq -r '.project // ""' "$STATE_JSON" 2>/dev/null)"
guard_kind="none"; guard_value=""; exit_status="null"; _output=""

if ! _acquire_lock; then
  classify "pending" "another cleanup in progress (lock busy) — retryable" || exit 1
  _release_lock; exit 0
fi

# --- active-task guard: NEVER auto-release -------------------------------------------------
case "$task_state" in
  spawning|running|needs_input)
    classify "pending" "active task (state=$task_state) is never auto-released" || exit 1
    _release_lock; exit 0 ;;
esac

# --- terminal but without a worktree ---------------------------------------------------------
if [[ -z "$path" ]]; then
  classify "already_released" "no worktree on record — nothing to release" || exit 1
  _release_lock; exit 0
fi

# --- ambiguous record: no persisted exact lease identity → operator review -------------------
if [[ -z "$lease_id" && -z "$holder" ]]; then
  classify "pending" "ambiguous record: no persisted lease identity (leaseId/leaseHolder) — operator review, never path-only cleanup" || exit 1
  _release_lock; exit 0
fi

# --- re-read treehouse status immediately before any return ----------------------------------
_work_dir="${project:-${path%/*}}"
status_out="$(cd "$_work_dir" 2>/dev/null && "$TREEHOUSE_BIN" status --json 2>&1)"
status_rc=$?
if [[ $status_rc -ne 0 ]] || ! printf '%s' "$status_out" | jq -e . >/dev/null 2>&1; then
  classify "pending" "treehouse status unavailable (rc=$status_rc): retryable" || exit 1
  _release_lock; exit 0
fi
# malformed shape (not a JSON array of pool rows) → retryable, never a verdict
if ! printf '%s' "$status_out" | jq -e 'type == "array"' >/dev/null 2>&1; then
  classify "pending" "malformed treehouse status (not a pool array): retryable" || exit 1
  _release_lock; exit 0
fi

# join the persisted identity to the live pool by EXACT path (never path-only cleanup:
# the lease identity must match too).
row="$(printf '%s' "$status_out" | jq -c --arg p "$path" '.[] | select(.path == $p)' 2>/dev/null | tail -1)"
if [[ -z "$row" ]]; then
  classify "already_released" "no live lease at the exact path ($path) — verified via treehouse status" || exit 1
  _release_lock; exit 0
fi
live_lease="$(printf '%s' "$row" | jq -r '.lease_id // ""' 2>/dev/null)"
live_holder="$(printf '%s' "$row" | jq -r '.lease_holder // ""' 2>/dev/null)"

if [[ -n "$lease_id" ]]; then
  if [[ -z "$live_lease" || "$live_lease" != "$lease_id" ]]; then
    classify "conflict" "path $path held by a DIFFERENT lease ($live_lease): never returned" || exit 1
    _release_lock; exit 0
  fi
  guard_kind="lease-id"; guard_value="$lease_id"
else
  if [[ -z "$live_holder" || "$live_holder" != "$holder" ]]; then
    classify "conflict" "path $path held by a DIFFERENT holder ($live_holder): never returned" || exit 1
    _release_lock; exit 0
  fi
  guard_kind="lease-holder"; guard_value="$holder"
fi

# --- exact matching live identity: guarded return (unless classify-only) ---------------------
if [[ "$CLASSIFY_ONLY" == "1" ]]; then
  classify "pending" "matching lease held (classify-only reconcile pass): no return attempted, result pending" || exit 1
  _release_lock; exit 0
fi

# matching live lease but the worktree DIRECTORY is gone: never falsify a release
# — record pending (operator review) instead of attempting a return on a ghost path.
if [[ ! -d "$path" ]]; then
  classify "pending" "matching lease alive at $path but the worktree dir is missing — operator review, release not claimed" || exit 1
  _release_lock; exit 0
fi

if [[ "$guard_kind" == "lease-id" ]]; then
  rel_out="$(cd "$_work_dir" 2>/dev/null && "$TREEHOUSE_BIN" return --force --if-lease-id "$guard_value" "$path" 2>&1)"
else
  rel_out="$(cd "$_work_dir" 2>/dev/null && "$TREEHOUSE_BIN" return --force --if-lease-holder "$guard_value" "$path" 2>&1)"
fi
rel_rc=$?
exit_status="$rel_rc"
_output="$(_redact "$rel_out")"

if [[ "$rel_rc" -eq 0 ]]; then
  classify "released" "guarded return confirmed (guard=$guard_kind)" || exit 1
  _release_lock; exit 0
fi

# --- nonzero return: re-verify the lease (the guard may have made it a no-op) ----------------
status_out2="$(cd "$_work_dir" 2>/dev/null && "$TREEHOUSE_BIN" status --json 2>&1)"
row2="$(printf '%s' "$status_out2" | jq -c --arg p "$path" '.[] | select(.path == $p)' 2>/dev/null | tail -1)"
if printf '%s' "$status_out2" | jq -e . >/dev/null 2>&1 \
   && { [[ -z "$row2" ]] || [[ -n "$lease_id" && "$(printf '%s' "$row2" | jq -r '.lease_id // ""' 2>/dev/null)" != "$lease_id" ]] \
      || { [[ -z "$lease_id" ]] && [[ "$(printf '%s' "$row2" | jq -r '.lease_holder // ""' 2>/dev/null)" != "$holder" ]] }; }; then
  classify "already_released" "guarded return rc=$rel_rc but the lease at $path is gone (verified re-check): idempotent no-op" || exit 1
  _release_lock; exit 0
fi

classify "failed" "guarded return rc=$rel_rc (guard=$guard_kind, $path): dirty/unreturnable worktree or treehouse refusal — artifacts preserved, pending recovery: $_output" || exit 1
_release_lock
exit 0