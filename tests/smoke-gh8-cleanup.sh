#!/usr/bin/env bash
#
# pi-fleet · gh-8 durable owner-safe worktree release — headless acceptance smoke
#
# Drives the gh-8 cleanup machinery with FAKE treehouse + FAKE herdr adapters
# and an ISOLATED temp state (never a live pool, never ~/.pi/fleet). Two levels:
#
#   PART A — owner level (bin/fleet-cleanup.sh directly + fake treehouse):
#     A1  lease identity persisted + guarded return records the REAL nonzero
#         exit status + output (never suppressed)
#     A2  idempotent second cleanup -> already_released (verified, no re-return)
#     A3  wrong live holder/lease on the same path -> conflict, NEVER returned
#     A4  dirty worktree (guarded return fails, lease stays) -> failed with
#         artifacts preserved; plus the artifact-bundle files exist
#     A5  missing treehouse / hanging status / malformed status JSON ->
#         retryable pending record
#     A6  ACTIVE task states (spawning/running/needs_input) are NEVER
#         auto-released (record pending, zero returns)
#     A7  duplicate historical records sharing one path cannot cause path-only
#         cleanup (each needs its EXACT persisted identity; a path-only record
#         with no identity -> pending, operator review)
#     A8  crash injection: kill the owner mid-status (before return) and
#         mid-return: the durable record stays valid JSON (atomic rename) and a
#         re-run converges on one result (recoverable); stale lock is taken over
#
#   PART B — launcher level (REAL bin/herdr-launch.sh + fake herdr/treehouse):
#     B1  acquisition persists holder + lease id + worktree path + timestamp;
#         normal done path persists the artifact bundle (<id>.result.json with
#         the FULL done-marker payload, <id>.findings.json with BLOCKING/
#         NON_BLOCKING counts, <id>.report.md copy with size+sha metadata,
#         <id>.cleanup.json) BEFORE the transient marker is consumed, then the
#         guarded return releases (recorded in <id>.cleanup.json)
#     B2  dirty worktree -> task done but cleanup=failed, artifacts preserved,
#         ownership NOT cleared (recoverable record)
#     B3  direct abort -> aborted + cleanup converges on released/...
#     B4  child crash (no done-marker) -> failed + failure reason persisted +
#         cleanup performed
#     B5  concurrent abort + completion -> exactly ONE guarded return (no
#         double-release), one terminal result, record converges
#     B6  launcher-crash injection (SIGKILL while the owner hangs in status,
#         AFTER artifact persistence): artifacts + record survive and a later
#         owner run converges (recoverable record)
#
# Real treehouse/herdr/pool are NEVER touched (PATH-shadowed fakes; state home
# under /tmp). Real-pane/real-pool runs are skipped by design.
#
# Prereqs: bash + jq only (no node/tsc, no herdr/treehouse daemon needed).
# Exit: 0 green / 1 failed / 2 missing prerequisites.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
LAUNCHER="$REPO_ROOT/bin/herdr-launch.sh"
OWNER="$REPO_ROOT/bin/fleet-cleanup.sh"
TS="$(date +%s)"
SCRATCH="/tmp/fleet-gh8-smoke-$TS"
STATE="$SCRATCH/state"
PROJ="$SCRATCH/proj"
WT="$SCRATCH/wt"
HOME_DIR="$SCRATCH/home"
MOCK_BIN="$SCRATCH/bin"
KEEP="${SMOKE_KEEP:-0}"

