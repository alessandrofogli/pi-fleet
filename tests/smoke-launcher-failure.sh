#!/usr/bin/env bash
#
# pi-fleet · issue #15 regression — "launcher failure ⇒ task terminal (failed)
# within N seconds + lease released"
#
# Historical root cause (2026-09-06, discovered after the gh-8 merge): a launch
# failure AFTER `treehouse get` (e.g. 'invalid worktree: {...json...}', caused
# by the acquisition stream — treehouse 🌳 banners merged via 2>&1 with the JSON
# record — breaking the jq gate and making the legacy last-line fallback take
# the JSON record for the path) exited 1 BEFORE the task JSON was persisted as
# terminal and BEFORE the lease was released → 3 leases leaked, tasks stuck
# non-terminal ~11h.
#
# The code fix is HEAD 05b549f (bin/herdr-launch.sh): stdout (JSON record) and
# stderr (banners) captured SEPARATELY, a banner-proof parse that takes the
# LAST line that is a JSON record with a resolvable path, and a guarded EXIT
# trap armed IMMEDIATELY after acquisition that (a) marks the task failed with
# a doneAt and (b) runs the shared cleanup owner — so any failure between
# acquisition and the full state write can never leak the lease.
#
# This test regresses THAT guarantee deterministically, launcher-level:
#
#   S1  acquisition SUCCEEDS (existing worktree dir, banner→stderr, record→
#       stdout kept SEPARATE — never 2>&1 for parsing) but the launcher fails
#       right AFTER acquisition (fleet workspace unresolvable): the task must
#       be marked failed within N seconds AND the lease returned (guarded
#       `treehouse return`, pool empty, cleanup record released).
#   S2  the historical failure MODE ('invalid worktree' — acquisition returns
#       a path whose directory does NOT exist): the task must STILL become
#       terminal failed (never stuck in 'spawning', never a silent exit-1 with
#       nothing on disk) and the lease must NOT be silently lost: the cleanup
#       owner records durable `pending` (dir missing → release NOT claimed on
#       a ghost path, per design) so the lease stays identifiable/recoverable.
#
# Isolation: FLEET_STATE_HOME + HOME under /tmp; fake treehouse + fake herdr
# PATH-shadowed; a real pool/herdr/lease is NEVER touched. stdout/stderr of the
# fake treehouse stay SEPARATE — the launcher's parse path must never see the
# banner text.
#
# Prereqs: bash + jq + git only (no node, no herdr/treehouse daemon).
# Exit: 0 green / 1 failed (a failing check is FATAL — deterministic) /
#       2 missing prerequisites.
#
# Usage:
#   bash tests/smoke-launcher-failure.sh
#   SMOKE_KEEP=1 bash tests/smoke-launcher-failure.sh   # keep scratch for debug
#
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
LAUNCHER="$REPO_ROOT/bin/herdr-launch.sh"
OWNER="$REPO_ROOT/bin/fleet-cleanup.sh"
TS="$(date +%s)"
SCRATCH="/tmp/fleet-lf-smoke-$TS"
STATE="$SCRATCH/state"            # isolated FLEET_STATE_HOME
PROJ="$SCRATCH/proj"              # fake project
WT="$SCRATCH/wt"                  # EXISTING worktree dir (S1)
GHOST="$SCRATCH/ghost-wt"         # NON-existent worktree path (S2)
HOME_DIR="$SCRATCH/home"
MOCK_BIN="$SCRATCH/bin"
KEEP="${SMOKE_KEEP:-0}"

