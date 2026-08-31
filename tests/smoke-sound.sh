#!/usr/bin/env bash
#
# pi-fleet · T-028 captain audible reply (completion notification) — fully headless
#
# Compiles the extension tree (tsc) and drives the REAL compiled extension with
# a mock pi (no herdr, no launcher, no real fleet state). Isolated
# FLEET_STATE_HOME under /tmp — the real ~/.pi/fleet is NEVER touched.
#
#   A  tsc: the whole extension tree compiles clean (npx tsc --noEmit).
#   B  emit: extension compiled to JS (tsc --outDir) — the driver imports the
#      real code, not a re-implementation.
#   C  captain mode  (PI_FLEET_CAPTAIN=1): simulated agent runs fire the REAL
#      agent_start/message_end/agent_settled hooks:
#        S1 displayed assistant turn, config absent (default ON)      → bell
#        S2 internal silent wake (role "custom", display:false-like)  → silent
#        S3 config `notify.sound: off` (captain.md) + displayed turn → silent
#        S4 config invalid value ("banana") + displayed turn          → bell (default)
#        S5 tool-only / empty assistant content                       → silent
#        S6 pure config/tracker unit checks (on/off/invalid/missing, visible-text)
#   D  child mode (PI_FLEET_CHILD=1): the SAME displayed turn          → silent
#      (sound ONLY from the captain; children never ring)
#
# KEEP the scratch with SMOKE_KEEP=1.
# Exit: 0 green / 1 failed / 2 missing prerequisites.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
TS="$(date +%s)"
SCRATCH="/tmp/fleet-sound-smoke-$TS"
STATE="$SCRATCH/state"               # isolated FLEET_STATE_HOME
EMIT="$REPO_ROOT/.tmp/smoke-sound-$TS/js"   # under the repo: same node_modules resolution as smoke-dispatch
DRIVER="$SCRATCH/driver.mjs"
KEEP="${SMOKE_KEEP:-0}"

