#!/usr/bin/env bash
#
# pi-fleet · T-022 fleet_dispatch tool acceptance smoke — fully headless
#
# Verifies the fleet_dispatch CONTRACT at the STATE level with an ISOLATED
# FLEET_STATE_HOME under /tmp (the real ~/.pi/fleet is NEVER touched):
#
#   A  tsc: the whole extension tree compiles clean (npx tsc --noEmit).
#   B  channel: the dispatch injection pair (<id>.json + <id>.needs-input.json)
#      is detected by the real watcher (bin/fleet-watch.sh) as
#      `signal: <id>.needs-input` → this is the wake that makes the captain
#      call fleet_dispatch (same pair dispatch-cmd.sh writes).
#   C  tool execution: the REAL compiled extension is driven with a mock pi
#      (registerTool capture) + a spawn recorder (child_process.spawn patched,
#      NO real herdr/launcher ever runs), FLEET_STATE_HOME = scratch state:
#        S1 fleet_status allowed → done.json {"status":"done", summary=status text}
#        S2 fleet_outcomes allowed → done.json done, summary=registry list
#        S3 unknown command → done.json {"status":"failed","summary":"refused: command not allowed"}
#        S4 fleet_launch without args → refused (same marker)
#        S5 fleet_status with extra args → refused (allowlist strict)
#        S6 invalid taskId (path traversal) → rejected, NOTHING written
#        S7 fleet_launch <project> <brief> → brief file + task record written,
#           launcher spawned with the fleet_launch arg contract (worktree default
#           ON — no --no-worktree), done.json "launched task <id> ..."
#        S8 fleet_launch with an unresolvable project → done.json failed with the
#           reason, NO launcher spawn (project is required, same as fleet_launch)
#   D  single-writer: the marker pair (<id>.json + needs-input) is byte-identical
#      before/after every allowed execution (only <id>.done.json is written).
#
# Optionally drive the driver scenarios with SMOKE_DRIVER_ONLY=1 (skips A/B).
# KEEP the scratch with SMOKE_KEEP=1.
# Exit: 0 green / 1 failed / 2 missing prerequisites.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
WATCHER="$REPO_ROOT/bin/fleet-watch.sh"
TS="$(date +%s)"
SCRATCH="/tmp/fleet-dispatch-smoke-$TS"
STATE_A="$SCRATCH/state-watch"       # watcher channel check
STATE_B="$SCRATCH/state-tool"        # tool execution tests
PROJ="$SCRATCH/project"              # an existing dir used as the launch target
EMIT="$REPO_ROOT/.tmp/smoke-dispatch-$TS/js"
DRIVER="$SCRATCH/driver.mjs"
KEEP="${SMOKE_KEEP:-0}"