log() { printf 'LF [%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf 'LF FAIL: %s\n' "$*" >&2; exit 1; }
die2() { printf 'LF SKIP (exit 2): %s\n' "$*" >&2; exit 2; }

command -v jq  >/dev/null 2>&1 || die2 "jq not found in PATH (brew install jq)"
command -v git >/dev/null 2>&1 || die2 "git not found in PATH"
[[ -f "$LAUNCHER" ]] || die "launcher not found: $LAUNCHER"
[[ -f "$OWNER" ]] || die "cleanup owner not found: $OWNER"
bash -n "$0" || die "smoke-launcher-failure.sh does not pass bash -n (self-check)"
bash -n "$LAUNCHER" || die "bin/herdr-launch.sh does not pass bash -n"
bash -n "$OWNER" || die "bin/fleet-cleanup.sh does not pass bash -n"

cleanup() {
  [[ "$KEEP" == "1" ]] && { log "SMOKE_KEEP=1: keeping $SCRATCH"; return 0; }
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

mkdir -p "$STATE/tasks" "$PROJ" "$WT" "$HOME_DIR" "$MOCK_BIN"
# S2: GHOST must NOT exist (that is the failure being exercised)
[[ ! -e "$GHOST" ]] || die "scratch ghost path exists: $GHOST (S2 setup broken)"
log "scratch: $SCRATCH (state: $STATE, mock bin: $MOCK_BIN)"

OK=0; BAD=0
pass() { OK=$((OK + 1)); log "  OK   $*"; }
fail() { BAD=$((BAD + 1)); log "  FAIL $*"; }
# announce + verdict per scenario: a single failing check is FATAL (deterministic)
scenario_done() { # <name>
  if [[ $BAD -gt 0 ]]; then
    die "scenario $1: $BAD check(s) failed — regression NOT green"
  fi
  log "scenario $1: all checks green ($OK checks)"
  OK=0; BAD=0
}

# ----------------------------------------------------------------- fakes ----
# fake treehouse: env-driven pool + fault injection. NEVER touches a real pool.
# IMPORTANT (issue #15): the record goes to STDOUT and the 🌳 banners to
# STDERR — SEPARATE channels, exactly like the real binary. The launcher parses
# the STDOUT capture only; it must never see the banner lines on the parse path.
cat > "$MOCK_BIN/treehouse" <<'EOF'
#!/usr/bin/env bash
# issue #15 fake treehouse. Env:
#   FTH_LOG         record every invocation ("TH <args>")
#   FTH_POOL        pool state file (JSON array of rows); `get` seeds one row
#   FTH_WT          the fake worktree path (may be a NON-existent dir → S2)
#   FTH_LEASE_ID    lease id issued by `get`
set -u
echo "TH $*" >> "${FTH_LOG:?}"
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
    # 🌳 banners → STDERR (the real binary does this); the record → STDOUT.
    # NEVER merge the two: 2>&1 parsing is exactly the bug being regressed.
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

# fake herdr: FTH_MODE=no-workspace → `workspace list` empty + `workspace
# create` without an id (the S1 launcher failure: fleet workspace unresolvable).
# Recording only — a real herdr/pane/tab is NEVER touched.
cat > "$MOCK_BIN/herdr" <<'EOF'
#!/usr/bin/env bash
set -u
[[ "$1" == "--session" ]] && shift 2
cmd="$1"
shift
printf 'MOCK %s %s\n' "$cmd" "$*" >> "${FTH_MOCK_REC:?}"
case "$cmd" in
  workspace)
    case "${1:-}" in
      list)   echo '{"result":{"workspaces":[]}}' ;;
      create) echo '{"ok":true}' ;;   # no .result.workspace → id empty
    esac ;;
  tab|pane|agent) echo '{"ok":true}' ;;
esac
exit 0
EOF
chmod +x "$MOCK_BIN/treehouse" "$MOCK_BIN/herdr"
log "fakes in place: $MOCK_BIN (treehouse + herdr, stdout/stderr SEPARATE)"

# ------------------------------------------------------------- helpers ----
# bounded wait for the launcher pid: returns its exit code, or 124 if it did
# not finish within <secs> seconds (killed). 124 ⇒ not terminal within N s.
wait_pid() { # <pid> <secs>
  local pid="$1" secs="$2" rc
  for ((i = 0; i < secs * 2; i++)); do
    kill -0 "$pid" 2>/dev/null || { wait "$pid"; rc=$?; return $rc; }
    sleep 0.5
  done
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  return 124
}

# launch the REAL launcher with the fakes + isolated state; $! is the pid.
launch_bg() { # <tid> <mode>
  local tid="$1" mode="$2"
  env -i /usr/bin/env bash -c "
    set -a
    FLEET_STATE_HOME=$STATE
    FTH_MODE=$mode
    FTH_LOG=$SCRATCH/$tid.th
    FTH_POOL=$SCRATCH/$tid.pool
    FTH_WT=$3
    FTH_LEASE_ID=fake-lease-$tid
    FTH_MOCK_REC=$SCRATCH/$tid.herdr
    HOME=$HOME_DIR
    PATH=$MOCK_BIN:$PATH
    set +a
    exec \"\$@\"
  " bash "$LAUNCHER" "lf-$tid" "issue #15 launcher-failure scenario $tid" \
    --project "$PROJ" --task-id "$tid" --timeout-min 1 >"$SCRATCH/$tid.out" 2>&1 &
}

