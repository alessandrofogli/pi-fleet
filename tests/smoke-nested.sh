#!/usr/bin/env bash
#
# pi-fleet · T-013 nested-launch smoke test
#
# Exercises the NESTED LAUNCH gate logic of the extension IN-PROCESS (mocked
# ExtensionAPI) — the only faithful way to verify the new gate without
# reinstalling the extension globally (out of scope for the ticket delivery).
#
# Coverage (acceptance criteria of T-013):
#   S1 captain            → fleet tools work exactly as before (zero regression),
#                          nested:true is persisted in the task state
#   S2 child w/o nested   → fleet tools explicitly BLOCKED with clear message
#   S3 child with nested  → can fleet_launch (depth inherited +1, parentTaskId),
#                          fleet_status/steer/abort/peek scoped to its subtree;
#                          captain-only tools blocked
#   S4 depth > max        → launch DENIED with clear message (default max 2)
#   S5 postures.json cfg  → $config.nestedMaxDepth honored (custom cap)
#   S6 watcher in child   → fleet_notice wake delivered to the child session for
#                          its own subtree + GROUP DIGEST (barrier wave) delivered
#                          with the child's groupId; sibling tasks do NOT wake it
#
# Isolation: FLEET_STATE_HOME per scenario points to /tmp/fleet-nested-state-*;
# the launcher binary is MOCKED (.tmp/smoke-out/bin/herdr-launch.sh) so no real
# herdr pane / pi child is spawned. Real fleet (~/.pi/fleet) is never touched.
#
# Usage:
#   bash tests/smoke-nested.sh
#
# Exit codes:
#   0  green — all scenarios passed
#   1  failed — a check or the compilation failed
#   2  missing prerequisites (npx/node)
#
# Environment (optional):
#   SMOKE_KEEP=1   do NOT remove scratch/state at the end (debug)
#
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$REPO_ROOT"   # relative tsc -p needs a stable cwd for a deterministic emit layout
TS="$(date +%s)"
STATE_ROOT="/tmp/fleet-nested-state-$TS"
WORKTREE_FAKE="/tmp/fleet-nested-wt-$TS"          # fake child cwd (≠ $HOME)
SCRATCH_PROJ="/tmp/fleet-nested-proj-$TS"         # fake project for launches
OUT_DIR="$REPO_ROOT/.tmp/smoke-out"               # compiled extension (gitignored)
KEEP="${SMOKE_KEEP:-0}"

