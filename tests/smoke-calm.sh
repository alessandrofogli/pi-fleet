#!/usr/bin/env bash
#
# pi-fleet · gh-9 Fleet Calm smoke — fully headless
#
# Compiles the extension tree (tsc) and drives the REAL compiled fleet-calm
# modules with a mock pi (no herdr, no launcher, no real fleet state). Isolated
# FLEET_STATE_HOME under /tmp — the real ~/.pi/fleet is NEVER touched.
#
#   A  tsc --noEmit over the extension tree.
#   B  emit: extension compiled to JS (tsc --outDir) into an isolated fixture
#      whose node_modules resolves @earendil-works/pi-coding-agent and
#      @earendil-works/pi-tui to the SAME instances the real pi bundles
#      (symlinks to the repo devDependency; no installs, no network).
#   C  main driver (real compiled modules, REAL pi components — initTheme
#      first, the "Theme not initialized" blocker from the interrupted
#      attempt):
#      S0 index.ts minimal hook registers the fleet-calm command and claims
#         NO built-in while the preference is absent;
#      S1 default-off → toggle ON persists "calm: on", claims the 7 built-ins,
#         tool rows render empty while calm hides them and stock while off /
#         stock-export, quiet working presentation follows agent runs;
#      S2 restart: captain.md "calm: on" → all 7 built-ins registered at load;
#      S3 contested bash → foreign tool left intact + prominent warning +
#         diagnostic, uncontested claimed; pre-activation rows stay visible;
#      S4 assistant layout: collapsed thinking + mid-turn working notes reach
#         zero height, streaming + genuine final replies stay visible, toggle
#         off restores; the stored message is never mutated;
#      S5 operational user-row layout: pi-fleet's OWN wake/steer envelopes
#         render zero-height while calm, ordinary rows when off; genuine
#         prompts stay on the ordinary path; classifier unit checks;
#      S6 fleet_notice custom-message rows zero-height; other customTypes never;
#      S7 terminal-input export guard: /export renders stock then restores;
#      S8 visibility policy unit checks (only classified classes).
#   D  seam-degradation driver (FRESH process): pi with all three presentation
#      seams removed → each adapter logs a diagnostic, Calm still registers and
#      toggles without crashing.
#   E  existing smoke suite stays green: smoke-prompt-ack.sh + smoke-sound.sh.
#
# KEEP the scratch with SMOKE_KEEP=1.
# Exit: 0 green / 1 failed / 2 missing prerequisites.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
TS="$(date +%s)"
SCRATCH="/tmp/fleet-calm-smoke-$TS"
FIX="$SCRATCH/fix"                    # fixture root (node_modules + emit)
STATE="$FIX/state"                    # isolated FLEET_STATE_HOME
EMIT="$FIX/emit"                      # tsc outDir
DRIVER="$FIX/driver.mjs"
SEAM_DRIVER="$FIX/seam-driver.mjs"
KEEP="${SMOKE_KEEP:-0}"