log() { printf 'DISPATCH [%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf 'DISPATCH FAIL: %s\n' "$*" >&2; exit 1; }
die2() { printf 'DISPATCH SKIP (exit 2): %s\n' "$*" >&2; exit 2; }

command -v node >/dev/null 2>&1 || die2 "node not found in PATH"
command -v jq  >/dev/null 2>&1 || die2 "jq not found in PATH (brew install jq)"
command -v git >/dev/null 2>&1 || die2 "git not found in PATH"
[[ -x "$WATCHER" ]] || die "watcher not found: $WATCHER"
bash -n "$0" || die "smoke-dispatch.sh does not pass bash -n (self-check)"

cleanup() {
  [[ "$KEEP" == "1" ]] && { log "SMOKE_KEEP=1: keeping $SCRATCH"; return 0; }
  rm -rf "$SCRATCH"
  rm -rf "$EMIT"
}
trap cleanup EXIT

mkdir -p "$STATE_A" "$STATE_B/tasks" "$PROJ"

OK=0
pass() { OK=$((OK + 1)); log "  OK   $*"; }
fail() { log "  FAIL $*"; }

# ----------------------------------------------------------------- helpers --
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

# tsckit: run repo tsc (npm install fallback if deps missing), bounded.
TSC_BIN="$REPO_ROOT/node_modules/.bin/tsc"
tsckit() { # out-file args...
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

# ============================================================ A tsc ========
if [[ "${SMOKE_DRIVER_ONLY:-0}" != "1" ]]; then
  log "STEP A — tsc --noEmit over the extension tree"
  if tsckit "$SCRATCH/tsc.log" --noEmit; then
    pass "tsc --noEmit clean"
  else
    fail "tsc --noEmit failed (see $SCRATCH/tsc.log)"
  fi

  # ======================================================== B channel =======
  log "STEP B — watcher detects the dispatch pair (signal: <id>.needs-input)"
  # exactly what dispatch-cmd.sh writes to inject a remote command
  jq -nc '{id:"cmd-w1",title:"cmd-w1",state:"running",kind:"dispatch"}' > "$STATE_A/cmd-w1.json"
  jq -nc '{question:"fleet_status",taskState:"needs_input"}' > "$STATE_A/cmd-w1.needs-input.json"
  # bounded run of the REAL watcher with FLEET_POLL=1 (isolated state)
  ( cd "$REPO_ROOT" && env FLEET_STATE_HOME="$STATE_A" FLEET_POLL=1 bash "$WATCHER" >"$SCRATCH/watch.out" 2>/dev/null ) &
  wpid=$!
  for ((i = 0; i < 50; i++)); do
    grep -q '^signal: cmd-w1.needs-input$' "$SCRATCH/watch.out" 2>/dev/null && break
    sleep 0.2
  done
  kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null
  if grep -q '^signal: cmd-w1.needs-input$' "$SCRATCH/watch.out" 2>/dev/null; then
    pass "watcher wakes the captain for the dispatch pair (signal: cmd-w1.needs-input)"
  else
    fail "watcher did not emit 'signal: cmd-w1.needs-input' (output: $(cat "$SCRATCH/watch.out" 2>/dev/null | head -3))"
  fi
fi

# ============================================== C compile + driver ==========
log "STEP C — compile the extension + drive fleet_dispatch with a mock pi"
mkdir -p "$(dirname "$EMIT")"
if ! tsckit "$SCRATCH/tsc-emit.log" --outDir "$EMIT" --noEmit false; then
  die "extension emit compile failed (see $SCRATCH/tsc-emit.log)"
fi
[[ -f "$EMIT/index.js" ]] || die "emit missing index.js: $EMIT"

cat > "$DRIVER" <<'EOF'
// T-022 driver — drives the REAL compiled extension with a mock pi.
// spawn is patched BEFORE the import: no launcher/herdr is ever executed.
import { createRequire } from "node:module";
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const require = createRequire(import.meta.url);
const cp = require("node:child_process");
const STATE = process.env.FLEET_STATE_HOME;
const PROJECT = process.env.SCRATCH_PROJECT;
const EMIT = process.env.EMIT;

const spawnCalls = [];
cp.spawn = (...args) => { spawnCalls.push(args); return { unref() { } }; };

const tools = {};
const pi = { registerTool(def) { tools[def.name] = def; }, on() { }, sendMessage() { } };
const mod = await import(pathToFileURL(path.join(EMIT, "index.js")).href);
mod.default(pi);
const t = tools["fleet_dispatch"];
if (!t) { console.error("FAIL fleet_dispatch tool not registered"); process.exit(2); }

let fails = 0;
let checks = 0;
const check = (name, cond, extra = "") => {
  checks++;
  if (cond) console.log(`  OK   ${name}${extra ? ` (${extra})` : ""}`);
  else { fails++; console.log(`  FAIL ${name}${extra ? ` (${extra})` : ""}`); }
};
const readJson = (p) => JSON.parse(fs.readFileSync(p, "utf8"));
const markerPair = (id, question, state = "running") => {
  fs.writeFileSync(path.join(STATE, `${id}.json`), JSON.stringify({ id, title: id, state, kind: "dispatch" }));
  fs.writeFileSync(path.join(STATE, `${id}.needs-input.json`), JSON.stringify({ question, taskState: "needs_input" }));
};
const pairSnapshot = (id) =>
  fs.readFileSync(path.join(STATE, `${id}.json`), "utf8") + "\x00" + fs.readFileSync(path.join(STATE, `${id}.needs-input.json`), "utf8");

// seed content so status/outcomes have something to show
fs.writeFileSync(path.join(STATE, "seed-1.json"), JSON.stringify({ id: "seed-1", title: "Seed Task", project: PROJECT, state: "done", startedAt: 1750000000000, doneAt: 1750000010000, summary: "seeded" }, null, 2) + "\n");
fs.writeFileSync(path.join(STATE, "branch-outcomes.jsonl"), JSON.stringify({ ts: 1750000000, taskId: "row-1", verdict: "done", project: PROJECT, summary: "seeded row" }) + "\n");

// ---- S1 fleet_status (allowlisted) -----------------------------------------
{
  markerPair("cmd-1", "fleet_status");
  const snap = pairSnapshot("cmd-1");
  const r = await t.execute("c1", { taskId: "cmd-1", command: "fleet_status" });
  const d = readJson(path.join(STATE, "cmd-1.done.json"));
  check("S1 done.json status=done", d.status === "done" && d.summary === r.content[0].text);
  check("S1 summary is the fleet_status text", d.summary.includes("**pi-fleet fleet (") && d.summary.includes("Seed Task"), d.summary.split("\n")[0]);
  check("S1 single-writer: markers untouched", pairSnapshot("cmd-1") === snap);
}
// ---- S2 fleet_outcomes (allowlisted) ---------------------------------------
{
  markerPair("cmd-2", "fleet_outcomes");
  const snap = pairSnapshot("cmd-2");
  const r = await t.execute("c2", { taskId: "cmd-2", command: "fleet_outcomes" });
  const d = readJson(path.join(STATE, "cmd-2.done.json"));
  check("S2 done.json status=done", d.status === "done");
  check("S2 summary is the outcomes list", d.summary.includes("**branch-outcomes registry (1 rows)**") && d.summary.includes("row-1"), d.summary.split("\n")[0]);
  check("S2 single-writer: markers untouched", pairSnapshot("cmd-2") === snap);
}
// ---- S3 unknown command (refused) ------------------------------------------
{
  markerPair("cmd-3", "rm -rf /");
  const snap = pairSnapshot("cmd-3");
  const r = await t.execute("c3", { taskId: "cmd-3", command: "rm -rf /" });
  const d = readJson(path.join(STATE, "cmd-3.done.json"));
  check("S3 done.json refused", d.status === "failed" && d.summary === "refused: command not allowed");
  check("S3 returned summary == marker summary", r.content[0].text === "refused: command not allowed");
  check("S3 single-writer: markers untouched", pairSnapshot("cmd-3") === snap);
}
// ---- S4 malformed launch (refused) -----------------------------------------
{
  markerPair("cmd-4", "fleet_launch");
  const r = await t.execute("c4", { taskId: "cmd-4", command: "fleet_launch" });
  const d = readJson(path.join(STATE, "cmd-4.done.json"));
  check("S4 fleet_launch w/o args refused", d.status === "failed" && d.summary === "refused: command not allowed");
  check("S4 no spawn on refusal", spawnCalls.length === 0);
}
// ---- S5 strict allowlist (extra args refused) ------------------------------
{
  markerPair("cmd-5", "fleet_status extra");
  const r = await t.execute("c5", { taskId: "cmd-5", command: "fleet_status extra" });
  const d = readJson(path.join(STATE, "cmd-5.done.json"));
  check("S5 'fleet_status extra' refused", d.status === "failed" && d.summary === "refused: command not allowed");
}
// ---- S6 invalid taskId (path-traversal defense) ----------------------------
{
  const evil = "../../evil";
  const r = await t.execute("c6", { taskId: evil, command: "fleet_status" });
  check("S6 invalid taskId rejected", r.details?.status === "rejected" && r.content[0].text.includes("invalid taskId"));
  const escaped = path.join(STATE, "..", "..", "evil.done.json");
  check("S6 nothing written outside STATE_HOME", !fs.existsSync(escaped));
}
// ---- S7 fleet_launch (allowlisted launch path) -----------------------------
{
  markerPair("cmd-7", `fleet_launch ${PROJECT} analizza il repo e scrivi un report di follow-up`);
  const snap = pairSnapshot("cmd-7");
  const r = await t.execute("c7", { taskId: "cmd-7", command: `fleet_launch ${PROJECT} analizza il repo e scrivi un report di follow-up` }, undefined, undefined, { model: { id: "gpt-5.6-sol", provider: "openai-codex" } });
  const d = readJson(path.join(STATE, "cmd-7.done.json"));
  const m = d.summary.match(/^launched task (\S+) \(project (.+)\); follow-up via fleet_status\/fleet_outcomes$/);
  check("S7 done.json launch summary shape", !!(m && d.status === "done"), d.summary);
  if (m) {
    const newId = m[1];
    const taskRec = readJson(path.join(STATE, `${newId}.json`));
    check("S7 task record written (spawning, ship)", taskRec.state === "spawning" && taskRec.kind === "ship" && taskRec.project === PROJECT);
    check("S7 title derived 'Remote: <first 60 chars>'", taskRec.title.startsWith("Remote: ") && taskRec.title.slice(8).length <= 60 && taskRec.title.length >= 15, taskRec.title);
    check("S7 brief file written via launcher pattern", fs.existsSync(path.join(STATE, "tasks", `${newId}.brief.md`)));
    check("S7 launcher spawned (herdr-launch.sh, one call)", spawnCalls.length === 1 && (spawnCalls[0][1] ?? []).join(" ").includes("herdr-launch.sh"));
    if (spawnCalls.length) {
      const all = spawnCalls[0][1].join(" ");
      check("S7 spawn arg contract (--task-id/--project/brief-file)", all.includes("--task-id " + newId) && all.includes("--project " + PROJECT) && all.includes(`@${STATE}/tasks/${newId}.brief.md`));
      check("S7 model inherited provider/id", all.includes("--model openai-codex/gpt-5.6-sol"));
      check("S7 worktree default ON (no --no-worktree)", !all.includes("--no-worktree"));
    }
    check("S7 single-writer: markers untouched", pairSnapshot("cmd-7") === snap);
    check("S7 atomic done (no .tmp leftover)", !fs.existsSync(path.join(STATE, "cmd-7.done.json.tmp")));
  }
}
// ---- S8 fleet_launch with unresolvable project -----------------------------
{
  markerPair("cmd-8", `fleet_launch /nonexistent/xyz-${Date.now()} brief`);
  const r = await t.execute("c8", { taskId: "cmd-8", command: `fleet_launch /nonexistent/xyz-${Date.now()} brief` });
  const d = readJson(path.join(STATE, "cmd-8.done.json"));
  check("S8 unresolvable project fails with reason", d.status === "failed" && d.summary.includes("fleet_launch refused:"), d.summary);
  check("S8 no launcher spawn on bad project", spawnCalls.length === 1, `spawnCalls=${spawnCalls.length}`);
}

console.log(`DISPATCH DRIVER: ${checks - fails}/${checks} checks green`);
process.exit(fails === 0 ? 0 : 1);
EOF

# bounded node run: the harness must not hang the suite
rlimit 120 "$SCRATCH/driver.out" env \
  PI_FLEET_CAPTAIN=1 \
  FLEET_STATE_HOME="$STATE_B" \
  SCRATCH_PROJECT="$PROJ" \
  EMIT="$EMIT" \
  node "$DRIVER" || { fail "node driver failed (exit $?) — see $SCRATCH/driver.out"; cat "$SCRATCH/driver.out" 2>/dev/null; die "driver failure"; }
cat "$SCRATCH/driver.out"
grep -qE '^DISPATCH DRIVER:.*checks green$' "$SCRATCH/driver.out" || die "driver did not complete cleanly"

# ---------------------------------------------------------------- result ---
# smoke-own checks: A (tsc) + B (watcher channel); the driver (STEP C) validates
# its scenarios itself (exit code + 'DISPATCH DRIVER: N/N checks green').
total_target=0
if [[ "${SMOKE_DRIVER_ONLY:-0}" != "1" ]]; then total_target=$((total_target + 2)); fi
log "OUTCOME: $OK/$total_target smoke checks green"
[[ "$OK" -ge "$total_target" ]] || die "not all dispatch smoke checks passed"
exit 0