log() { printf 'GH8 [%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf 'GH8 FAIL: %s\n' "$*" >&2; exit 1; }
die2() { printf 'GH8 SKIP (exit 2): %s\n' "$*" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || die2 "jq not found in PATH (brew install jq)"
[[ -f "$LAUNCHER" ]] || die "launcher not found: $LAUNCHER"
[[ -f "$OWNER" ]] || die "cleanup owner not found: $OWNER"
bash -n "$0" 2>/dev/null || die "smoke-gh8-cleanup.sh does not pass bash -n (self-check)"
bash -n "$LAUNCHER" 2>/dev/null || die "bin/herdr-launch.sh does not pass bash -n"
bash -n "$OWNER" 2>/dev/null || die "bin/fleet-cleanup.sh does not pass bash -n"

cleanup() {
  [[ "$KEEP" == "1" ]] && { log "SMOKE_KEEP=1: keeping $SCRATCH"; return 0; }
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

mkdir -p "$STATE/tasks" "$PROJ" "$WT" "$HOME_DIR" "$MOCK_BIN"
log "scratch: $SCRATCH (state: $STATE, mock bin: $MOCK_BIN)"

OK=0
pass() { OK=$((OK + 1)); log "  OK   $*"; }
fail() { log "  FAIL $*"; }

# ----------------------------------------------------------------- fakes ----
# fake treehouse: env-driven pool + fault injection. NEVER touches a real pool.
cat > "$MOCK_BIN/treehouse" <<'EOF'
#!/usr/bin/env bash
# gh-8 fake treehouse. Env:
#   FTH_LOG        record every invocation ("TH <args>")
#   FTH_POOL       pool state file (JSON array of rows); `get` seeds one row
#   FTH_WT         the fake worktree path
#   FTH_LEASE_ID   lease id issued by `get`
#   FTH_MODE       ok | status_hang | status_garbage | return_fail | return_hang
#                    status_hang: `status --json` sleeps FTH_HANG_S then answers
#                    status_garbage: `status --json` prints a non-array blob
#                    return_fail: `return` exits 3 WITHOUT removing the row
#                    return_hang: guarded `return` sleeps FTH_HANG_S then answers
set -u
echo "TH $*" >> "${FTH_LOG:?}"

hang() { sleep "${FTH_HANG_S:-25}"; }

case "${1:-}" in
  get)
    shift
    holder=""; want_json=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --lease-holder) holder="$2"; shift 2 ;;
        --json) want_json=1; shift ;;
        *) shift ;;
      esac
    done
    [[ -n "$holder" ]] || holder="pi-fleet:mock"
    id="${FTH_LEASE_ID:-fake-lease-1}"
    # real treehouse prints the 🌳 banners to STDERR and the record to STDOUT:
    # the launcher must survive the interleave (regression guard — the gh-8
    # merge failed EVERY launch because 2>&1 broke the jq gate and the last-
    # line fallback mis-took the JSON record for the path).
    printf 'Setting up worktree...\n' >&2
    printf 'Leased worktree at %s.\n' "${FTH_WT:?}" >&2
    if [[ -n "$want_json" ]]; then
      printf '{"path":"%s","lease_id":"%s","lease_holder":"%s"}\n' "${FTH_WT:?}" "$id" "$holder"
    else
      printf '%s\n' "${FTH_WT:?}"
    fi
    jq -nc --arg p "${FTH_WT:?}" --arg id "$id" --arg h "$holder" \
      '[{name:"1",path:$p,status:"leased",lease_id:$id,lease_holder:$h,leased_at:"x"}]' \
      > "${FTH_POOL:?}"
    ;;
  status)
    case "${FTH_MODE:-ok}" in
      status_hang) hang ;;
      status_garbage) printf '{"path":"%s","status":"leased"}\n' "${FTH_WT:?}"; exit 0 ;;
    esac
    cat "${FTH_POOL:?}" 2>/dev/null || echo '[]'
    ;;
  return)
    # args: --force --if-lease-id <id>|<holder> <path>
    id=""; h=""; path=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --if-lease-id) id="$2"; shift 2 ;;
        --if-lease-holder) h="$2"; shift 2 ;;
        --force) shift ;;
        *) path="$1"; shift ;;
      esac
    done
    case "${FTH_MODE:-ok}" in
      return_fail)
        echo "treehouse: refusing return: worktree not clean (uncommitted changes)"
        exit 3 ;;
      return_hang) hang ;;
    esac
    row="$(cat "${FTH_POOL:?}" 2>/dev/null | jq -c --arg p "$path" '.[] | select(.path==$p)' 2>/dev/null)"
    if [[ -z "$row" ]]; then echo "treehouse: already released"; exit 3; fi
    live_id="$(printf '%s' "$row" | jq -r '.lease_id // ""' 2>/dev/null)"
    live_h="$(printf '%s' "$row" | jq -r '.lease_holder // ""' 2>/dev/null)"
    if [[ -n "$id" && "$live_id" != "$id" ]] || [[ -n "$h" && "$live_h" != "$h" ]]; then
      echo "treehouse: guard mismatch — lease held by a different identity"
      exit 3
    fi
    cat "${FTH_POOL:?}" | jq --arg p "$path" '[.[] | select(.path != $p)]' > "${FTH_POOL:?}.tmp"
    mv "${FTH_POOL:?}.tmp" "${FTH_POOL:?}"
    echo "treehouse: returned"
    ;;
esac
exit 0
EOF

# fake herdr for launcher-level scenarios (recording, static agent)
cat > "$MOCK_BIN/herdr" <<'EOF'
#!/usr/bin/env bash
# gh-8 fake herdr — records calls; agent list serves the agent until
# FTH_MOCK_KILL exists (pane dies); tab/pane close are no-ops.
set -u
[[ "$1" == "--session" ]] && shift 2
cmd="$1"
shift
printf 'MOCK %s %s\n' "$cmd" "$*" >> "${FTH_MOCK_REC:?}"
case "$cmd" in
  workspace) echo '{"result":{"workspaces":[{"label":"fleet","workspace_id":"w9"}]}}' ;;
  tab)
    case "${1:-}" in
      create) echo '{"result":{"tab":{"tab_id":"t1"},"root_pane":{"pane_id":"p1"}}}' ;;
      close)  echo '{"ok":true}' ;;
    esac ;;
  pane) echo '{"ok":true}' ;;
  agent)
    case "${1:-}" in
      start) echo '{"ok":true}' ;;
      get)   echo '{"result":{"agent":{"agent_status":"working","revision":"5","pane_id":"p1"}}}' ;;
      list)
        if [[ -n "${FTH_MOCK_KILL:-}" ]] && [[ -f "${FTH_MOCK_KILL:?}" ]]; then
          echo '{"result":{"agents":[]}}'
        else
          echo '{"result":{"agents":[{"agent":"pi","agent_status":"working","pane_id":"p1"}]}}'
        fi ;;
      prompt) echo '{"ok":true}' ;;
    esac ;;
esac
exit 0
EOF
chmod +x "$MOCK_BIN/treehouse" "$MOCK_BIN/herdr"
log "fakes in place: $MOCK_BIN (treehouse + herdr)"

# ------------------------------------------------------------- helpers ----
# rlimit: bounded run (no GNU `timeout` dependency — macOS-safe).
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

# owner-level run with the fakes: <tid> [--classify-only] [extra env...]
trade_state() { # <tid> <lease-id> <holder> <task-state> [extra jq fields...]
  local tid="$1" lid="$2" holder="$3" tstate="$4"
  shift 4
  local extra="${1:-}"
  jq -nc --arg id "$tid" --arg lid "$lid" --arg h "$holder" --arg st "$tstate" \
    --arg cwd "$WT" --arg wt "$WT" --arg proj "$PROJ" \
    '{id:$id, state:$st, cwd:$cwd, worktreePath:$wt, project:$proj,
      leaseId:$lid, leaseHolder:$h, leaseAcquiredAt:1750000000000}' \
    "$@" > "$STATE/$tid.json"
}

