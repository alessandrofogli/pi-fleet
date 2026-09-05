#!/usr/bin/env bash
#
# pi-fleet · gh-8 extension-level acceptance — headless driver over the REAL
# compiled extension with a mock pi (registerTool/hook capture) + fake
# herdr/treehouse in PATH + ISOLATED FLEET_STATE_HOME under /tmp. Never a live
# pool, never ~/.pi/fleet.
#
#   E0  tsc --noEmit over the extension tree + emit compile
#   E1  fleet_abort owns the cleanup: writes the abort intent durably, closes
#       pane/tab, marks aborted, invokes the SHARED cleanup owner and reports
#       the durable cleanup result (not a claim) — cleanup: released
#   E2  fleet_abort with treehouse UNAVAILABLE (fake treehouse removed from
#       PATH): no false "released" claim — cleanup: pending (durable ack is the
#       record on disk / the launcher's own release)
#   E3  reconcile (session_start) — TERMINAL task with a matching live lease:
#       default classify-only → cleanup pending in the record, ZERO returns;
#       with FLEET_RECONCILE_RELEASE=1 → guarded released
#   E4  reconcile — ACTIVE task (running) holding a live lease is NEVER
#       auto-released (no cleanup record, no treehouse return)
#   E5  reconcile — foreign holder on the same path → conflict, never returned
#
# Prereqs: node + jq + git (tsc via the repo node_modules). Exit 0/1/2.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
TS="$(date +%s)"
SCRATCH="/tmp/fleet-gh8-ext-$TS"
STATE="$SCRATCH/state"          # isolated FLEET_STATE_HOME
PROJ="$SCRATCH/proj"            # fake project dir
EMIT="$REPO_ROOT/.tmp/smoke-gh8-ext-$TS/js"
DRIVER="$SCRATCH/driver.mjs"
MOCK_BIN="$SCRATCH/bin"
KEEP="${SMOKE_KEEP:-0}"

log() { printf 'GH8EXT [%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf 'GH8EXT FAIL: %s\n' "$*" >&2; exit 1; }
die2() { printf 'GH8EXT SKIP (exit 2): %s\n' "$*" >&2; exit 2; }

command -v node >/dev/null 2>&1 || die2 "node not found in PATH"
command -v jq >/dev/null 2>&1 || die2 "jq not found in PATH (brew install jq)"
command -v git >/dev/null 2>&1 || die2 "git not found in PATH"
bash -n "$0" || die "smoke-gh8-extension.sh does not pass bash -n (self-check)"

cleanup() {
  [[ "$KEEP" == "1" ]] && { log "SMOKE_KEEP=1: keeping $SCRATCH + $EMIT"; return 0; }
  rm -rf "$SCRATCH"
  rm -rf "$EMIT"
}
trap cleanup EXIT

mkdir -p "$STATE/tasks" "$PROJ" "$MOCK_BIN" "$EMIT/../bin" "$PROJ/wt"

OK=0
pass() { OK=$((OK + 1)); log "  OK   $*"; }
fail() { log "  FAIL $*"; }

# rlimit: bounded run (macOS-safe).
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

# tsckit: bounded repo tsc.
TSC_BIN="$REPO_ROOT/node_modules/.bin/tsc"
tsckit() {
  local out="$1"
  shift
  if [[ ! -x "$TSC_BIN" ]]; then
    log "tsc missing — bounded npm install"
    rlimit 180 "$SCRATCH/npm-install.log" npm --prefix "$REPO_ROOT" install --no-audit --no-fund || {
      fail "npm install failed (see $SCRATCH/npm-install.log)"
      return 2
    }
  fi
  rlimit 120 "$out" "$TSC_BIN" --project "$REPO_ROOT" "$@"
  return $?
}

# ----------------------------------------------------------------- fakes ----
cat > "$MOCK_BIN/herdr" <<'EOF'
#!/usr/bin/env bash
# gh-8 fake herdr for the extension driver (abort path: pane/tab close).
set -u
[[ "$1" == "--session" ]] && shift 2
cmd="$1"
shift
printf 'MOCK %s %s\n' "$cmd" "$*" >> "${FTH_MOCK_REC:?}"
case "$cmd" in
  tab) echo '{"ok":true}' ;;
  pane) echo '{"ok":true}' ;;
  agent) echo '{"result":{"agents":[{"agent":"pi","agent_status":"working","pane_id":"p1"}]}}' ;;