log() { printf 'SOUND [%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf 'SOUND FAIL: %s\n' "$*" >&2; exit 1; }
die2() { printf 'SOUND SKIP (exit 2): %s\n' "$*" >&2; exit 2; }

command -v node >/dev/null 2>&1 || die2 "node not found in PATH"
command -v git >/dev/null 2>&1 || die2 "git not found in PATH"
bash -n "$0" || die "smoke-sound.sh does not pass bash -n (self-check)"

cleanup() {
  [[ "$KEEP" == "1" ]] && { log "SMOKE_KEEP=1: keeping $SCRATCH"; return 0; }
  rm -rf "$SCRATCH"
  rm -rf "$EMIT"
}
trap cleanup EXIT

mkdir -p "$STATE/tasks"

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
log "STEP A — tsc --noEmit over the extension tree"
if tsckit "$SCRATCH/tsc.log" --noEmit; then
  pass "tsc --noEmit clean"
else
  fail "tsc --noEmit failed (see $SCRATCH/tsc.log)"
fi

# ============================================ B compile + driver ===========
log "STEP B — compile the extension (outDir) for the mock-pi driver"
if ! tsckit "$SCRATCH/tsc-emit.log" --outDir "$EMIT" --noEmit false; then
  die "extension emit compile failed (see $SCRATCH/tsc-emit.log)"
fi
[[ -f "$EMIT/index.js" ]] || die "emit missing index.js: $EMIT"
[[ -f "$EMIT/fleet-sound.js" ]] || die "emit missing fleet-sound.js: $EMIT"
pass "extension emit compile ok (fleet-sound.js + index.js)"

cat > "$DRIVER" <<'EOF'
// T-028 driver — drives the REAL compiled extension with a mock pi.
// Mode from argv[2]: "captain" (PI_FLEET_CAPTAIN=1, TTY-less stdout) or
// "child" (PI_FLEET_CHILD=1): the same simulated turns, different gates.
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const MODE = process.argv[2] ?? "captain";
const STATE = process.env.FLEET_STATE_HOME;
const EMIT = process.env.EMIT;

// --- mock pi: capture handlers + tools (no real herdr/launcher ever runs) ---
const handlers = {};
const tools = {};
const pi = {
  registerTool(def) { tools[def.name] = def; },
  on(name, h) { (handlers[name] ??= []).push(h); },
  sendMessage() {},
  registerCommand() {},
  logger: { warn() {} },
};

// --- bell sink capture (THROUGH the real fleet-sound module) ---------------
const sound = await import(pathToFileURL(path.join(EMIT, "fleet-sound.js")).href);
const captured = [];
sound.setSoundSink((payload) => captured.push(payload));

// --- load the REAL compiled extension ---------------------------------------
const mod = await import(pathToFileURL(path.join(EMIT, "index.js")).href);
mod.default(pi);

let fails = 0;
let checks = 0;
const check = (name, cond, extra = "") => {
  checks++;
  if (cond) console.log(`  OK   ${name}${extra ? ` (${extra})` : ""}`);
  else { fails++; console.log(`  FAIL ${name}${extra ? ` (${extra})` : ""}`); }
};

// Simulate one agent run with the recorded hooks (displayed turn = assistant
// message with visible text; wake = role "custom").
const fire = (msgs) => {
  (handlers.agent_start ?? []).forEach((h) => h({}, { ui: {} }));
  for (const m of msgs) (handlers.message_end ?? []).forEach((h) => h({ message: m }, { ui: {} }));
  (handlers.agent_settled ?? []).forEach((h) => h({}, { ui: {} }));
};
const assistantText = (text) => ({ role: "assistant", content: [{ type: "text", text }] });
const silentWake = (text) => ({ role: "custom", content: text, display: false, customType: "fleet_notice" });
const captainMd = (line) => fs.writeFileSync(path.join(STATE, "captain.md"), `# Captain preferences\n${line}\n`);

if (MODE === "captain") {
  // ---- S1 displayed turn, config absent (default ON) → bell ----------------
  captured.length = 0;
  fire([assistantText("Group complete: T-001 done.")]);
  check("S1 default ON + displayed turn rings (exactly one BEL)", captured.length === 1 && captured[0] === sound.BELL, JSON.stringify(captured));

  // ---- S2 internal silent wake (display:false) → no bell -------------------
  captured.length = 0;
  fire([silentWake("[silent fleet-notice] Task group completed (1 tasks): x-1.")]);
  check("S2 display:false wake never rings", captured.length === 0, JSON.stringify(captured));

  // ---- S3 config off + displayed turn → no bell ----------------------------
  captainMd("notify.sound: off");
  check("S3a isSoundEnabled false with 'off'", sound.isSoundEnabled(STATE) === false);
  captured.length = 0;
  fire([assistantText("Task x-1 done.")]);
  check("S3b config off suppresses the bell", captured.length === 0, JSON.stringify(captured));

  // ---- S4 invalid config value → default ON → bell -------------------------
  captainMd("notify.sound: banana");
  check("S4a invalid value resolves to ON", sound.isSoundEnabled(STATE) === true);
  captured.length = 0;
  fire([assistantText("Task x-2 done.")]);
  check("S4b invalid value rings (default ON)", captured.length === 1 && captured[0] === sound.BELL, JSON.stringify(captured));

  // ---- S5 tool-only / empty assistant content → no bell --------------------
  fs.rmSync(path.join(STATE, "captain.md"), { force: true });
  captured.length = 0;
  fire([{ role: "assistant", content: [{ type: "toolCall", id: "c1", name: "fleet_status", arguments: {} }] }]);
  fire([assistantText("")]);
  check("S5 tool-only/empty assistant turns never ring (even if config on)", captured.length === 0, JSON.stringify(captured));

  // ---- S6 pure unit checks ---------------------------------------------------
  const pd = sound.parseSoundConfig;
  check("S6 parseSoundConfig defaults", pd(null) === true && pd(undefined) === true && pd("") === true);
  check("S6 parseSoundConfig on forms", pd("on") === true && pd("ON") === true && pd(" On ") === true);
  check("S6 parseSoundConfig off forms", pd("off") === false && pd("OFF") === false && pd(" Off ") === false);
  check("S6 parseSoundConfig invalid → ON", pd("banana") === true && pd("1") === true);
  const vtl = sound.messageVisibleTextLength;
  check("S6 visible length: string text", vtl("hi there") === 8 && vtl("   ") === 0);
  check("S6 visible length: text parts only (thinking/toolCall excluded)", vtl([{ type: "text", text: "a" }, { type: "thinking", thinking: "hidden" }, { type: "toolCall", id: "x", name: "t", arguments: {} }]) === 1);
  const dAm = sound.isDisplayedAssistantMessage;
  check("S6 displayed detection: assistant w/ text yes", dAm("assistant", "reply") === true);
  check("S6 displayed detection: custom/toolResult/user no", dAm("custom", "x") === false && dAm("toolResult", "x") === false && dAm("user", "x") === false);
  const tracker = sound.createSoundTracker();
  let rang = false;
  sound.setSoundSink(() => { rang = true; });
  tracker.onAgentStart();
  check("S6 tracker: no assistant → no ring", sound.ringForSettledTurn(STATE, tracker) === false && rang === false);
  tracker.onMessageEnd("assistant", "hello");
  check("S6 tracker: assistant seen → ring (config on now)", sound.ringForSettledTurn(STATE, tracker) === true && rang === true);
  rang = false;
  captainMd("notify.sound: off");
  check("S6 tracker: assistant seen + config off → no ring", sound.ringForSettledTurn(STATE, tracker) === false && rang === false);
  fs.rmSync(path.join(STATE, "captain.md"), { force: true });
} else {
  // ---- S7 child session (PI_FLEET_CHILD=1): the SAME displayed turn --------
  // IS_CAPTAIN=false → the agent_settled hook returns before ringing.
  captured.length = 0;
  fire([assistantText("Child reports group complete."), silentWake("ignored")]);
  check("S7 child session NEVER rings (displayed turn + wake both silent)", captured.length === 0, JSON.stringify(captured));
}

console.log(`SOUND DRIVER (${MODE}): ${checks - fails}/${checks} checks green`);
process.exit(fails === 0 ? 0 : 1);
EOF

# ============================================= C captain-mode driver =======
log "STEP C — captain-mode driver (mock pi, simulated agent turns)"
rlimit 120 "$SCRATCH/driver-captain.out" env \
  PI_FLEET_CAPTAIN=1 \
  FLEET_STATE_HOME="$STATE" \
  EMIT="$EMIT" \
  node "$DRIVER" captain || {
    fail "captain driver failed (exit $?)"
    cat "$SCRATCH/driver-captain.out" 2>/dev/null
    die "captain driver failure"
  }
cat "$SCRATCH/driver-captain.out"
grep -qE '^SOUND DRIVER \(captain\):.*checks green$' "$SCRATCH/driver-captain.out" || die "captain driver did not complete cleanly"

# ============================================== D child-mode driver =========
log "STEP D — child-mode driver (PI_FLEET_CHILD=1, same simulated turns)"
rlimit 120 "$SCRATCH/driver-child.out" env \
  PI_FLEET_CHILD=1 \
  FLEET_STATE_HOME="$STATE" \
  EMIT="$EMIT" \
  node "$DRIVER" child || {
    fail "child driver failed (exit $?)"
    cat "$SCRATCH/driver-child.out" 2>/dev/null
    die "child driver failure"
  }
cat "$SCRATCH/driver-child.out"
grep -qE '^SOUND DRIVER \(child\):.*checks green$' "$SCRATCH/driver-child.out" || die "child driver did not complete cleanly"

# ---------------------------------------------------------------- result ---
log "OUTCOME: $OK/2 smoke checks green"
[[ "$OK" -ge 2 ]] || die "not all sound smoke checks passed"
exit 0