log()  { printf 'SMOKE [%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf 'SMOKE FAIL: %s\n' "$*" >&2; exit 1; }
die2() { printf 'SMOKE SKIP (exit 2): %s\n' "$*" >&2; exit 2; }
step() { printf '\n════ SMOKE %s ════\n' "$*"; }

cleanup() {
  [[ "$KEEP" == "1" ]] && { log "cleanup: SMOKE_KEEP=1, keeping /tmp/fleet-nested-* and $OUT_DIR"; return 0; }
  rm -rf "$STATE_ROOT" "$WORKTREE_FAKE" "$SCRATCH_PROJ" "$OUT_DIR"
}
trap cleanup EXIT

# ---------------------------------------------------------------- [0] preflight
log "[0/6] preflight: node/npx/jq/git, isolated fixtures"
command -v node >/dev/null 2>&1 || die2 "node not found in PATH"
command -v npx >/dev/null 2>&1 || die2 "npx not found in PATH (npm install)"
command -v jq  >/dev/null 2>&1 || die2 "jq not found in PATH (brew install jq)"
command -v git >/dev/null 2>&1 || die2 "git not found in PATH"

mkdir -p "$STATE_ROOT" "$WORKTREE_FAKE" "$SCRATCH_PROJ" "$OUT_DIR/bin"
( cd "$SCRATCH_PROJ" \
    && git init -q \
    && git config user.name "fleet-smoke" \
    && git config user.email "fleet-smoke@localhost" \
    && printf '# nested smoke scratch\n' > README.md \
    && git add README.md \
    && git commit -qm "init nested smoke" ) \
  || die "scratch repo creation failed: $SCRATCH_PROJ"
log "fixtures: fake worktree $WORKTREE_FAKE · project $SCRATCH_PROJ"

# --------------------------------------------------------- [1/6] compile (noEmit off)
log "[1/6] tsc compile of the extension to $OUT_DIR (noEmit off, temp tsconfig)"
# "extends" requires a RELATIVE path (TS forbids absolute) — compute it from $OUT_DIR
REL_TS="$(node -e "const p=require('path');process.stdout.write(p.relative(process.argv[1],process.argv[2])||'.')" "$OUT_DIR" "$REPO_ROOT/tsconfig.json")"
REL_EXT="$(node -e "const p=require('path');process.stdout.write(p.relative(process.argv[1],process.argv[2])||'.')" "$OUT_DIR" "$REPO_ROOT/extensions")"
cat > "$OUT_DIR/tsconfig.json" <<EOF
{
  "extends": "$REL_TS",
  "compilerOptions": {
    "noEmit": false,
    "outDir": ".",
    "rootDir": "../.."
  },
  "include": ["$REL_EXT/**/*.ts"]
}
EOF
npx tsc -p ".tmp/smoke-out/tsconfig.json" 2>&1 | tail -5
[[ ${PIPESTATUS[0]} -eq 0 ]] || die "tsc compile of the extension failed"
[[ -f "$OUT_DIR/extensions/index.js" ]] || die "compiled extensions/index.js missing"
log "compiled ok"

# Mocked launcher: records argv to SMOKE_LAUNCH_LOG, never spawns herdr. Must sit at
# join(EXT_DIR, "..", "bin", "herdr-launch.sh") = $OUT_DIR/bin/herdr-launch.sh.
cat > "$OUT_DIR/bin/herdr-launch.sh" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${SMOKE_LAUNCH_LOG:-}" ]]; then
  printf '%s\n' "$@" > "$SMOKE_LAUNCH_LOG"
fi
echo "mocked-launcher"
exit 0
EOF
chmod +x "$OUT_DIR/bin/herdr-launch.sh"

# ------------------------------------------------- [2/6] node harness written
log "[2/6] write the in-process harness (mocked ExtensionAPI)"
cat > "$OUT_DIR/harness.mjs" <<'HARNESS_EOF'
// T-013 nested-launch in-process harness — mocked ExtensionAPI.
import { readFileSync, writeFileSync, existsSync, readdirSync, mkdirSync } from "node:fs";
import { join } from "node:path";

const OUT = process.env.SMOKE_OUT;
const SCENARIO = process.env.SMOKE_SCENARIO;
const STATE = process.env.FLEET_STATE_HOME;
const PROJ = process.env.SMOKE_PROJ;
let failures = 0;

function check(name, cond, extra = "") {
  if (cond) console.log(` OK  ${name}${extra ? ` — ${extra}` : ""}`);
  else { failures++; console.log(`FAIL ${name}${extra ? ` — ${extra}` : ""}`); }
}

// ---- minimal ExtensionAPI mock
const pi = {
  tools: new Map(),
  messages: [],
  hooks: new Map(),
  registerTool(t) { this.tools.set(t.name, t); },
  sendMessage(msg, opts) { this.messages.push({ msg, opts }); },
  on(ev, cb) { if (!this.hooks.has(ev)) this.hooks.set(ev, []); this.hooks.get(ev).push(cb); },
};

const mod = await import(`file://${join(OUT, "extensions/index.js")}`);
mod.default(pi);
await new Promise((r) => setTimeout(r, 150)); // let the lazy imports settle

const readTask = (id) => {
  const p = join(STATE, `${id}.json`);
  if (!existsSync(p)) return null;
  try { return JSON.parse(readFileSync(p, "utf8")); } catch { return null; }
};
const writeTask = (t) => writeFileSync(join(STATE, `${t.id}.json`), JSON.stringify(t) + "\n");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const slug = (t) => t.replace(/[^a-z0-9_-]/gi, "-").slice(0, 24);
const launchLog = (title) => {
  const p = join(STATE, `launch-${slug(title)}.log`);
  return existsSync(p) ? readFileSync(p, "utf8").trim() : "";
};
const launch = async (title, overrides = {}) => {
  process.env.SMOKE_LAUNCH_LOG = join(STATE, `launch-${slug(title)}.log`);
  const t = pi.tools.get("fleet_launch");
  const r = await t.execute("t", { title, brief: "b", project: PROJ, ...overrides }, undefined, undefined, { model: { id: "m", provider: "p" } });
  await sleep(400); // let the (mocked, detached) launcher record its argv
  return r;
};
const contentText = (r) => Array.isArray(r?.content) && r.content[0]?.type === "text" ? r.content[0].text : "";

switch (SCENARIO) {
  // ─────────────────────────────── S1 captain ───────────────────────────────
  case "S1": {
    check("captain: fleet_launch registered", pi.tools.has("fleet_launch"));
    check("captain: fleet_status registered", pi.tools.has("fleet_status"));

    let res = await launch("cap-nested", { nested: true });
    check("captain: launch allowed (not rejected)", !(res?.details && res.details.state === "rejected"), res?.details?.state);
    const t1 = readTask(res.details.taskId);
    check("captain: state persisted with nested:true", t1?.nested === true);
    check("captain: state depth = 1", t1?.depth === 1);
    check("captain: no parentTaskId", t1?.parentTaskId === undefined || t1?.parentTaskId === "");
    const l1 = launchLog("cap-nested");
    check("captain: launcher got --nested + --depth 1", l1.includes("--nested") && /--depth\s*1/.test(l1), l1.replace(/\n/g, " ").slice(0, 150));

    res = await launch("cap-plain"); // no nested param
    const t2 = readTask(res.details.taskId);
    check("captain: plain launch still works (zero regression), nested:false", t2?.nested === false && res.details.state === "spawning");

    res = await pi.tools.get("fleet_status").execute("t", {});
    check("captain: fleet_status not blocked", !(res?.details && res.details.blocked === true));
    break;
  }

  // ─────────────────────────────── S2 mute child ────────────────────────────
  case "S2": {
    writeTask({ id: "child-mute", title: "mute", state: "running", nested: false, depth: 1, parentTaskId: "root" });
    const res = await launch("attempt");
    const text = contentText(res);
    check("mute: fleet_launch DENIED", res?.details?.state === "rejected", res?.details?.state);
    check("mute: clear message (mentions nested:true)", /nested:true/.test(text), text.slice(0, 180));
    check("mute: no state file written for the denied launch", !existsSync(join(STATE, "attempt.json")));

    const st = await pi.tools.get("fleet_status").execute("t", {});
    check("mute: fleet_status blocked", st?.details?.blocked === true);
    const ab = await pi.tools.get("fleet_abort").execute("t", { id: "child-mute" });
    check("mute: fleet_abort blocked", ab?.details?.blocked === true);
    const bd = await pi.tools.get("fleet_bootstrap").execute("t", {});
    check("mute: fleet_bootstrap blocked", bd?.details?.blocked === true);
    break;
  }

  // ─────────────────────────────── S3 nested child ──────────────────────────
  case "S3": {
    writeTask({ id: "child-n", title: "orchestrator", state: "running", nested: true, depth: 1, parentTaskId: "root", groupId: "grp-child", groupSize: 1 });
    writeTask({ id: "sibling-x", title: "sibling", state: "running", nested: false, depth: 1, parentTaskId: "root" });

    let res = await launch("grandkid-leaf", { nested: false, groupId: "grp-gk" });
    const gk = readTask(res.details.taskId);
    const lLeaf = launchLog("grandkid-leaf");
    check("nested: launch allowed", res.details.state !== "rejected", res.details.state);
    check("nested: grandchild depth inherited +1 = 2", gk?.depth === 2);
    check("nested: grandchild parentTaskId = child-n", gk?.parentTaskId === "child-n");
    check("nested: grandchild nested:false (opt-in not propagated implicitly)", gk?.nested === false);
    check("nested: launcher got --depth 2 + --parent-task-id child-n (no --nested)",
      /--depth\s*2/.test(lLeaf) && /--parent-task-id\s*child-n/.test(lLeaf) && !lLeaf.includes("--nested"), lLeaf.replace(/\n/g, " ").slice(0, 150));

    res = await launch("grandkid-orch", { nested: true });
    const gk2 = readTask(res.details.taskId);
    check("nested: explicit nested:true propagated to the grandchild", gk2?.nested === true && gk2?.depth === 2);

    // scoped fleet_status
    const st = await pi.tools.get("fleet_status").execute("t", {});
    const ids = (st?.details?.tasks ?? []).map((t) => t.id);
    check("nested: fleet_status shows own subtree (grandkids)", ids.includes(gk.id) && ids.includes(gk2.id), ids.join(","));
    check("nested: fleet_status hides sibling (scope)", !ids.includes("sibling-x"), ids.join(","));
    check("nested: fleet_status lists the orchestrator itself", ids.includes("child-n"));

    // steer: own grandchild (inbox on disk), muted sibling
    const sr = await pi.tools.get("fleet_steer").execute("t", { id: gk.id, message: "go" });
    check("nested: steer own grandchild ok", sr?.details?.blocked !== true && sr?.details?.seq >= 1, JSON.stringify(sr?.details));
    check("nested: steer enqueued in the grandchild inbox", existsSync(join(STATE, `${gk.id}.inbox`, "1.json")));
    const srBad = await pi.tools.get("fleet_steer").execute("t", { id: "sibling-x", message: "no" });
    check("nested: steer sibling blocked (subtree scope)", srBad?.details?.blocked === true);

    // peek scoped
    const pk = await pi.tools.get("fleet_peek").execute("t", { id: "sibling-x" });
    check("nested: peek sibling blocked", pk?.details?.blocked === true);

    // abort own grandchild vs sibling
    const abGk = await pi.tools.get("fleet_abort").execute("t", { id: gk.id });
    check("nested: abort own grandchild ok", abGk?.details?.state === "aborted", abGk?.details?.state);
    const abSib = await pi.tools.get("fleet_abort").execute("t", { id: "sibling-x" });
    check("nested: abort sibling blocked", abSib?.details?.blocked === true);

    // captain-only tools blocked for nested children
    const bd = await pi.tools.get("fleet_bootstrap").execute("t", {});
    check("nested: fleet_bootstrap captain-only", bd?.details?.blocked === true);
    const ln = await pi.tools.get("fleet_learn").execute("t", { title: "t", fact: "f" });
    check("nested: fleet_learn captain-only", ln?.details?.blocked === true);
    const po = await pi.tools.get("fleet_posture").execute("t", { action: "get", project: PROJ });
    check("nested: fleet_posture get allowed", po?.details?.blocked !== true && po?.details?.ok === true);
    break;
  }

  // ─────────────────────────────── S4 depth cap ─────────────────────────────
  case "S4": {
    writeTask({ id: "child-d2", title: "depth2", state: "running", nested: true, depth: 2, parentTaskId: "child-d1" });
    const res = await launch("too-deep");
    const text = contentText(res);
    check("depth: DENIED at depth >= max(2)", res?.details?.state === "rejected", res?.details?.state);
    check("depth: clear message (depth limit reached)", /depth limit/.test(text), text.slice(0, 180));
    check("depth: no state file for the denied launch", !existsSync(join(STATE, "too-deep.json")));
    break;
  }

  // ─────────────────────────────── S5 custom cap ────────────────────────────
  case "S5": {
    mkdirSync(STATE, { recursive: true });
    writeFileSync(join(STATE, "postures.json"), JSON.stringify({ $config: { nestedMaxDepth: 1 } }, null, 2) + "\n");
    writeTask({ id: "child-c1", title: "cap1", state: "running", nested: true, depth: 1, parentTaskId: "root" });
    const res = await launch("over-cap");
    const text = contentText(res);
    check("cap: custom cap (1) honored — depth-1 child denied", res?.details?.state === "rejected", res?.details?.state);
    check("cap: message mentions max 1 (postures.json)", /max is 1/.test(text), text.slice(0, 180));
    // setPosture must PRESERVE $config
    const pmod = await import(`file://${join(OUT, "extensions/fleet-posture.js")}`);
    pmod.setPosture(PROJ, "yolo");
    const raw = JSON.parse(readFileSync(join(STATE, "postures.json"), "utf8"));
    check("cap: setPosture preserves $config", raw.$config?.nestedMaxDepth === 1);
    check("cap: getNestedMaxDepth honors the config file", pmod.getNestedMaxDepth() === 1);
    break;
  }

  // ─────────────── S6 scoped watcher: wake + group digest in child ──────────
  case "S6": {
    const grpId = "grp-wave-a1b2c3";
    // Synthetic tasks borrow THIS session's live pane id: the session_start
    // reconcile (zombie check) then sees them alive and leaves the states alone,
    // so the watcher observes exactly the transitions the scenario writes.
    const livePane = process.env.HERDR_PANE_ID || "w0:p0";
    writeTask({ id: "child-w", title: "wave", state: "running", paneId: livePane, nested: true, depth: 1, parentTaskId: "root" });
    // own grandkids: a group barrier wave (the child used groupId/groupLabel/
    // groupMode/groupFailPolicy at launch — the digest must land in the CHILD)
    writeTask({ id: "gk-a", title: "A", state: "running", paneId: livePane, nested: false, depth: 2, parentTaskId: "child-w", groupId: grpId, groupSize: 2, groupLabel: "WaveN", groupMode: "barrier", groupFailPolicy: "waitAll" });
    writeTask({ id: "gk-b", title: "B", state: "running", paneId: livePane, nested: false, depth: 2, parentTaskId: "child-w", groupId: grpId, groupSize: 2, groupLabel: "WaveN", groupMode: "barrier", groupFailPolicy: "waitAll" });
    // a single non-group grandchild and a SIBLING (must NOT wake the child)
    writeTask({ id: "gk-single", title: "S", state: "running", paneId: livePane, nested: false, depth: 2, parentTaskId: "child-w" });
    writeTask({ id: "sib-c", title: "C", state: "running", paneId: livePane, nested: false, depth: 1, parentTaskId: "root" });

    const sessionStarts = pi.hooks.get("session_start") ?? [];
    check("nested: session_start hook registered", sessionStarts.length >= 4);
    for (const h of sessionStarts) h();
    await sleep(2500); // let reconcile + watcher seed deterministically (POLL_MS = 3000)

    const waitPoll = async () => sleep(3600);

    // gk-a done → group barrier buffers (no message yet)
    writeTask({ ...readTask("gk-a"), state: "done" });
    await waitPoll();
    check("wave: first member done does NOT wake (barrier buffered)", pi.messages.length === 0, `messages=${pi.messages.length}`);

    // gk-single done → single wake delivered to the CHILD session
    writeTask({ ...readTask("gk-single"), state: "done" });
    await waitPoll();
    const wakeSingle = pi.messages.find((m) => m.msg.details?.fleetTaskId === "gk-single");
    check("wave: single grandchild done wakes the child session (fleet_notice)", !!wakeSingle && wakeSingle.msg.customType === "fleet_notice");

    // group complete → digest delivered to the CHILD session with the child's groupId
    writeTask({ ...readTask("gk-b"), state: "done" });
    await waitPoll();
    const digest = pi.messages.find((m) => m.msg.details?.groupId === grpId);
    check("wave: group digest delivered to the child session", !!digest,
      pi.messages.map((m) => m.msg.details?.groupId ?? m.msg.details?.fleetTaskId ?? "?").join(","));
    check("wave: digest carries the child's groupId + both members", digest?.msg.details?.groupId === grpId && digest?.msg.details?.results?.length === 2);

    // sibling done → NOT delivered to the child session (scoped watcher)
    const nBefore = pi.messages.length;
    writeTask({ ...readTask("sib-c"), state: "failed" });
    await waitPoll();
    check("wave: sibling failed does NOT wake the child session (scope)", pi.messages.length === nBefore, `messages=${pi.messages.length}->${nBefore}`);
    break;
  }

  default:
    console.error(`unknown scenario ${SCENARIO}`);
    process.exit(3);
}

console.log(failures === 0 ? `SCENARIO ${SCENARIO} GREEN` : `SCENARIO ${SCENARIO} RED (${failures} failures)`);
process.exit(failures === 0 ? 0 : 1);
HARNESS_EOF
log "harness written"

# ------------------------------------------------- [3/6] run the scenarios
VERDICT_DIR="$STATE_ROOT/verdicts"
mkdir -p "$VERDICT_DIR"

run_scenario() {
  local name="$1" state="$2" extra_env="$3"
  mkdir -p "$state"
  # extra_env is a bash snippet setting/exporting the scenario env vars
  (
    eval "$extra_env"
    cd "$WORKTREE_FAKE" \
      && env FLEET_STATE_HOME="$state" SMOKE_OUT="$OUT_DIR" SMOKE_SCENARIO="$name" \
           SMOKE_PROJ="$SCRATCH_PROJ" \
           node "$OUT_DIR/harness.mjs"
  ) 2>&1 | tee "$state/out.txt" | tail -1 > "$VERDICT_DIR/$name.txt"
}

log "[3/6] running scenarios S1..S6 (captain / mute / nested / caps / watcher)"

step "S1 — CAPTAIN (zero regression, nested opt-in persisted)"
run_scenario S1 "$STATE_ROOT/s1" "export PI_FLEET_CAPTAIN=1; unset FLEET_TASK_ID FLEET_DEPTH;"

step "S2 — MUTE CHILD (no nested opt-in → explicit denial)"
run_scenario S2 "$STATE_ROOT/s2" "unset PI_FLEET_CAPTAIN; export FLEET_TASK_ID=child-mute; unset FLEET_DEPTH;"

step "S3 — NESTED CHILD (depth 1: launch/status/steer/abort/peek scoped)"
run_scenario S3 "$STATE_ROOT/s3" "unset PI_FLEET_CAPTAIN; export FLEET_TASK_ID=child-n FLEET_DEPTH=1;"

step "S4 — DEPTH CAP (depth 2 ≥ max 2 → denied)"
run_scenario S4 "$STATE_ROOT/s4" "unset PI_FLEET_CAPTAIN; export FLEET_TASK_ID=child-d2 FLEET_DEPTH=2;"

step "S5 — postures.json CUSTOM CAP (\$config.nestedMaxDepth=1) + preservation"
run_scenario S5 "$STATE_ROOT/s5" "unset PI_FLEET_CAPTAIN; export FLEET_TASK_ID=child-c1 FLEET_DEPTH=1;"

step "S6 — SCOPED WATCHER in the child (fleet_notice wakes + group digest)"
run_scenario S6 "$STATE_ROOT/s6" "unset PI_FLEET_CAPTAIN; export FLEET_TASK_ID=child-w FLEET_DEPTH=1;"

# ------------------------------------------------- [4/6] verdicts
log "[4/6] verdicts:"
cat "$VERDICT_DIR"/S?.txt
GREEN=$(( $(cat "$VERDICT_DIR"/S?.txt | grep -c "GREEN" || true) ))
RED=$(( $(cat "$VERDICT_DIR"/S?.txt | grep -c "RED" || true) ))

# ----------------------------------------------------------- [6/6] outcome
log "[6/6] outcome"
if [[ "$RED" -gt 0 ]]; then
  die "$RED scenario(s) RED — see the FAIL lines above"
fi
if [[ "$GREEN" -ne 6 ]]; then
  die "expected 6 green scenarios, got $GREEN (a scenario crashed?)"
fi
log "OUTCOME: OK — T-013 nested-launch gate: captain regression-free, mute blocked, nested enabled + scoped, depth cap honored, watcher wake + group digest in the child session"
exit 0