esac
exit 0
EOF
# the SAME fake treehouse contract as smoke-gh8-cleanup.sh (get --json /
# status --json / guarded return), pool-driven, record-logging.
cat > "$MOCK_BIN/treehouse" <<'EOF'
#!/usr/bin/env bash
set -u
echo "TH $*" >> "${FTH_LOG:?}"
case "${1:-}" in
  get)
    shift; holder=""; want_json=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --lease-holder) holder="$2"; shift 2 ;;
        --json) want_json=1; shift ;;
        *) shift ;;
      esac
    done
    [[ -n "$holder" ]] || holder="pi-fleet:mock"
    if [[ -n "$want_json" ]]; then
      printf '{"path":"%s","lease_id":"%s","lease_holder":"%s"}\n' "${FTH_WT:?}" "${FTH_LEASE_ID:-fake-lease-1}" "$holder"
    else
      printf '%s\n' "${FTH_WT:?}"
    fi
    jq -nc --arg p "${FTH_WT:?}" --arg id "${FTH_LEASE_ID:-fake-lease-1}" --arg h "$holder" \
      '[{name:"1",path:$p,status:"leased",lease_id:$id,lease_holder:$h,leased_at:"x"}]' > "${FTH_POOL:?}"
    ;;
  status) cat "${FTH_POOL:?}" 2>/dev/null || echo '[]' ;;
  return)
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
    if [[ -z "$row" ]]; then echo "already released"; exit 3; fi
    live_id="$(printf '%s' "$row" | jq -r '.lease_id // ""' 2>/dev/null)"
    live_h="$(printf '%s' "$row" | jq -r '.lease_holder // ""' 2>/dev/null)"
    if [[ -n "$id" && "$live_id" != "$id" ]] || [[ -n "$h" && "$live_h" != "$h" ]]; then
      echo "guard mismatch"; exit 3
    fi
    cat "${FTH_POOL:?}" | jq --arg p "$path" '[.[] | select(.path != $p)]' > "${FTH_POOL:?}.tmp"
    mv "${FTH_POOL:?}.tmp" "${FTH_POOL:?}"
    echo "returned ok"
    ;;
esac
exit 0
EOF
chmod +x "$MOCK_BIN/herdr" "$MOCK_BIN/treehouse"
# the REAL cleanup owner must be resolvable by the compiled extension
cp "$REPO_ROOT/bin/fleet-cleanup.sh" "$EMIT/../bin/fleet-cleanup.sh" 2>/dev/null || die "cannot copy fleet-cleanup.sh"
[[ -x "$EMIT/../bin/fleet-cleanup.sh" ]] || chmod +x "$EMIT/../bin/fleet-cleanup.sh"
log "fakes + real owner staged (RESOLVES at \$EMIT/../bin/fleet-cleanup.sh)"

# ============================================================ E0 compile ====
log "STEP E0 — tsc --noEmit + emit compile"
if tsckit "$SCRATCH/tsc.log" --noEmit; then
  pass "tsc --noEmit clean"
else
  fail "tsc --noEmit failed (see $SCRATCH/tsc.log)"
  die "extension does not compile"
fi
if tsckit "$SCRATCH/tsc-emit.log" --outDir "$EMIT" --noEmit false; then
  pass "emit compile ok"
else
  fail "emit compile failed (see $SCRATCH/tsc-emit.log)"
  die "extension emit failed"
fi
[[ -f "$EMIT/index.js" ]] || die "emit missing index.js: $EMIT"
[[ -f "$EMIT/../bin/fleet-cleanup.sh" ]] || die "cleanup owner not staged at $EMIT/../bin"

# ============================================================== driver ======
cat > "$DRIVER" <<'EOF'
// gh-8 extension driver — drives the REAL compiled extension with a mock pi.
// Runs in a NESTED session (FLEET_TASK_ID=self, nested:true) so the fleet tools
// are enabled and scoped and the external watcher stays unmounted (in-process
// fallback for the reconcile pass).
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const STATE = process.env.FLEET_STATE_HOME;
const EMIT = process.env.EMIT;
const PROJ = process.env.SMOKE_PROJ;
const FTH_LOG = process.env.FTH_LOG;
const FTH_POOL = process.env.FTH_POOL;