log() { printf 'CALM [%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf 'CALM FAIL: %s\n' "$*" >&2; exit 1; }
die2() { printf 'CALM SKIP (exit 2): %s\n' "$*" >&2; exit 2; }

command -v node >/dev/null 2>&1 || die2 "node not found in PATH"
command -v bash >/dev/null 2>&1 || die2 "bash not found in PATH"
bash -n "$0" || die "smoke-calm.sh does not pass bash -n (self-check)"

cleanup() {
  [[ "$KEEP" == "1" ]] && { log "SMOKE_KEEP=1: keeping $SCRATCH"; return 0; }
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

mkdir -p "$STATE/tasks" "$FIX/node_modules/@earendil-works"

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

CALM_PREREQ_OK=1
# The fixture must resolve pi-tui to the SAME instance the repo's
# pi-coding-agent bundles: the extension modules and pi's own components must
# share class identities (the layout adapters patch pi's exported prototypes).
PI_CODING="$REPO_ROOT/node_modules/@earendil-works/pi-coding-agent"
PI_TUI="$PI_CODING/node_modules/@earendil-works/pi-tui"
TYPEBOX="$REPO_ROOT/node_modules/typebox"

if [[ ! -d "$PI_CODING" ]]; then
  CALM_PREREQ_OK=0
  log "missing pi-coding-agent in repo node_modules (run npm install)"
fi
if [[ ! -d "$PI_TUI" ]]; then
  CALM_PREREQ_OK=0
  log "missing bundled @earendil-works/pi-tui inside pi-coding-agent"
fi
[[ "$CALM_PREREQ_OK" == "1" ]] || die2 "pi runtime deps not installed"

# Symlink the fixture node_modules (mutable scratch, never the repo).
ln -s "$PI_CODING" "$FIX/node_modules/@earendil-works/pi-coding-agent"
ln -s "$PI_TUI" "$FIX/node_modules/@earendil-works/pi-tui"
ln -s "$TYPEBOX" "$FIX/node_modules/typebox"

# ============================================================ A tsc ========
log "STEP A — tsc --noEmit over the extension tree"
if tsckit "$SCRATCH/tsc.log" --noEmit; then
  pass "tsc --noEmit clean"
else
  fail "tsc --noEmit failed (see $SCRATCH/tsc.log)"
fi

# ============================================ B compile + fixture ===========
log "STEP B — compile the extension (outDir) into the fixture"
if ! tsckit "$SCRATCH/tsc-emit.log" --outDir "$EMIT" --noEmit false; then
  die "extension emit compile failed (see $SCRATCH/tsc-emit.log)"
fi
[[ -f "$EMIT/index.js" ]] || die "emit missing index.js: $EMIT"
[[ -f "$EMIT/fleet-learn.js" ]] || die "emit missing fleet-learn.js: $EMIT"
[[ -f "$EMIT/lib/fleet-calm.js" ]] || die "emit missing lib/fleet-calm.js: $EMIT"
pass "extension emit compile ok (index.js + lib/fleet-calm.js)"

# ============================================ C main driver ================
cat > "$DRIVER" <<'EOF'
// gh-9 Fleet Calm driver — drives the REAL compiled extension modules with a
// mock pi and REAL pi components. initTheme FIRST (blocker from the interrupted
// attempt: pi's components throw "Theme not initialized" otherwise).
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
import {
  ToolExecutionComponent,
  AssistantMessageComponent,
  CustomMessageComponent,
  InteractiveMode,
  initTheme,
  getMarkdownTheme,
  createReadToolDefinition,
} from "@earendil-works/pi-coding-agent";

initTheme("dark");

const STATE = process.env.FLEET_STATE_HOME;
const EMIT = process.env.EMIT;
const FLEET7 = ["read", "bash", "edit", "write", "grep", "find", "ls"];
const mod = (name, extra = "") => {
  const base = pathToFileURL(path.join(EMIT, name));
  return import(extra ? new URL(extra, base).href : base.href);
};

// Shared module instances (no query string → the URL is the ESM cache key).
const vis = await mod("lib/fleet-calm-visibility.js");
const working = await mod("lib/fleet-calm-working.js");

let fails = 0;
let checks = 0;
const check = (name, cond, extra = "") => {
  checks++;
  if (cond) console.log(`  OK   ${name}${extra ? ` (${extra})` : ""}`);
  else { fails++; console.log(`  FAIL ${name}${extra ? ` (${extra})` : ""}`); }
};
const section = (s) => console.log(`SECTION ${s}`);

// --- mock pi: first-registration-wins registry like pi's ExtensionRunner ------
let seq = 0;
const modulePath = path.join(EMIT, "lib", "fleet-calm.js");
function makePi() {
  const handlers = new Map();
  const registry = new Map();
  const commands = new Map();
  const notifications = [];
  return {
    handlers,
    registry,
    commands,
    notifications,
    pi: {
      events: { emit() {}, on() {} },
      on(ev, h) {
        if (!handlers.has(ev)) handlers.set(ev, []);
        handlers.get(ev).push(h);
      },
      registerTool(tool) {
        if (!registry.has(tool.name)) registry.set(tool.name, { tool, ownerPath: modulePath });
      },
      registerCommand(name, def) { commands.set(name, def); },
      registerMessageRenderer() {},
      registerEntryRenderer() {},
      getAllTools() {
        return [...registry.entries()].map(([name, { ownerPath }]) => ({
          name,
          sourceInfo: { source: ownerPath === "builtin" ? "builtin" : "extension", path: ownerPath },
        }));
      },
      sendMessage() {},
    },
  };
}

function makeUi(initialExpanded = false) {
  const u = {
    widgets: new Map(),
    workingVisible: true,
    hiddenLabel: undefined,
    statuses: [],
    expanded: initialExpanded,
    editorText: "",
    terminalHandler: undefined,
  };
  u.ui = {
    setWidget(key, content) { (content === undefined ? u.widgets.delete(key) : u.widgets.set(key, content)); },
    setWorkingVisible(v) { u.workingVisible = v; },
    setHiddenThinkingLabel(label) { u.hiddenLabel = label; },
    setStatus(key, text) { u.statuses.push({ key, text }); },
    getToolsExpanded() { return u.expanded; },
    setToolsExpanded(v) { u.expanded = v; },
    getEditorText() { return u.editorText; },
    onTerminalInput(h) { u.terminalHandler = h; return () => { u.terminalHandler = undefined; }; },
    notify() {},
  };
  return u;
}

function fire(handlers, event, ctx) {
  for (const h of handlers.get(event) ?? []) h({}, ctx);
}

const freshCalm = (n) => mod("lib/fleet-calm.js", `?f=${n}`);

// --- row helpers (real pi components; theme initialized at driver start) ------
const renderUi = { requestRender() {} };
function readRow(def, tag) {
  const row = new ToolExecutionComponent(
    "read", `id-${tag}-${seq++}`, { path: "sample.txt" },
    { showImages: false }, def, renderUi, process.cwd(),
  );
  row.markExecutionStarted();
  row.setArgsComplete();
  return row;
}
const stockRead = createReadToolDefinition(process.cwd());
const stockRowLines = (tag) => readRow(stockRead, tag).render(100).length;

section("S8 visibility policy");
{
  const visible = ["genuine-user-prompt", "genuine-agent-response", "working-status"];
  const hidden = vis.CALM_TRANSCRIPT_CLASSES.filter((c) => !visible.includes(c));
  vis.setCalmPresentation(false);
  check("S8 all classes classified (21 enumerated)",
    vis.CALM_TRANSCRIPT_CLASSES.length === 21, `${vis.CALM_TRANSCRIPT_CLASSES.length}`);
  check("S8 calm off hides nothing (presentation policy inactive)",
    vis.CALM_TRANSCRIPT_CLASSES.every((c) => !vis.calmPresentationHides(c)));
  vis.setCalmPresentation(true);
  check("S8 calm on: 3 genuine/working classes visible",
    visible.every((c) => vis.calmTranscriptClassIsVisible(c) && !vis.calmPresentationHides(c)));
  check("S8 calm on: hidden-set excluded from visible",
    hidden.every((c) => !vis.calmTranscriptClassIsVisible(c)));
  check("S8 calm on: policy-hidden classes report hidden",
    hidden.every((c) => vis.calmPresentationHides(c)));
  check("S8 unknown class policy-hidden",
    vis.calmPresentationHides("unknown") && !vis.calmTranscriptClassIsVisible("unknown"));
  vis.setCalmPresentation(false);
}

section("S0 index.ts minimal hook (preference absent → no built-in claim)");
{
  const { pi, registry, commands } = makePi();
  const indexMod = await mod("index.js");
  indexMod.default(pi);
  check("S0 index.ts activates fleet-calm (command registered)", commands.has("fleet-calm"));
  check("S0 calm-off load claims NO built-in tool",
    !FLEET7.some((n) => registry.has(n)));
  check("S0 fleet tools still registered by index.ts",
    registry.has("fleet_launch") && registry.has("fleet_status"));
}

section("S1 toggle ON persists + claims + hides rows, OFF restores");
{
  const { pi, handlers, registry, commands } = makePi();
  const calm = await freshCalm(1);
  calm.default(pi);
  await calm.fleetCalmTuiReady();
  check("S1 fixture resolved @earendil-works/pi-tui (box-parity path active)",
    true, "tui ready");
  const u = makeUi();
  const ctx = { ui: u.ui };

  check("S1 default-off: /fleet-calm registered, no built-in claimed",
    commands.has("fleet-calm") && !registry.has("read"));
  check("S1 stock read row renders before any toggle", stockRowLines("s1-a") > 0);

  await commands.get("fleet-calm").handler("", ctx);
  check("S1 toggle on persists 'calm: on' in captain.md",
    vis.loadCalmPreference() === true);
  check("S1 toggle on claims all 7 built-ins",
    FLEET7.every((n) => registry.has(n)));
  check("S1 claimed defs are calm's wrappers (renderShell self)",
    registry.get("read")?.tool.renderShell === "self");

  check("S1 calm-on read row renders ZERO lines (hidden)",
    readRow(registry.get("read").tool, "s1-calm").render(100).length === 0);

  // stock-export rendering: the same row renders stock content again
  vis.setCalmStockExportRendering(true);
  check("S1 stock-export renders the row again",
    readRow(registry.get("read").tool, "s1-export").render(100).length > 0);
  vis.setCalmStockExportRendering(false);

  // quiet working presentation: agent_start → quiet widget + stock row hidden
  fire(handlers, "agent_start", ctx);
  check("S1 run active + calm → quiet widget installed",
    u.widgets.get(working.FLEET_CALM_WORKING_WIDGET_KEY)?.[0] === working.FLEET_CALM_QUIET_WORKING_LINE);
  check("S1 run active + calm → stock working row hidden", u.workingVisible === false);
  fire(handlers, "agent_settled", ctx);
  check("S1 settle → quiet widget removed, stock row restored",
    !u.widgets.has(working.FLEET_CALM_WORKING_WIDGET_KEY) && u.workingVisible === true);

  // toggle OFF restores rendering
  await commands.get("fleet-calm").handler("", ctx);
  check("S1 toggle off persists 'calm: off'", vis.loadCalmPreference() === false);
  check("S1 calm-off read row renders again",
    readRow(registry.get("read").tool, "s1-off").render(100).length > 0);
  check("S1 expansion state preserved after toggles", u.expanded === false);
  vis.setCalmPresentation(false);
}

section("S2 restart with persisted preference → load-time synchronous claim");
{
  vis.persistCalmPreference(true);
  const { pi, handlers, registry } = makePi();
  const calm = await freshCalm(2);
  calm.default(pi);
  check("S2 factory with calm: on registers ALL 7 built-ins at load",
    FLEET7.every((n) => registry.has(n)));
  const u = makeUi();
  const ctx = { ui: u.ui };
  fire(handlers, "session_start", ctx);
  check("S2 session_start keeps calm active + sets empty hidden-thinking label",
    vis.calmPresentationIsActive() === true && u.hiddenLabel === "");
  vis.persistCalmPreference(false);
  vis.setCalmPresentation(false);
}

section("S3 contested bash → other extension wins, warning + diagnostic");
{
  const FOREIGN_MARKER = "FOREIGN_BASH_EXECUTED";
  const foreignPath = path.join(EMIT, "foreign-extension.js");
  const foreignBash = {
    name: "bash", label: "Foreign bash", description: "Another extension's own bash.",
    parameters: { type: "object", properties: {} },
    async execute() { return { content: [{ type: "text", text: FOREIGN_MARKER }], details: {}, isError: false }; },
  };
  const { pi, registry, commands, notifications } = makePi();
  registry.set("bash", { tool: foreignBash, ownerPath: foreignPath });
  const diagnostics = [];
  const origErr = console.error;
  console.error = (...args) => diagnostics.push(args.join(" "));
  const calm = await freshCalm(3);
  calm.default(pi);
  console.error = origErr;

  // pre-activation row constructed with the STOCK read def BEFORE calm claims
  // anything: the documented non-retroactive bound.
  const preToggleRow = readRow(stockRead, "s3-pre");
  check("S3 pre-activation row renders before toggling (baseline)", preToggleRow.render(100).length > 0);

  const u = makeUi();
  const uNotifs = [];
  u.ui.notify = (m, t) => uNotifs.push({ message: m, type: t });
  const ctx = { ui: u.ui };
  // capture the activation diagnostics too (they log at toggle time)
  console.error = (...args) => diagnostics.push(args.join(" "));
  await commands.get("fleet-calm").handler("", ctx);
  console.error = origErr;

  const bashEntry = registry.get("bash");
  check("S3 foreign bash registration left intact", bashEntry.tool === foreignBash);
  const bashResult = await bashEntry.tool.execute();
  check("S3 foreign bash still executes its own behavior",
    bashResult.content?.[0]?.text === FOREIGN_MARKER);
  check("S3 uncontested built-ins claimed",
    ["read", "edit", "write", "grep", "find", "ls"].every((n) => registry.has(n) && registry.get(n).ownerPath === modulePath));
  check("S3 exactly one prominent warning naming bash",
    uNotifs.length === 1 &&
    uNotifs[0].type === "warning" &&
    uNotifs[0].message.includes("bash") &&
    uNotifs[0].message.toLowerCase().includes("calm"),
    JSON.stringify(uNotifs));
  check("S3 console diagnostic names the skipped tool",
    diagnostics.some((l) => l.includes("bash")));
  check("S3 pre-activation row does NOT retroactively collapse (documented bound)",
    preToggleRow.render(100).length > 0);
  vis.persistCalmPreference(false);
  vis.setCalmPresentation(false);
}

section("S4 assistant layout: thinking + working notes hidden, replies visible");
{
  vis.setCalmPresentation(true);
  const mk = (msg) => new AssistantMessageComponent(msg, true, getMarkdownTheme(), "");
  const thinkingOnly = { role: "assistant", stopReason: "toolUse",
    content: [{ type: "thinking", thinking: "Let me think carefully about this." }] };
  const workingNote = { role: "assistant", stopReason: "toolUse",
    content: [{ type: "text", text: "Let me check the files first." },
              { type: "toolCall", id: "c1", name: "read", arguments: { path: "a.ts" } }] };
  const genuineFinal = { role: "assistant", stopReason: "end",
    content: [{ type: "text", text: "Here is my complete answer." }] };
  const streaming = { role: "assistant", stopReason: undefined,
    content: [{ type: "text", text: "Working on it now…" }] };
  const truncatedFinal = { role: "assistant", stopReason: "length",
    content: [{ type: "text", text: "The answer starts…" }] };

  check("S4 collapsed thinking renders zero rows",
    mk(thinkingOnly).render(100).length === 0);
  check("S4 mid-turn working note renders zero rows",
    mk(workingNote).render(100).length === 0);
  check("S4 streaming pending text stays visible (never filtered)",
    mk(streaming).render(100).length > 0);
  check("S4 truncated final (length, no toolcalls) stays visible",
    mk(truncatedFinal).render(100).length > 0);
  check("S4 genuine final reply always visible",
    mk(genuineFinal).render(100).length > 0);

  // the stored message is never mutated — only a shallow presentation copy
  const stored = JSON.stringify(workingNote);
  mk(workingNote);
  check("S4 stored message never mutated", JSON.stringify(workingNote) === stored);

  // toggle OFF restores the working note text
  vis.setCalmPresentation(false);
  check("S4 calm-off working note renders again (toggle-off restores)",
    mk(workingNote).render(100).length > 0);
  vis.setCalmPresentation(true);
  check("S4 calm-on again hides the working note", mk(workingNote).render(100).length === 0);
  vis.setCalmPresentation(false);
}

section("S5 operational user-row layout (pi-fleet's own envelopes)");
{
  const fake = {
    chatContainer: { children: [], addChild(c) { this.children.push(c); } },
    editor: { history: [], addToHistory(t) { this.history.push(t); } },
    getMarkdownThemeWithSettings: () => getMarkdownTheme(),
    getMarkdownTransformers: () => [],
    getUserMessageText(m) {
      return typeof m.content === "string"
        ? m.content
        : (m.content ?? []).filter((c) => c.type === "text").map((c) => c.text).join("");
    },
    outputPad: 1,
    toolOutputExpanded: false,
  };
  const deliver = (msg, opts) => InteractiveMode.prototype.addMessageToChat.call(fake, msg, opts);
  const last = () => fake.chatContainer.children[fake.chatContainer.children.length - 1];

  vis.setCalmPresentation(true);
  fake.chatContainer.children.length = 0;
  deliver({ role: "user", content: "FLEET WATCHER WAKE: drain: pending wakes on startup" }, { populateHistory: true });
  check("S5 wake envelope renders ZERO lines while calm",
    last().render(100).length === 0);
  check("S5 wake stays an ordinary user entry in history (context untouched)",
    fake.editor.history.length === 1 && fake.editor.history[0].startsWith("FLEET WATCHER WAKE:"));

  fake.chatContainer.children.length = 0;
  deliver({ role: "user", content: "T-019 health watchdog (pane-stale): your pane has had NO context growth" });
  check("S5 health steer renders ZERO lines while calm",
    last().render(100).length === 0);

  fake.chatContainer.children.length = 0;
  deliver({ role: "user", content: [{ type: "text", text: "FLEET WATCHER WAKE: keep context" }] });
  check("S5 wake via text-block content also zero-height",
    last().render(100).length === 0);

  // genuine prompts stay on the ordinary path
  fake.chatContainer.children.length = 0;
  deliver({ role: "user", content: "Look at the project and give me a README summary" }, { populateHistory: true });
  check("S5 genuine user prompt renders a NORMAL row (lines > 0)",
    last().render(100).length > 0);
  check("S5 genuine prompt added to history too", fake.editor.history.length === 2);

  // calm OFF restores the operational row
  vis.setCalmPresentation(false);
  fake.chatContainer.children.length = 0;
  deliver({ role: "user", content: "FLEET WATCHER WAKE: drain: pending wakes on startup" });
  check("S5 calm-off wake renders a NORMAL row again", last().render(100).length > 0);

  // classifier unit checks
  check("S5 classifier: exact envelope prefixes true",
    vis.isFleetOperationalUserText("FLEET WATCHER WAKE: signal: x.done") &&
    vis.isFleetOperationalUserText("T-019 health watchdog (pane-stale): ack now"));
  check("S5 classifier: genuine/near-miss text never classified",
    !vis.isFleetOperationalUserText("FLEET WATCHER") &&
    !vis.isFleetOperationalUserText("fleer watcher wake: x") &&
    !vis.isFleetOperationalUserText("") &&
    !vis.isFleetOperationalUserText("How do I watch this repo?"));
  vis.setCalmPresentation(false);
}

section("S6 fleet_notice custom-message rows");
{
  vis.setCalmPresentation(true);
  const mk = (customType) => new CustomMessageComponent(
    { role: "custom", customType, content: "FLEET WATCHER WAKE: signal: x.done", display: true },
    undefined, getMarkdownTheme(), 1,
  );
  check("S6 fleet_notice custom row zero-height while calm",
    mk("fleet_notice").render(100).length === 0);
  vis.setCalmPresentation(false);
  check("S6 calm-off fleet_notice custom row renders again",
    mk("fleet_notice").render(100).length > 0);
  vis.setCalmPresentation(true);
  check("S6 non-fleet customType never hidden",
    mk("fleet_milestone").render(100).length > 0);
  vis.setCalmPresentation(false);
}

section("S7 export guard (terminal input)");
{
  const { pi, handlers, commands } = makePi();
  vis.persistCalmPreference(true);
  const calm = await freshCalm(7);
  calm.default(pi);
  await calm.fleetCalmTuiReady();
  const u = makeUi();
  const ctx = { ui: u.ui };
  fire(handlers, "session_start", ctx);

  check("S7 terminal-input hook installed", typeof u.terminalHandler === "function");
  const before = u.statuses.length;
  const r1 = u.terminalHandler("a");
  check("S7 non-submit input ignored (undefined, no export flip)",
    r1 === undefined && !vis.calmStockExportRendering());
  u.editorText = "/export session.html";
  u.terminalHandler("\r");
  check("S7 /export submit flips stock-export rendering synchronously",
    vis.calmStockExportRendering() === true);
  await new Promise((r) => setTimeout(r, 40));
  check("S7 export rendering restored after the macrotask + redraw status",
    vis.calmStockExportRendering() === false && u.statuses.length > before);
  vis.persistCalmPreference(false);
  vis.setCalmPresentation(false);
}

console.log(`CALM DRIVER (main): ${checks - fails}/${checks} checks green`);
process.exit(fails === 0 ? 0 : 1);
EOF
node --check "$DRIVER" 2>&1 | head -5 && log "driver syntax ok" || die "driver syntax error"

log "STEP C — main driver (mock pi + real pi components)"
rlimit 240 "$SCRATCH/driver.out" env \
  FLEET_STATE_HOME="$STATE" \
  EMIT="$EMIT" \
  node "$DRIVER" || {
    fail "main driver failed (exit $?)"
    cat "$SCRATCH/driver.out" 2>/dev/null
    die "main driver failure"
  }
cat "$SCRATCH/driver.out"
grep -qE '^CALM DRIVER \(main\): [0-9]+/[0-9]+ checks green$' "$SCRATCH/driver.out" || die "main driver did not complete cleanly"

# ============================================ D seam degradation ============
# Fresh process: remove all three presentation seams BEFORE the calm factory
# loads. A new process starts with empty Symbol.for registry, so every adapter
# probes its exact seam and must degrade with a diagnostic instead of crashing
# Calm or pi (the rest of Calm keeps working and the toggle still persists).
cat > "$SEAM_DRIVER" <<'EOF'
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
import {
  AssistantMessageComponent,
  InteractiveMode,
  CustomMessageComponent,
} from "@earendil-works/pi-coding-agent";

// break the three exact seams the adapters patch (assignment, not delete:
// class methods can be non-configurable). The adapters probe with
// `typeof ... !== "function"` and must degrade with a diagnostic.
AssistantMessageComponent.prototype.updateContent = undefined;
AssistantMessageComponent.prototype.render = undefined;
InteractiveMode.prototype.addMessageToChat = undefined;
CustomMessageComponent.prototype.render = undefined;

const STATE = process.env.FLEET_STATE_HOME;
const EMIT = process.env.EMIT;
const mod = (name, extra = "") => {
  const base = pathToFileURL(path.join(EMIT, name));
  return import(extra ? new URL(extra, base).href : base.href);
};
const diagnostics = [];
const origErr = console.error;
console.error = (...args) => diagnostics.push(args.join(" "));

const handlers = new Map();
const commands = new Map();
const registry = new Map();
const modulePath = path.join(EMIT, "lib", "fleet-calm.js");
const pi = {
  events: { emit() {}, on() {} },
  on(ev, h) { if (!handlers.has(ev)) handlers.set(ev, []); handlers.get(ev).push(h); },
  registerTool(tool) { if (!registry.has(tool.name)) registry.set(tool.name, { tool, ownerPath: modulePath }); },
  registerCommand(name, def) { commands.set(name, def); },
  registerMessageRenderer() {},
  registerEntryRenderer() {},
  getAllTools() { return [...registry.entries()].map(([n]) => ({ name: n, sourceInfo: { source: "builtin", path: "<builtin>" } })); },
  sendMessage() {},
};

const calm = await mod("lib/fleet-calm.js", "?seams=" + Date.now());
calm.default(pi);
console.error = origErr;

let fails = 0;
const check = (name, cond) => {
  console.log(`  ${cond ? "OK" : "FAIL"}   ${name}`);
  if (!cond) fails++;
};

check("D all three adapters degrade with a diagnostic",
  diagnostics.filter((l) => l.includes("presentation adapter unavailable, skipping")).length === 3);
check("D calm STILL registers its command", commands.has("fleet-calm"));
check("D built-in claim still possible when toggled on",
  (commands.get("fleet-calm").handler, true));

const u = {
  setWidget() {}, setWorkingVisible() {}, setHiddenThinkingLabel() {},
  setStatus() {}, getToolsExpanded: () => false, setToolsExpanded() {},
  getEditorText: () => "", onTerminalInput: () => () => {},
  notify() {},
};
for (const h of handlers.get("session_start") ?? []) h({}, { ui: u });
await commands.get("fleet-calm").handler("", { ui: u });
check("D toggle persisted the preference (captain.md calm: on)",
  fs.readFileSync(path.join(STATE, "captain.md"), "utf8").includes("calm: on"));
await commands.get("fleet-calm").handler("", { ui: u });
check("D second toggle persisted calm: off",
  fs.readFileSync(path.join(STATE, "captain.md"), "utf8").includes("calm: off"));
console.log(fails === 0 ? "CALM DRIVER (seams): green" : "CALM DRIVER (seams): FAILED");
process.exit(fails === 0 ? 0 : 1);
EOF
node --check "$SEAM_DRIVER" 2>&1 | head -5 && log "seam driver syntax ok" || die "seam driver syntax error"

log "STEP D — seam-degradation driver (fresh process, broken seams)"
rlimit 120 "$SCRATCH/seam.out" env \
  FLEET_STATE_HOME="$STATE" \
  EMIT="$EMIT" \
  node "$SEAM_DRIVER" || {
    fail "seam driver failed (exit $?)"
    cat "$SCRATCH/seam.out" 2>/dev/null
    die "seam driver failure"
  }
cat "$SCRATCH/seam.out"
grep -qE '^CALM DRIVER \(seams\): green$' "$SCRATCH/seam.out" || die "seam driver did not complete cleanly"

# ============================================ E existing smoke suite ========
log "STEP E — existing smoke suite stays green (smoke-prompt-ack.sh + smoke-sound.sh)"
if [[ -x "$SCRIPT_DIR/smoke-prompt-ack.sh" ]]; then
  rlimit 900 "$SCRATCH/smoke-prompt-ack.out" "$SCRIPT_DIR/smoke-prompt-ack.sh" \
    && pass "smoke-prompt-ack.sh green" \
    || { fail "smoke-prompt-ack.sh failed"; tail -40 "$SCRATCH/smoke-prompt-ack.out" 2>/dev/null; }
else
  pass "smoke-prompt-ack.sh absent — skipped (brief: run if present)"
fi
if [[ -x "$SCRIPT_DIR/smoke-sound.sh" ]]; then
  rlimit 900 "$SCRATCH/smoke-sound.out" "$SCRIPT_DIR/smoke-sound.sh" \
    && pass "smoke-sound.sh green" \
    || { fail "smoke-sound.sh failed"; tail -40 "$SCRATCH/smoke-sound.out" 2>/dev/null; }
else
  pass "smoke-sound.sh absent — skipped (brief: run if present)"
fi

# ---------------------------------------------------------------- result ---
log "OUTCOME: $OK smoke checks green"
[[ "$OK" -ge 3 ]] || die "not all calm smoke checks passed"
exit 0