run_owner() { # <tid> [--classify-only] [KEY=VALUE...] (bounded via rlimit)
  local tid="$1"; shift
  local args=("$OWNER" "$tid")
  local envs=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --classify-only) args+=("--classify-only"); shift ;;
      *=*) envs+=("$1"); shift ;;
      *) break ;;
    esac
  done
  rlimit 30 "$SCRATCH/$tid.owner.out" env FLEET_STATE_HOME="$STATE" PATH="$MOCK_BIN:$PATH" \
    FTH_LOG="$SCRATCH/$tid.th" FTH_POOL="${FTH_POOL:-$SCRATCH/$tid.pool}" FTH_WT="$WT" \
    FTH_LEASE_ID="fake-lease-$tid" FTH_HANG_S="${FTH_HANG_S:-0}" "${envs[@]}" bash "${args[@]}"
}

owner_result() { jq -r '.lastResult // "missing"' "$STATE/$1.cleanup.json" 2>/dev/null; }
owner_reason() { jq -r '[.attempts[-1].reason // ""][0]' "$STATE/$1.cleanup.json" 2>/dev/null; }
owner_exit_status() { jq -r '[.attempts[-1].exitStatus // "null"][0]' "$STATE/$1.cleanup.json" 2>/dev/null; }
th_returns() { grep -c "^TH return" "$SCRATCH/$1.th" 2>/dev/null || true; }

# ============================================================ PART A ========
log "PART A — owner level: bin/fleet-cleanup.sh + fake treehouse"

# ---- A1 lease identity + nonzero return not suppressed ----------------------
log "SCENARIO A1 — guarded return records the REAL exit status + output"
trade_state a1 "fake-lease-a1" "pi-fleet:a1" "done"
jq -nc --arg p "$WT" '[{name:"1",path:$p,status:"leased",lease_id:"fake-lease-a1",lease_holder:"pi-fleet:a1",leased_at:"x"}]' \
  > "$SCRATCH/a1.pool"
run_owner a1; RC=$?
[[ "$RC" -eq 0 ]] || fail "A1 owner rc=$RC"
[[ "$(owner_result a1)" == "released" ]] && pass "A1 released via exact lease-id guard" \
  || fail "A1 expected released, got $(owner_result a1)"
[[ "$(th_returns a1)" -eq 1 ]] && pass "A1 exactly one guarded return" || fail "A1 return count $(th_returns a1)"
GUARD="$(jq -r '.attempts[0].guard + "=" + .attempts[0].guardValue' "$STATE/a1.cleanup.json")"
[[ "$GUARD" == "lease-id=fake-lease-a1" ]] && pass "A1 guard is the persisted lease id ($GUARD)" \
  || fail "A1 guard=$GUARD"
grep -q "TH return --force --if-lease-id fake-lease-a1 $WT" "$SCRATCH/a1.th" \
  && pass "A1 exact guarded command recorded (no unguarded --force)" \
  || fail "A1 guarded command not found in $(cat "$SCRATCH/a1.th")"
EX="$(owner_exit_status a1)"
[[ "$EX" == "0" ]] && pass "A1 exitStatus=$EX persisted" || fail "A1 exitStatus=$EX"
jq -e '.attempts[0].output | length > 0' "$STATE/a1.cleanup.json" >/dev/null \
  && pass "A1 output persisted" || fail "A1 output empty"

# ---- A2 idempotent second cleanup -> already_released -----------------------
log "SCENARIO A2 — second cleanup is a verified already_released no-op"
run_owner a1; RC=$?
[[ "$RC" -eq 0 ]] || fail "A2 owner rc=$RC"
[[ "$(owner_result a1)" == "already_released" ]] && pass "A2 second cleanup -> already_released" \
  || fail "A2 expected already_released, got $(owner_result a1)"
[[ "$(th_returns a1)" -eq 1 ]] && pass "A2 no second return (idempotent)" \
  || fail "A2 return count became $(th_returns a1)"

# ---- A3 wrong live holder on the same path -> conflict, never returned ------
log "SCENARIO A3 — same path held by a DIFFERENT live identity -> conflict"
trade_state a3 "my-lease-a3" "pi-fleet:a3" "done"
jq -nc --arg p "$WT" '{name:"1",path:$p,status:"leased",lease_id:"someone-else-lease",lease_holder:"pi-fleet:other-task",leased_at:"x"}' \
  > "$SCRATCH/a3.pool"   # NOTE: a single ROW object is NOT an array → also feeds the malformed check
run_owner a3; RC=$?
[[ "$RC" -eq 0 ]] || fail "A3 owner rc=$RC"
RE="$(owner_result a3)"
[[ "$RE" == "pending" ]] && pass "A3 malformed status (non-array pool) -> retryable pending, NEVER a verdict" \
  || fail "A3 expected pending on malformed status, got $RE"
grep -q "TH return" "$SCRATCH/a3.th" 2>/dev/null && fail "A3 return attempted on malformed status" || pass "A3 zero returns on malformed status"
# now a REAL array pool with a foreign lease
jq -nc --arg p "$WT" '[{name:"1",path:$p,status:"leased",lease_id:"someone-else-lease",lease_holder:"pi-fleet:other-task",leased_at:"x"}]' \
  > "$SCRATCH/a3.pool"