state_get() { jq -r "$1" "$STATE/$2.json" 2>/dev/null; }
cleanup_get() { jq -r "$1" "$STATE/$2.cleanup.json" 2>/dev/null; }
pool_len() { jq 'length' "$SCRATCH/$1.pool" 2>/dev/null || echo '?'; }
th_returns() { grep -c "^TH return" "$SCRATCH/$1.th" 2>/dev/null || true; }

# ============================================================ S1 ============
# The issue #15 guarantee: acquisition ok (existing dir) → launcher failure
# right after → task terminal (failed) within N seconds + lease returned.
log "SCENARIO S1 — acquisition ok, launcher fails after acquisition (workspace unresolvable): terminal failed + lease returned"
TID=s1
START="$(date +%s)"
launch_bg "$TID" ok "$WT"
LFPID=$!
wait_pid "$LFPID" 45
RC=$?
ELAPSED=$(( $(date +%s) - START ))
[[ "$RC" -eq 1 ]] && pass "S1 launcher exited 1 (failure) in ${ELAPSED}s (< 45s bound, well below the 60s task timeout)" \
  || fail "S1 launcher rc=$RC (expected 1) after ${ELAPSED}s — must be terminal failed within N seconds, not the done-wait timeout"
[[ "$RC" -ne 124 ]] || fail "S1 launcher not terminal within 45s (rc=124 → killed)"

ST="$(state_get '.state' "$TID")"
[[ "$ST" == "failed" ]] && pass "S1 state=failed" || fail "S1 state='$ST'"
jq -e '.doneAt | type=="number" and .>0' "$STATE/$TID.json" >/dev/null 2>&1 \
  && pass "S1 doneAt persisted (terminal timestamp)" || fail "S1 doneAt missing/not numeric"
state_get '.summary' "$TID" | grep -q "fleet workspace not resolvable" \
  && pass "S1 summary names the launcher failure (fleet workspace not resolvable)" \
  || fail "S1 summary=$(state_get '.summary' "$TID")"
[[ "$(state_get '.worktreePath' "$TID")" == "$WT" ]] \
  && pass "S1 worktreePath == the REAL path from the JSON record (parse took the record, not banners)" \
  || fail "S1 worktreePath=$(state_get '.worktreePath' "$TID") (expected $WT)"
[[ "$(state_get '.leaseId' "$TID")" == "fake-lease-s1" ]] \
  && pass "S1 leaseId persisted with the task record" || fail "S1 leaseId missing"

CRL="$(cleanup_get '.lastResult' "$TID")"
{ [[ "$CRL" == "released" || "$CRL" == "already_released" ]]; } \
  && pass "S1 cleanup converged on $CRL" || fail "S1 cleanup lastResult=$CRL"
[[ "$(cleanup_get '.attempts[0].result' "$TID")" == "released" ]] \
  && pass "S1 first cleanup attempt released (record: released)" \
  || fail "S1 attempts[0].result=$(cleanup_get '.attempts[0].result' "$TID")"
[[ "$(cleanup_get '.attempts[0].guard' "$TID")" == "lease-id" ]] \
  && pass "S1 guarded return used the exact persisted lease id" \
  || fail "S1 attempts[0].guard=$(cleanup_get '.attempts[0].guard' "$TID")"
[[ "$(cleanup_get '.attempts[0].guardValue' "$TID")" == "fake-lease-s1" ]] \
  && pass "S1 guardValue=fake-lease-s1" || fail "S1 guardValue=$(cleanup_get '.attempts[0].guardValue' "$TID")"

[[ "$(pool_len "$TID")" == "0" ]] && pass "S1 lease returned — pool empty (no leaked lease)" \
  || fail "S1 pool still holds $(pool_len "$TID") row(s) — LEASE LEAK"
[[ "$(th_returns "$TID")" -eq 1 ]] && pass "S1 exactly ONE treehouse return invoked" \
  || fail "S1 TH return count=$(th_returns "$TID") (expected 1)"