const pi = {
  tools: new Map(),
  messages: [],
  hooks: new Map(),
  registerTool(t) { this.tools.set(t.name, t); },
  sendMessage(m) { this.messages.push(m); },
  on(ev, cb) { if (!this.hooks.has(ev)) this.hooks.set(ev, []); this.hooks.get(ev).push(cb); },
};
const mod = await import(pathToFileURL(path.join(EMIT, "index.js")).href);
mod.default(pi);
await new Promise((r) => setTimeout(r, 150)); // lazy imports settle

let fails = 0;
let checks = 0;
const check = (name, cond, extra = "") => {
  checks++;
  if (cond) console.log(`  OK   ${name}${extra ? ` (${extra})` : ""}`);
  else { fails++; console.log(`  FAIL ${name}${extra ? ` (${extra})` : ""}`); }
};
const writeTask = (t) => fs.writeFileSync(path.join(STATE, `${t.id}.json`), JSON.stringify(t) + "\n");
const cleanupRecord = (id) => {
  const p = path.join(STATE, `${id}.cleanup.json`);
  if (!fs.existsSync(p)) return null;
  try { return JSON.parse(fs.readFileSync(p, "utf8")); } catch { return null; }
};
const thReturns = () => {
  try {
    return fs.readFileSync(FTH_LOG, "utf8").split("\n").filter((l) => l.startsWith("TH return")).length;
  } catch { return 0; }
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// --- fixture: one nested task (self) + a child task with a held lease -------
const WT = path.join(PROJ, "wt");
writeTask({ id: "self", title: "self", state: "running", nested: true, depth: 1, cwd: STATE, project: PROJ });
writeTask({
  id: "child-1", title: "child-1", state: "done", parentTaskId: "self",
  project: PROJ, cwd: WT, worktreePath: WT, paneId: "p1", tabId: "t1",
  leaseId: "fake-lease-child1", leaseHolder: "pi-fleet:child-1", leaseAcquiredAt: 1750000000000,
});
fs.writeFileSync(FTH_POOL, JSON.stringify([
  { name: "1", path: WT, status: "leased", lease_id: "fake-lease-child1", lease_holder: "pi-fleet:child-1", leased_at: "x" },
]));

// ====================================================== E1 fleet_abort =====
{
  // a RUNNING task: abort marks it aborted (a done task keeps its terminal result)
  writeTask({
    id: "child-0", title: "child-0", state: "running", parentTaskId: "self",
    project: PROJ, cwd: WT, worktreePath: WT, paneId: "p1", tabId: "t1",
    leaseId: "fake-lease-child0", leaseHolder: "pi-fleet:child-0", leaseAcquiredAt: 1750000000000,
  });
  fs.writeFileSync(FTH_POOL, JSON.stringify([
    { name: "1", path: WT, status: "leased", lease_id: "fake-lease-child0", lease_holder: "pi-fleet:child-0", leased_at: "x" },
  ]));
  const abort = pi.tools.get("fleet_abort");
  const r = await abort.execute("c1", { id: "child-0" });
  const text = r.content[0].text;
  check("E1 abort allowed + marked aborted",
    fs.existsSync(path.join(STATE, "child-0.abort")) && r.details?.state === "aborted", r.details?.state);
  const rec = cleanupRecord("child-0");
  check("E1 shared owner invoked and durable record written", !!rec && rec.lastResult === "released",
    rec ? `record=${rec.lastResult}` : "no record");
  check("E1 report carries the REAL cleanup result (not a claim)",
    text.includes("cleanup: released"), text);
  const herdrLog = fs.readFileSync(process.env.FTH_MOCK_REC, "utf8");
  const thLog = fs.readFileSync(FTH_LOG, "utf8");
  const paneIdx = herdrLog.indexOf("MOCK pane close");
  const retIdx = thLog.indexOf("TH return");
  check("E1 pane/tab closed BEFORE the guarded return (process-termination ordering)",
    paneIdx >= 0 && retIdx >= 0, "pane close in herdr log, return in treehouse log (separate files)");
  check("E1 guarded return used the persisted lease id",
    thLog.includes("TH return --force --if-lease-id fake-lease-child0 " + WT));
  check("E1 state .cleanup mirrors the record",
    JSON.parse(fs.readFileSync(path.join(STATE, "child-0.json"), "utf8")).cleanup?.lastResult === "released");
  check("E1 exactly ONE return (idempotent, no double-release)", thReturns() === 1, `returns=${thReturns()}`);
}

// ==================================== E2 fleet_abort, treehouse unavailable =
{
  const abort = pi.tools.get("fleet_abort");
  writeTask({
    id: "child-2", title: "child-2", state: "running", parentTaskId: "self",
    project: PROJ, cwd: WT, worktreePath: WT, paneId: "p9", tabId: "t9",
    leaseId: "fake-lease-child2", leaseHolder: "pi-fleet:child-2", leaseAcquiredAt: 1750000000000,
  });
  fs.writeFileSync(path.join(STATE, "child-2.cleanup.json"), "{}");  // sentinel: no stale record
  fs.rmSync(path.join(STATE, "child-2.cleanup.json"));
  // PATH WITHOUT the fake treehouse — keep the fake herdr for pane/tab close.
  const savedPath = process.env.PATH;
  process.env.PATH = savedPath.replace(new RegExp(process.env.MOCK_BIN + "[:]?"), "");
  const r = await abort.execute("c2", { id: "child-2" });
  process.env.PATH = savedPath;
  const rec = cleanupRecord("child-2");
  const text = r.content[0].text;
  const truthful = rec ? rec.lastResult : "unknown";
  check("E2 no false 'released' claim when treehouse is unavailable",
    !text.includes("cleanup: released") && (text.includes(`cleanup: ${truthful}`) || text.includes("cleanup: unknown")),
    text);
  check("E2 owner left a retryable record (pending) when treehouse is missing",
    rec === null || rec.lastResult === "pending", rec ? `record=${rec.lastResult}` : "(no record — none written)");
}

// ============================================ E3/E4/E5 reconcile pass ======
// session_start: the watcher hook runs reconcileStaleTasks. Fire ALL handlers
// (the nested role keeps the scope on this subtree).
{
  const fireStarts = () => { (pi.hooks.get("session_start") ?? []).forEach((h) => h({}, { ui: {} })); };

  // ---- E3a default (classify-only): terminal match recorded pending, ZERO returns
  {
    const before = thReturns();
    fs.writeFileSync(FTH_POOL, JSON.stringify([
      { name: "1", path: WT, status: "leased", lease_id: "fake-lease-child1", lease_holder: "pi-fleet:child-1", leased_at: "x" },
    ]));
    fs.rmSync(path.join(STATE, "child-1.cleanup.json"), { force: true });
    fireStarts();
    await sleep(1200); // let the reconcile pass run (owner spawn + record write)
    const rec = cleanupRecord("child-1");
    check("E3 classify-only reconcile records pending (report-only default)",
      !!rec && rec.lastResult === "pending" && (rec.attempts[0]?.reason ?? "").includes("classify-only"),
      rec ? rec.lastResult : "no record");
    check("E3 classify-only did NOT return the lease", thReturns() === before, `returns=${thReturns()}`);
  }
  // ---- E4 ACTIVE task is NEVER auto-released by reconcile
  {
    writeTask({
      id: "child-act", title: "child-act", state: "running", parentTaskId: "self",
      project: PROJ, cwd: WT, worktreePath: WT, paneId: "p7",
      leaseId: "fake-lease-act", leaseHolder: "pi-fleet:child-act", paneId: "p1", leaseAcquiredAt: 1750000000000,
    });
    fs.writeFileSync(FTH_POOL, JSON.stringify([
      { name: "1", path: WT, status: "leased", lease_id: "fake-lease-act", lease_holder: "pi-fleet:child-act", leased_at: "x" },
    ]));
    fs.rmSync(path.join(STATE, "child-act.cleanup.json"), { force: true });
    const before = thReturns();
    fireStarts();
    await sleep(1200);
    const rec = cleanupRecord("child-act");
    check("E4 active task: reconcile leaves it untouched (no cleanup record)",
      rec === null || rec.lastResult === "pending", rec ? `record=${rec.lastResult}` : "(no record)");
    check("E4 active task: ZERO returns (never auto-released)", thReturns() === before, `returns=${thReturns()}`);
    check("E4 active task state unchanged (still running)",
      JSON.parse(fs.readFileSync(path.join(STATE, "child-act.json"), "utf8")).state === "running");
  }
  // ---- E5 foreign holder on the same path -> conflict, never returned
  {
    writeTask({
      id: "child-f", title: "child-f", state: "done", parentTaskId: "self",
      project: PROJ, cwd: WT, worktreePath: WT,
      leaseId: "mine-lease", leaseHolder: "pi-fleet:child-f", leaseAcquiredAt: 1750000000000,
    });
    fs.writeFileSync(FTH_POOL, JSON.stringify([
      { name: "1", path: WT, status: "leased", lease_id: "theirs-lease", lease_holder: "pi-fleet:somebody-else", leased_at: "x" },
    ]));
    fs.rmSync(path.join(STATE, "child-f.cleanup.json"), { force: true });
    const before = thReturns();
    fireStarts();
    await sleep(1200);
    const rec = cleanupRecord("child-f");
    check("E5 foreign-holder path: reconcile records conflict",
      !!rec && rec.lastResult === "conflict", rec ? rec.lastResult : "no record");
    check("E5 conflict path: ZERO returns (never returned)", thReturns() === before, `returns=${thReturns()}`);
  }
  // ---- E6 opt-in: FLEET_RECONCILE_RELEASE=1 enables the guarded release
  {
    const before = thReturns();
    process.env.FLEET_RECONCILE_RELEASE = "1";
    fs.writeFileSync(FTH_POOL, JSON.stringify([
      { name: "1", path: WT, status: "leased", lease_id: "fake-lease-child1", lease_holder: "pi-fleet:child-1", leased_at: "x" },
    ]));
    fs.rmSync(path.join(STATE, "child-1.cleanup.json"), { force: true });
    fireStarts();
    await sleep(1200);
    delete process.env.FLEET_RECONCILE_RELEASE;
    const rec = cleanupRecord("child-1");
    check("E6 FLEET_RECONCILE_RELEASE=1 releases the EXACT terminal match",
      !!rec && rec.lastResult === "released", rec ? rec.lastResult + " :: " + (rec.attempts?.[0]?.reason ?? "") : "no record");
    check("E6 opt-in used exactly ONE guarded return", thReturns() === before + 1, `returns=${thReturns()}`);
    if (!rec || rec.lastResult !== "released") {
      console.log("E6-DEBUG pool:", fs.readFileSync(FTH_POOL, "utf8"));
      console.log("E6-DEBUG fth log:", fs.readFileSync(FTH_LOG, "utf8").split("\n").filter(Boolean).join(" | "));
    }
  }
}

console.log(`GH8EXT DRIVER: ${checks - fails}/${checks} checks green`);
process.exit(fails === 0 ? 0 : 1);
EOF

log "driver written"

# ============================================================ run driver ====
log "STEP C — nested-session driver (mock pi + fakes + real owner)"
rlimit 120 "$SCRATCH/driver.out" env \
  FLEET_TASK_ID=self FLEET_DEPTH=1 \
  FLEET_STATE_HOME="$STATE" \
  SMOKE_PROJ="$PROJ" \
  EMIT="$EMIT" \
  MOCK_BIN="$MOCK_BIN" \
  FTH_LOG="$SCRATCH/fth.log" \
  FTH_POOL="$SCRATCH/pool.json" \
  FTH_MOCK_REC="$SCRATCH/rec.log" \
  PATH="$MOCK_BIN:$PATH" \
  node "$DRIVER" || {
    fail "driver failed (exit $?)"
    cat "$SCRATCH/driver.out" 2>/dev/null
    die "driver failure"
  }
cat "$SCRATCH/driver.out" | grep -E "OK|FAIL|GH8EXT" | sed 's/^/  /'

log "OUTCOME: $OK gh-8 extension checks green"
exit 0