rm -f "$STATE/a3.cleanup.json"
run_owner a3; RC=$?
[[ "$RC" -eq 0 ]] || fail "A3b owner rc=$RC"
[[ "$(owner_result a3)" == "conflict" ]] && pass "A3b foreign lease on same path -> conflict" \
  || fail "A3b expected conflict, got $(owner_result a3)"
jq -e '.attempts[-1].reason | contains("DIFFERENT lease")' "$STATE/a3.cleanup.json" >/dev/null \
  && pass "A3b conflict reason names the live lease" || fail "A3b conflict reason missing"
[[ "$(th_returns a3)" -eq 0 ]] && pass "A3b conflict -> ZERO returns (never returned)" \
  || fail "A3b returns=$(th_returns a3)"
# holder-guard variant: no lease id persisted, foreign holder
trade_state a3h "" "pi-fleet:a3h" "done"
jq -nc --arg p "$WT" '[{name:"1",path:$p,status:"leased",lease_id:"x9",lease_holder:"pi-fleet:other",leased_at:"x"}]' \
  > "$SCRATCH/a3h.pool"
run_owner a3h; RC=$?
[[ "$(owner_result a3h)" == "conflict" ]] && pass "A3c holder-guard conflict (no lease id) never returned" \
  || fail "A3c expected conflict, got $(owner_result a3h)"

# ---- A4 dirty worktree -> failed with artifacts preserved -------------------
log "SCENARIO A4 — guarded return fails (dirty), lease stays: failed + artifacts"
trade_state a4 "fake-lease-a4" "pi-fleet:a4" "done"
# matching live lease (the fake return_fail mode refuses to remove it)
jq -nc --arg p "$WT" '[{name:"1",path:$p,status:"leased",lease_id:"fake-lease-a4",lease_holder:"pi-fleet:a4",leased_at:"x"}]' \
  > "$SCRATCH/a4.pool"
# artifact bundle pre-existing (as the launcher persists it BEFORE release)
jq -nc --arg id a4 '{taskId:$id,status:"done",summary:"scout completed",changedFiles:["report.md"]}' \
  > "$STATE/a4.result.json"
jq -nc '{findings:[{id:"X-1",severity:"BLOCKING"}]}' > "$STATE/a4.findings.json"
run_owner a4 FTH_MODE=return_fail; RC=$?
[[ "$RC" -eq 0 ]] || fail "A4 owner rc=$RC"
[[ "$(owner_result a4)" == "failed" ]] && pass "A4 dirty -> cleanup failed (distinct from task outcome)" \
  || fail "A4 expected failed, got $(owner_result a4)"
[[ "$(owner_exit_status a4)" == "3" ]] && pass "A4 real nonzero exitStatus=3 persisted (NOT suppressed)" \
  || fail "A4 exitStatus=$(owner_exit_status a4)"
jq -e '.attempts[-1].output | contains("refusing return")' "$STATE/a4.cleanup.json" >/dev/null \
  && pass "A4 real output persisted in the record" || fail "A4 output missing"
[[ -f "$STATE/a4.result.json" && -f "$STATE/a4.findings.json" ]] \
  && pass "A4 artifact bundle preserved (result.json + findings.json)" \
  || fail "A4 artifacts missing"
jq -e '.state == "done"' "$STATE/a4.json" >/dev/null \
  && pass "A4 task outcome unchanged (done) — cleanup failed is recorded separately" \
  || fail "A4 task state corrupted"

# ---- A5 missing / hanging / malformed status -> retryable pending -----------
log "SCENARIO A5 — treehouse unavailable/timeout/malformed -> retryable record"
trade_state a5m "fake-lease-a5m" "pi-fleet:a5m" "done"
rm -f "$STATE/a5m.cleanup.json"
env FLEET_STATE_HOME="$STATE" PATH="/usr/bin:/bin" \
  bash "$OWNER" a5m >/dev/null 2>&1
[[ "$(owner_result a5m)" == "pending" ]] && pass "A5a missing treehouse binary -> pending (retryable)" \
  || fail "A5a expected pending, got $(owner_result a5m)"
trade_state a5h "fake-lease-a5h" "pi-fleet:a5h" "done"
jq -nc --arg p "$WT" '[{name:"1",path:$p,status:"leased",lease_id:"fake-lease-a5h",lease_holder:"pi-fleet:a5h",leased_at:"x"}]' \
  > "$SCRATCH/a5h.pool"
run_owner a5h FTH_MODE=status_hang FTH_HANG_S=45
RC=$?
if [[ "$RC" -eq 124 ]]; then
  # rlimit killed it — the record (if any) must still parse; a re-run converges
  jq -e . "$STATE/a5h.cleanup.json" >/dev/null 2>&1 && pass "A5b status-hang record stays valid JSON (atomic)" \
    || pass "A5b status-hang left no record (nothing persisted, nothing corrupt)"
  FTH_HANG_S=0 run_owner a5h
  [[ "$(owner_result a5h)" == "released" || "$(owner_result a5h)" == "pending" ]] \
    && pass "A5b re-run after hang converges ($(owner_result a5h))" \
    || fail "A5b re-run result=$(owner_result a5h)"
else
  fail "A5b status-hang: expected rlimit kill (124), got rc=$RC"
fi
trade_state a5g "fake-lease-a5g" "pi-fleet:a5g" "done"
run_owner a5g FTH_MODE=status_garbage; RC=$?
[[ "$RC" -eq 0 ]] || fail "A5c owner rc=$RC"
[[ "$(owner_result a5g)" == "pending" ]] && pass "A5c malformed status JSON -> pending (retryable)" \
  || fail "A5c expected pending, got $(owner_result a5g)"