grep -q "TH return --force --if-lease-id fake-lease-s1 $WT" "$SCRATCH/$TID.th" \
  && pass "S1 return command is the EXACT guarded form (--if-lease-id)" \
  || fail "S1 guarded return line missing: $(cat "$SCRATCH/$TID.th")"

grep -q "TH get --lease --no-fetch --lease-holder pi-fleet:s1 --json" "$SCRATCH/$TID.th" \
  && pass "S1 acquisition used the --json primary branch (stdout=record)" \
  || fail "S1 get line missing: $(cat "$SCRATCH/$TID.th")"
grep -q "unable to create/resolve the fleet workspace" "$SCRATCH/$TID.out" \
  && pass "S1 launcher error names the failure point" || fail "S1 launcher error missing"
scenario_done "S1"

# ============================================================ S2 ============
# The historical failure mode: acquisition returns a record whose DIRECTORY
# does not exist ('invalid worktree'). The task must still become terminal
# failed within N seconds (the pre-fix leak left it 'spawning' + nothing on
# disk) and the lease must NOT be silently lost — the cleanup owner records a
# durable pending (ghost dir → release not claimed by design, recoverable).
log "SCENARIO S2 — invalid worktree (ghost dir): task still terminal failed within N seconds, lease durably recorded"
TID=s2
START="$(date +%s)"
launch_bg "$TID" ok "$GHOST"
LFPID=$!
wait_pid "$LFPID" 45
RC=$?
ELAPSED=$(( $(date +%s) - START ))
[[ "$RC" -eq 1 ]] && pass "S2 launcher exited 1 in ${ELAPSED}s (< 45s bound)" \
  || fail "S2 launcher rc=$RC (expected 1) after ${ELAPSED}s"

ST="$(state_get '.state' "$TID")"
[[ "$ST" == "failed" ]] && pass "S2 state=failed (terminal — never stuck in spawning, never a silent exit-1 with nothing on disk)" \
  || fail "S2 state='$ST'"
jq -e '.doneAt | type=="number" and .>0' "$STATE/$TID.json" >/dev/null 2>&1 \
  && pass "S2 doneAt persisted (terminal timestamp)" || fail "S2 doneAt missing/not numeric"
[[ "$(state_get '.leaseId' "$TID")" == "fake-lease-s2" ]] \
  && pass "S2 leaseId persisted BEFORE the validation that failed (persist-before-validate guarantee)" \
  || fail "S2 leaseId missing — the pre-fix code never wrote the record"

grep -q "invalid worktree: $GHOST" "$SCRATCH/$TID.out" \
  && pass "S2 failure is 'invalid worktree: <REAL path>' — the banner-proof parse resolved the path from the JSON record (root cause: the JSON blob was taken as the path)" \
  || fail "S2 invalid-worktree line missing: $(grep -o 'invalid worktree[^)]*' "$SCRATCH/$TID.out" | head -1)"
grep -q "Setting up worktree..." "$SCRATCH/$TID.out" \
  && pass "S2 acquisition banners travelled on stderr, preserved in the launcher error (STDOUT/STDERR kept SEPARATE)" \
  || fail "S2 banner text not visible in the launcher error (merged parse regression?)"

CRL="$(cleanup_get '.lastResult' "$TID")"
[[ "$CRL" == "pending" ]] && pass "S2 cleanup record durable pending (ghost dir — release NOT claimed, lease identifiable + recoverable)" \
  || fail "S2 cleanup lastResult=$CRL (expected pending)"
cleanup_get '.attempts[0].reason' "$TID" | grep -q "worktree dir is missing" \
  && pass "S2 pending reason names the ghost dir (operator review)" \
  || fail "S2 reason=$(cleanup_get '.attempts[0].reason' "$TID")"
[[ "$(th_returns "$TID")" -eq 0 ]] && pass "S2 ZERO unguarded returns (never a false release on a ghost path)" \
  || fail "S2 TH return count=$(th_returns "$TID") (expected 0)"
grep -q "TH get --lease --no-fetch --lease-holder pi-fleet:s2 --json" "$SCRATCH/$TID.th" \
  && pass "S2 acquisition used the --json primary branch (stdout=record)" \
  || fail "S2 get line missing: $(cat "$SCRATCH/$TID.th")"
scenario_done "S2"

# ============================================================ outcome =======
log "OUTCOME: issue #15 regression GREEN — launcher failure ⇒ task failed within N seconds + lease returned (S1) / durably recorded (S2)"
exit 0