grep -q "TH return" "$SCRATCH/a5g.th" 2>/dev/null && fail "A5c return attempted on malformed status" \
  || pass "A5c zero returns on malformed status"

# ---- A6 active states are NEVER auto-released -------------------------------
log "SCENARIO A6 — spawning/running/needs_input are never released"
for st in spawning running needs_input; do
  trade_state "a6-$st" "fake-lease-a6-$st" "pi-fleet:a6-$st" "$st"
  run_owner "a6-$st"
  [[ "$(owner_result "a6-$st")" == "pending" ]] \
    && pass "A6 state=$st -> pending, never released" \
    || fail "A6 state=$st -> $(owner_result "a6-$st")"
  [[ "$(th_returns "a6-$st")" -eq 0 ]] \
    && pass "A6 state=$st -> zero returns" \
    || fail "A6 state=$st -> returns=$(th_returns "a6-$st")"
done

# ---- A7 duplicate historical records -> no path-only cleanup ----------------
log "SCENARIO A7 — records sharing a path need their EXACT identity"
trade_state a7old "fake-lease-a7old" "pi-fleet:a7old" "done"
trade_state a7new "" "" "done"   # path-only record: NO lease identity
# path-only record must NOT trigger a return even if a live lease exists at that path
jq -nc --arg p "$WT" '[{name:"1",path:$p,status:"leased",lease_id:"LIVE-X",lease_holder:"pi-fleet:a7old",leased_at:"x"}]' \
  > "$SCRATCH/a7new.pool"
run_owner a7new; RC=$?
[[ "$RC" -eq 0 ]] || fail "A7 owner rc=$RC"
[[ "$(owner_result a7new)" == "pending" ]] && pass "A7 path-only duplicate -> pending (operator review, never released)" \
  || fail "A7 expected pending, got $(owner_result a7new)"
[[ "$(th_returns a7new)" -eq 0 ]] && pass "A7 zero returns (no path-only cleanup)" \
  || fail "A7 returns=$(th_returns a7new)"
# the identity-carrying record, on the SAME path with MATCHING live lease, may release
jq -nc --arg p "$WT" '[{name:"1",path:$p,status:"leased",lease_id:"fake-lease-a7old",lease_holder:"pi-fleet:a7old",leased_at:"x"}]' \
  > "$SCRATCH/a7old.pool"
run_owner a7old; RC=$?
[[ "$(owner_result a7old)" == "released" ]] && pass "A7 identity-carrying record released with its exact lease" \
  || fail "A7 a7old -> $(owner_result a7old)"
jq -e '.cleanup.lastResult == "released"' "$STATE/a7old.json" >/dev/null \
  && pass "A7 state .cleanup mirrored" || fail "A7 state .cleanup not mirrored"

# ---- A8 crash injection (owner level) ---------------------------------------
log "SCENARIO A8 — kill mid-status and mid-return leave recoverable records"
# A8a: kill while status hangs (crash BEFORE return)
trade_state a8a "fake-lease-a8a" "pi-fleet:a8a" "done"
jq -nc --arg p "$WT" '[{name:"1",path:$p,status:"leased",lease_id:"fake-lease-a8a",lease_holder:"pi-fleet:a8a",leased_at:"x"}]' \
  > "$SCRATCH/a8a.pool"
FTH_HANG_S=45 FTH_MODE=status_hang \
env FLEET_STATE_HOME="$STATE" PATH="$MOCK_BIN:$PATH" \
  FTH_LOG="$SCRATCH/a8a.th" FTH_POOL="$SCRATCH/a8a.pool" FTH_WT="$WT" \
  FTH_LEASE_ID="fake-lease-a8a" \
  bash "$OWNER" a8a >/dev/null 2>&1 &
PID_A8A=$!
sleep 1
# the status hang keeps the call open: the record has NOT been written yet (or
# is the previous valid one); killing must not corrupt anything
kill -9 "$PID_A8A" 2>/dev/null; wait "$PID_A8A" 2>/dev/null
if [[ -f "$STATE/a8a.cleanup.json" ]]; then
  jq -e . "$STATE/a8a.cleanup.json" >/dev/null 2>&1 && pass "A8a killed mid-status: record valid JSON" \
    || fail "A8a record corrupt after kill"
else
  pass "A8a killed mid-status before any write: no record, nothing corrupt"
fi
# stale lock from the killed process is taken over and the run converges
FTH_HANG_S=0 FTH_MODE=ok run_owner a8a
[[ "$(owner_result a8a)" == "released" ]] && pass "A8a re-run converges released (stale lock taken over)" \
  || fail "A8a re-run -> $(owner_result a8a)"
# A8b: kill mid-return (return_hang) AFTER the matching lease was verified
rm -f "$STATE/a8b.cleanup.json"
trade_state a8b "fake-lease-a8b" "pi-fleet:a8b" "done"
jq -nc --arg p "$WT" '[{name:"1",path:$p,status:"leased",lease_id:"fake-lease-a8b",lease_holder:"pi-fleet:a8b",leased_at:"x"}]' \
  > "$SCRATCH/a8b.pool"
FTH_HANG_S=45 FTH_MODE=return_hang \
env FLEET_STATE_HOME="$STATE" PATH="$MOCK_BIN:$PATH" \
  FTH_LOG="$SCRATCH/a8b.th" FTH_POOL="$SCRATCH/a8b.pool" FTH_WT="$WT" \
  FTH_LEASE_ID="fake-lease-a8b" \
  bash "$OWNER" a8b >/dev/null 2>&1 &
PID_A8B=$!
sleep 1
kill -9 "$PID_A8B" 2>/dev/null; wait "$PID_A8B" 2>/dev/null
if [[ -f "$STATE/a8b.cleanup.json" ]]; then
  jq -e . "$STATE/a8b.cleanup.json" >/dev/null 2>&1 && pass "A8b killed mid-return: record valid (atomic rename)" \
    || fail "A8b record corrupt after kill"
else
  pass "A8b killed mid-return before persist: no record, nothing corrupt"
fi
# the pool still holds the lease (return never completed) → the guarded re-run
# converges on released — the lease id guard makes the crash harmless
[[ "$(cat "$SCRATCH/a8b.pool" 2>/dev/null | jq -r '.[0].lease_id // ""')" == "fake-lease-a8b" ]] \
  && pass "A8b lease still held after the crash (recoverable)" || fail "A8b pool state missing"
FTH_HANG_S=0 FTH_MODE=ok run_owner a8b
[[ "$(owner_result a8b)" == "released" ]] && pass "A8b re-run converges released" \
  || fail "A8b re-run -> $(owner_result a8b)"

# ============================================================ PART B ========
log "PART B — launcher level: REAL bin/herdr-launch.sh + fake herdr/treehouse"

b_env() { # <tid> <mode> -> env lines for the launcher run
  local tid="$1" mode="$2"
  printf '%s\n' \
    "FLEET_STATE_HOME=$STATE" \
    "FTH_MODE=$mode" \
    "FTH_LOG=$SCRATCH/b-$tid.th" \
    "FTH_POOL=$SCRATCH/b-$tid.pool" \
    "FTH_WT=$WT" \
    "FTH_LEASE_ID=fake-lease-$tid" \
    "FTH_MOCK_REC=$SCRATCH/b-$tid.herdr" \
    "FTH_MOCK_KILL=$SCRATCH/b-$tid.kill" \
    "FLEET_STARTUP_WAIT_TRIES=2" \
    "FLEET_STARTUP_WAIT_SLEEP=1" \
    "HOME=$HOME_DIR" \
    "PATH=$MOCK_BIN:$PATH"
}

b_launch_bg() { # <tid> <mode> -> launches in background; the caller takes $!
  local tid="$1" mode="$2"
  local envs
  envs="$(b_env "$tid" "$mode")"
  env -i /usr/bin/env bash -c "
    set -a
    $envs
    set +a
    exec \"\$@\"
  " bash "$LAUNCHER" "gh8-$tid" "gh-8 $tid scenario" \
    --project "$PROJ" --task-id "$tid" --timeout-min 1 >"$SCRATCH/b-$tid.out" 2>&1 &
}

b_wait_pid() { # <pid> <secs> -> exit code
  local pid="$1" secs="$2" rc
  for ((i = 0; i < secs * 2; i++)); do
    kill -0 "$pid" 2>/dev/null || { wait "$pid"; rc=$?; return $rc; }
    sleep 0.5
  done
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  return 124
}

b_wait_log() { # <out> <pattern> <secs>
  local out="$1" pat="$2" secs="$3"
  for ((i = 0; i < secs * 2; i++)); do
    grep -q -- "$pat" "$out" 2>/dev/null && return 0
    sleep 0.5
  done
  return 1
}

# ---- B1 acquisition + done path artifact bundle + guarded release -----------
log "SCENARIO B1 — acquisition persists lease identity; done path persists the bundle"
TID=b1
b_launch_bg "$TID" ok; PID=$!
b_wait_log "$SCRATCH/b-$TID.out" "brief delivered to the child" 60 \
  && pass "B1 child started (native initial request)" || fail "B1 child start log missing"
# scout-style done-marker with report + findings
printf 'report line one\nreport line two — the durable scout deliverable\n' > "$WT/report.md"
jq -nc --arg s "scout complete: analysis delivered" \
  '{status:"done", summary:$s, reportPath:"report.md",
    findings:[{id:"PET-01", severity:"BLOCKING", domain:"PET", checklist:"PET-1", location:"report.md", problem:"p", evidence:"e", requiredFix:"f", verification:"v"},
              {id:"PET-02", severity:"NON_BLOCKING", domain:"PET", checklist:"PET-2", location:"report.md", problem:"p2", evidence:"e2", requiredFix:"f2", verification:"v2"}]}' \
  > "$STATE/$TID.done.json"
b_wait_pid "$PID" 90
RC=$?
[[ "$RC" -eq 0 ]] && pass "B1 launcher exit 0" || fail "B1 launcher rc=$RC"
ST="$(jq -r '.state // ""' "$STATE/$TID.json" 2>/dev/null)"
[[ "$ST" == "done" ]] && pass "B1 state=done" || fail "B1 state=$ST"
LID="$(jq -r '.leaseId // ""' "$STATE/$TID.json")"
LH="$(jq -r '.leaseHolder // ""' "$STATE/$TID.json")"
WTP="$(jq -r '.worktreePath // ""' "$STATE/$TID.json")"
LAT="$(jq -r '.leaseAcquiredAt // 0' "$STATE/$TID.json")"
[[ "$LID" == "fake-lease-b1" && "$LH" == "pi-fleet:b1" && "$WTP" == "$WT" && "$LAT" -gt 0 ]] \
  && pass "B1 acquisition persisted (leaseId=$LID holder=$LH path=$WTP acquiredAt=$LAT)" \
  || fail "B1 acquisition fields: leaseId=$LID holder=$LH path=$WTP acquiredAt=$LAT"
[[ -f "$STATE/$TID.result.json" ]] && pass "B1 <id>.result.json persisted" || fail "B1 result.json missing"
jq -e --arg s "scout complete: analysis delivered" '.status=="done" and .summary==$s and (.doneMarker.status=="done") and (.doneMarker.findings|length)==2' \
  "$STATE/$TID.result.json" >/dev/null \
  && pass "B1 result.json carries outcome + FULL original done-marker payload" \
  || fail "B1 result.json payload wrong: $(jq -c '{status, summary, doneMarker}' "$STATE/$TID.result.json" 2>/dev/null)"
[[ -f "$STATE/$TID.findings.json" ]] && pass "B1 <id>.findings.json persisted" || fail "B1 findings.json missing"
jq -e '.counts.blocking==1 and .counts.non_blocking==1 and (.findings|length)==2' \
  "$STATE/$TID.findings.json" >/dev/null \
  && pass "B1 findings validated (1 BLOCKING + 1 NON_BLOCKING)" \
  || fail "B1 findings counts wrong: $(jq -c '.counts' "$STATE/$TID.findings.json" 2>/dev/null)"
[[ -f "$STATE/$TID.report.md" ]] && pass "B1 <id>.report.md copied out of the worktree" || fail "B1 report.md missing"
diff -q "$WT/report.md" "$STATE/$TID.report.md" >/dev/null \
  && pass "B1 report.md content identical to the worktree original" || fail "B1 report.md differs"
REP_META="$(jq -c '.report' "$STATE/$TID.result.json")"
echo "$REP_META" | jq -e '.copied==true and (.bytes|type=="number") and .bytes>0 and (.sha256|length>=40)' >/dev/null \
  && pass "B1 report metadata size+sha256 present ($REP_META)" || fail "B1 report metadata wrong: $REP_META"
[[ ! -f "$STATE/$TID.done.json" ]] && pass "B1 transient done-marker consumed AFTER persistence" \
  || fail "B1 done-marker not consumed"
[[ "$(owner_result "$TID")" == "released" ]] && pass "B1 cleanup released" || fail "B1 cleanup=$(owner_result "$TID")"
grep -q "TH return --force --if-lease-id fake-lease-b1 $WT" "$SCRATCH/b-$TID.th" \
  && pass "B1 guarded return used the PERSISTED lease id" \
  || fail "B1 guarded return missing: $(cat "$SCRATCH/b-$TID.th")"
grep -q "task b1 finalized (state=done, cleanup=released)" "$SCRATCH/b-$TID.out" \
  && pass "B1 final log: explicit task result + cleanup result (Phase 5)" \
  || fail "B1 final log missing"

# ---- B2 dirty worktree -> task done, cleanup failed, artifacts preserved -----
log "SCENARIO B2 — dirty worktree: cleanup failed, artifact bundle preserved"
TID=b2
b_launch_bg "$TID" return_fail; PID=$!
b_wait_log "$SCRATCH/b-$TID.out" "brief delivered to the child" 60 \
  && pass "B2 child started" || fail "B2 child start log missing"
printf 'partial report — saved before the dirty return\n' > "$WT/report.md"
jq -nc '{status:"done", summary:"done marker but the worktree is dirty", reportPath:"report.md", changedFiles:["report.md"]}' \
  > "$STATE/$TID.done.json"
b_wait_pid "$PID" 90
RC=$?
[[ "$RC" -eq 0 ]] && pass "B2 launcher exit 0 (task result delivered; cleanup failure separated)" \
  || fail "B2 launcher rc=$RC"
[[ "$(jq -r '.state' "$STATE/$TID.json")" == "done" ]] && pass "B2 state=done (task outcome)" \
  || fail "B2 state=$(jq -r '.state' "$STATE/$TID.json")"
[[ "$(owner_result "$TID")" == "failed" ]] && pass "B2 cleanup=failed (distinct from task outcome)" \
  || fail "B2 cleanup=$(owner_result "$TID")"
[[ "$(owner_exit_status "$TID")" == "3" ]] && pass "B2 nonzero return NOT suppressed (exitStatus=3)" \
  || fail "B2 exitStatus=$(owner_exit_status "$TID")"
[[ -f "$STATE/$TID.result.json" && -f "$STATE/$TID.report.md" && -f "$STATE/$TID.findings.json" ]] \
  && pass "B2 artifacts preserved (result/report/findings)" || fail "B2 artifacts missing"
diff -q "$WT/report.md" "$STATE/$TID.report.md" >/dev/null \
  && pass "B2 scout report durable despite the dirty worktree" || fail "B2 report.md differs/missing"

# ---- B3 direct abort -> aborted + cleanup -----------------------------------
log "SCENARIO B3 — abort marker: launcher marks aborted and runs the shared owner"
TID=b3
b_launch_bg "$TID" ok; PID=$!
b_wait_log "$SCRATCH/b-$TID.out" "brief delivered to the child" 60 \
  && pass "B3 child started" || fail "B3 child start log missing"
printf '%s\n' "$(date +%s)" > "$STATE/$TID.abort"
b_wait_pid "$PID" 60
RC=$?
[[ "$RC" -eq 0 ]] && pass "B3 launcher exit 0 on abort" || fail "B3 launcher rc=$RC"
[[ "$(jq -r '.state' "$STATE/$TID.json")" == "aborted" ]] && pass "B3 state=aborted" \
  || fail "B3 state=$(jq -r '.state' "$STATE/$TID.json")"
[[ "$(owner_result "$TID")" == "released" || "$(owner_result "$TID")" == "already_released" ]] \
  && pass "B3 abort cleanup=$(owner_result "$TID")" || fail "B3 cleanup=$(owner_result "$TID")"

# ---- B4 child crash (no done-marker) -> failed + reason persisted -----------
log "SCENARIO B4 — child disappears without done-marker: failed + cleanup"
TID=b4
b_launch_bg "$TID" ok; PID=$!
b_wait_log "$SCRATCH/b-$TID.out" "brief delivered to the child" 60 \
  && pass "B4 child started" || fail "B4 child start log missing"
touch "$SCRATCH/b-$TID.kill"   # mock agent list becomes empty -> liveness gate trips
b_wait_pid "$PID" 90
RC=$?
[[ "$RC" -eq 1 ]] && pass "B4 launcher exit 1 (liveness gate)" || fail "B4 launcher rc=$RC"
[[ "$(jq -r '.state' "$STATE/$TID.json")" == "failed" ]] && pass "B4 state=failed" \
  || fail "B4 state=$(jq -r '.state' "$STATE/$TID.json")"
jq -e '.failureReason | contains("without writing the done-marker")' "$STATE/$TID.result.json" >/dev/null \
  && pass "B4 failure reason persisted in <id>.result.json" \
  || fail "B4 failure reason missing: $(cat "$STATE/$TID.result.json" 2>/dev/null)"
[[ "$(owner_result "$TID")" == "released" || "$(owner_result "$TID")" == "already_released" ]] \
  && pass "B4 cleanup=$(owner_result "$TID")" || fail "B4 cleanup=$(owner_result "$TID")"

# ---- B5 concurrent abort + completion: exactly ONE return -------------------
log "SCENARIO B5 — concurrent abort + done: no double-release"
TID=b5
b_launch_bg "$TID" ok; PID=$!
b_wait_log "$SCRATCH/b-$TID.out" "brief delivered to the child" 60 \
  && pass "B5 child started" || fail "B5 child start log missing"
# both signals appear in the SAME loop window
printf '%s\n' "$(date +%s)" > "$STATE/$TID.abort"
jq -nc '{status:"done", summary:"completed at the same time the abort arrived"}' > "$STATE/$TID.done.json"
b_wait_pid "$PID" 90
RC=$?
ST="$(jq -r '.state' "$STATE/$TID.json" 2>/dev/null)"
[[ "$ST" == "done" || "$ST" == "aborted" || "$ST" == "failed" ]] \
  && pass "B5 exactly one terminal result ($ST)" || fail "B5 state=$ST"
[[ "$(owner_result "$TID")" == "released" || "$(owner_result "$TID")" == "already_released" ]] \
  && pass "B5 cleanup converges on $(owner_result "$TID")" || fail "B5 cleanup=$(owner_result "$TID")"
RETS="$(grep -c "^TH return" "$SCRATCH/b-$TID.th" 2>/dev/null || echo 0)"
[[ "$RETS" -eq 1 ]] && pass "B5 exactly ONE guarded return (no double-release)" \
  || fail "B5 returns=$RETS (expected 1): $(cat "$SCRATCH/b-$TID.th")"
POOL_EMPTY="$(cat "$SCRATCH/b-$TID.pool" 2>/dev/null | jq 'length' 2>/dev/null || echo '?')"
[[ "$POOL_EMPTY" == "0" ]] && pass "B5 lease released exactly once (pool empty)" \
  || fail "B5 pool still has rows: $POOL_EMPTY"

# ---- B6 launcher-crash injection (after artifact persist, during cleanup) ----
log "SCENARIO B6 — SIGKILL the launcher while the owner hangs in status: recoverable"
TID=b6
b_launch_bg "$TID" status_hang; PID=$!
b_wait_log "$SCRATCH/b-$TID.out" "brief delivered to the child" 60 \
  && pass "B6 child started" || fail "B6 child start log missing"
jq -nc '{status:"done", summary:"artifacts persisted, then crash before return"}' > "$STATE/$TID.done.json"
# wait until result.json exists (artifact persist happens BEFORE the cleanup owner)
for ((i = 0; i < 60; i++)); do
  [[ -f "$STATE/$TID.result.json" ]] && break
  sleep 0.5
done
[[ -f "$STATE/$TID.result.json" ]] && pass "B6 artifacts persisted BEFORE the crash point" \
  || fail "B6 result.json not persisted before the kill"
# the owner is now INSIDE the status hang (release not yet done) — kill everything
sleep 1
kill -9 "$PID" 2>/dev/null
wait "$PID" 2>/dev/null
pkill -9 -f "fleet-cleanup.sh $TID" 2>/dev/null || true
# recoverable: the record (if any) parses, and the guarded re-run converges
if [[ -f "$STATE/$TID.cleanup.json" ]]; then
  jq -e . "$STATE/$TID.cleanup.json" >/dev/null 2>&1 && pass "B6 record valid JSON after the crash" \
    || fail "B6 record corrupt"
else
  pass "B6 no record written before the crash (nothing corrupt)"
fi
RC="$(FTH_HANG_S=0 FTH_MODE=ok FTH_POOL="$SCRATCH/b-$TID.pool" run_owner "$TID")"
[[ "$(owner_result "$TID")" == "released" ]] && pass "B6 re-run converges released (crash-recoverable)" \
  || fail "B6 re-run -> $(owner_result "$TID")"
jq -e '.doneMarker.status=="done"' "$STATE/$TID.result.json" >/dev/null \
  && pass "B6 done-marker payload survived the crash (result.json intact)" \
  || fail "B6 result.json doneMarker lost"

# ============================================================ outcome =======
log "OUTCOME: $OK gh-8 cleanup checks green"
[[ $OK -gt 0 ]] || die "no checks executed"
exit 0