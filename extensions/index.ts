/**
 * pi-fleet · Pi extension (M2)
 *
 * Wraps the CLI launcher (bin/herdr-launch.sh) in a Pi extension:
 *  - fleet_launch  : spawns a task as a SIDE-BY-SIDE HERDR PANE (split, not tab)
 *  - fleet_status  : lists tasks and states
 *  - fleet_peek    : reads the task pane output
 *  - fleet_steer   : writes into the child's prompt (e.g. answer to needs_input)
 *  - fleet_abort   : closes pane/tab + releases worktree + marks aborted
 *  - fleet_attach  : moves the herdr focus onto the task pane
 *  - fleet_learn   : records a dated operational learning in learnings.md (24h dedup)
 *  - fleet_captain_pref : get/set captain preferences in captain.md / captain-shared.md
 *  - in-process watcher: wakes the chat (sendMessage triggerTurn) when a
 *    task enters failed/needs_input (done tasks are silent, per F0 decisions)
 */

import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { existsSync, mkdirSync, openSync, readdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { mountFleetWatchArm } from "./fleet-watch-arm.js";
import type { GroupRecord, GroupTaskInfo } from "./fleet-group.js";
import type { InboxMsg } from "./fleet-inbox.js";
import type { CheckedTool, GroupSummaryLike } from "./fleet-bootstrap.js";
// L3.5 barrier — optional helpers lazy-loaded for fail soft
let _fleetGroup: typeof import("./fleet-group.js") | null = null;
async function getFleetGroup(): Promise<typeof import("./fleet-group.js") | null> {
  if (_fleetGroup) return _fleetGroup;
  try { _fleetGroup = await import("./fleet-group.js"); return _fleetGroup; } catch { return null; }
}
function getFleetGroupSync(): typeof import("./fleet-group.js") | null {
  return _fleetGroup;
}
// T-004 branch outcomes — optional helpers lazy-loaded, same pattern as getFleetGroup
let _fleetOutcomes: typeof import("./fleet-outcomes.js") | null = null;
async function getFleetOutcomes(): Promise<typeof import("./fleet-outcomes.js") | null> {
  if (_fleetOutcomes) return _fleetOutcomes;
  try { _fleetOutcomes = await import("./fleet-outcomes.js"); return _fleetOutcomes; } catch { return null; }
}
function getFleetOutcomesSync(): typeof import("./fleet-outcomes.js") | null {
  return _fleetOutcomes;
}
// T-003 — delivery posture: optional module lazy-loaded for fail soft
let _fleetPosture: typeof import("./fleet-posture.js") | null = null;
async function getFleetPosture(): Promise<typeof import("./fleet-posture.js") | null> {
  if (_fleetPosture) return _fleetPosture;
  try { _fleetPosture = await import("./fleet-posture.js"); return _fleetPosture; } catch { return null; }
}
// T-002 (5b.2) durable inbox — same lazy pattern as fleet-group (fail soft)
let _fleetInbox: typeof import("./fleet-inbox.js") | null = null;
async function getFleetInbox(): Promise<typeof import("./fleet-inbox.js") | null> {
  if (_fleetInbox) return _fleetInbox;
  try { _fleetInbox = await import("./fleet-inbox.js"); return _fleetInbox; } catch { return null; }
}
function getFleetInboxSync(): typeof import("./fleet-inbox.js") | null {
  return _fleetInbox;
}
// T-006 bootstrap — same lazy/fail soft pattern as getFleetGroup
let _fleetBootstrap: typeof import("./fleet-bootstrap.js") | null = null;
async function getFleetBootstrap(): Promise<typeof import("./fleet-bootstrap.js") | null> {
  if (_fleetBootstrap) return _fleetBootstrap;
  try { _fleetBootstrap = await import("./fleet-bootstrap.js"); return _fleetBootstrap; } catch { return null; }
}
function getFleetBootstrapSync(): typeof import("./fleet-bootstrap.js") | null {
  return _fleetBootstrap;
}
// 5b.5 learnings/prefs — lazy import like fleet-group (fail soft)
let _fleetLearn: typeof import("./fleet-learn.js") | null = null;
async function getFleetLearn(): Promise<typeof import("./fleet-learn.js") | null> {
  if (_fleetLearn) return _fleetLearn;
  try { _fleetLearn = await import("./fleet-learn.js"); return _fleetLearn; } catch { return null; }
}
function getFleetLearnSync(): typeof import("./fleet-learn.js") | null {
  return _fleetLearn;

}

const EXT_DIR = dirname(fileURLToPath(import.meta.url));
const LAUNCHER = join(EXT_DIR, "..", "bin", "herdr-launch.sh");
const STATE_HOME = process.env.FLEET_STATE_HOME ?? join(homedir(), ".pi", "fleet");
const TASKS_DIR = join(STATE_HOME, "tasks");
const WAKE_CHANNEL = "pi-fleet.wake.v1";
const POLL_MS = 3000;
// T-002 (5b.2): inbox re-ring — interval between replays and max before escalation
const RING_INTERVAL_MS = 60_000;
const RING_MAX_REPLAYS = 5;
// L3.5 batch window: all fleet_launch calls in the same LLM turn (<3s) share the same groupId
let lastGroupId: string | null = null;
let lastGroupTime = 0;
let lastGroupSize = 0;

const ACTIVE_STATES = new Set(["spawning", "running", "needs_input"]);

// ------------------------------------------------------------------ types ---
type TaskState = "spawning" | "running" | "done" | "failed" | "aborted" | "needs_input";

interface TaskStateFile {
  id: string;
  title?: string;
  project?: string;
  worktree?: boolean;
  cwd?: string;
  briefFile?: string;
  state: TaskState;
  startedAt?: number;
  lastBeatAt?: number;
  doneAt?: number | null;
  timeoutMs?: number;
  paneId?: string;
  tabId?: string;
  workspaceId?: string;
  summary?: string;
  changedFiles?: string[];
  groupId?: string;
  groupSize?: number;
  groupLabel?: string;
  groupMode?: "barrier" | "streaming";
  kind?: "ship" | "scout";
  reportPath?: string;
  deliveryPosture?: string;
  groupFailPolicy?: "waitAll" | "immediate";
  // T-011 mechanical gate: outcome of the launcher's anti-fraud verification
  gate?: { passed: boolean; rounds?: number; reportPath?: string };
  prUrl?: string;
}

function stateDir(): string {
  mkdirSync(STATE_HOME, { recursive: true });
  return STATE_HOME;
}

function parseTaskFile(name: string): TaskStateFile | null {
  if (!name.endsWith(".json") || name.endsWith(".done.json") || name.endsWith(".needs-input.json")) {
    return null;
  }
  try {
    const raw = readFileSync(join(STATE_HOME, name), "utf8");
    const data = JSON.parse(raw) as TaskStateFile;
    if (typeof data.id !== "string" || typeof data.state !== "string") return null;
    return data;
  } catch {
    // NEVER delete: if parsing fails, the file may be mid-write
    // (the launcher writes atomically, but the first M1 pass did not).
    // Rename it to .bad so it stays inspectable and a later poll can re-read.
    try { renameSync(join(STATE_HOME, name), join(STATE_HOME, name + ".bad")); } catch { /* ignore */ }
    return null;
  }
}

function listTasks(): TaskStateFile[] {
  stateDir();
  let names: string[] = [];
  try { names = readdirSync(STATE_HOME); } catch { return []; }
  return names
    .map(parseTaskFile)
    .filter((t): t is TaskStateFile => t !== null)
    .sort((a, b) => (b.startedAt ?? 0) - (a.startedAt ?? 0));
}

function readTask(id: string): TaskStateFile | null {
  return parseTaskFile(`${id}.json`);
}

function writeTask(task: TaskStateFile): void {
  writeFileSync(join(STATE_HOME, `${task.id}.json`), JSON.stringify(task, null, 2) + "\n");
}

/** Slug readable from the title: ascii, lowercase, max 30 chars (e.g. 'Model analysis' → 'model-analysis'). */
function slugify(s: string, max = 30): string {
  return s
    .toLowerCase()
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, max)
    .replace(/-+$/g, "");
}

/**
 * Resolve the task project. Accepts an absolute path, a ~/ path, or a short
 * name. Short names are resolved against FLEET_PROJECTS_DIR if set
 * (e.g. export FLEET_PROJECTS_DIR=~/projects). Otherwise an absolute path
 * is required — this keeps the plugin generic and not tied to any directory
 * layout. Example: project: "my-app" with FLEET_PROJECTS_DIR=~/code
 * resolves to ~/code/my-app.
 */
function resolveProject(raw: string): { ok: true; path: string } | { ok: false; error: string } {
  const expanded = raw.startsWith("~") ? join(homedir(), raw.slice(1)) : raw;
  if (expanded.startsWith("/")) {
    if (existsSync(expanded)) return { ok: true, path: expanded };
    return { ok: false, error: `Path not found: ${expanded}` };
  }
  const rootEnv = process.env.FLEET_PROJECTS_DIR;
  const roots: string[] = [];
  if (rootEnv) {
    roots.push(rootEnv.startsWith("~") ? join(homedir(), rootEnv.slice(1)) : rootEnv);
  } else {
    // Back-compat fallback for existing setups that used ~/Documents/GitHub.
    // New setups should set FLEET_PROJECTS_DIR explicitly (see README).
    const legacy = join(homedir(), "Documents", "GitHub");
    if (existsSync(legacy)) roots.push(legacy);
  }
  if (roots.length > 0) {
    for (const root of roots) {
      const candidate = join(root, raw);
      if (existsSync(candidate)) return { ok: true, path: candidate };
    }
    const root = roots[0];
    let available = "";
    try {
      available = readdirSync(root)
        .filter((d) => { try { return statSync(join(root, d)).isDirectory(); } catch { return false; } })
        .slice(0, 15)
        .join(", ");
    } catch { /* ignore */ }
    return {
      ok: false,
      error: `Project '${raw}' not found in ${root}. Available: ${available || "(empty)"} — use an absolute path or set FLEET_PROJECTS_DIR (e.g. export FLEET_PROJECTS_DIR=~/projects).`,
    };
  }
  return {
    ok: false,
    error: `Project '${raw}' requires an absolute path (e.g. /home/user/projects/${raw}) or set FLEET_PROJECTS_DIR to enable short-name lookup (e.g. export FLEET_PROJECTS_DIR=~/projects).`,
  };
}

function runHerdr(args: string[], timeoutMs = 20_000): Promise<{ ok: boolean; out: string }> {
  return new Promise((resolve) => {
    const session = process.env.HERDR_SESSION ?? "default";
    const child = spawn("herdr", ["--session", session, ...args], { stdio: ["ignore", "pipe", "pipe"] });
    let out = "";
    let err = "";
    const timer = setTimeout(() => child.kill("SIGKILL"), timeoutMs);
    child.stdout.on("data", (d: Buffer) => { out += d.toString(); });
    child.stderr.on("data", (d: Buffer) => { err += d.toString(); });
    child.on("close", (code) => {
      clearTimeout(timer);
      resolve({ ok: code === 0, out: out.trim() || err.trim() });
    });
    child.on("error", (e) => {
      clearTimeout(timer);
      resolve({ ok: false, out: String(e) });
    });
  });
}

// ------------------------------------------------------------- launcher ----
interface FleetLaunchParams {
  title: string;
  brief: string;
  project: string;
  worktree?: boolean;
  model?: string;
  timeoutMin?: number;
  session?: string;
  groupId?: string;
  groupLabel?: string;
  groupMode?: "barrier" | "streaming";
  kind?: "ship" | "scout";
  deliveryPosture?: string;
  groupFailPolicy?: "waitAll" | "immediate";
  // T-011 gate: active only when posture is no-mistakes AND gate.yaml exists in the project
  gate?: boolean;
  autoPr?: boolean;
}

function spawnLauncher(taskId: string, title: string, briefPath: string, params: FleetLaunchParams): { ok: boolean; error?: string; logPath?: string } {
  const args = [LAUNCHER, title, `@${briefPath}`, "--task-id", taskId, "--project", params.project];
  if (params.worktree === false) args.push("--no-worktree");
  if (params.model) args.push("--model", params.model);
  if (params.timeoutMin) args.push("--timeout-min", String(params.timeoutMin));
  if (params.session) args.push("--session", params.session);
  // L3.5: pass the group to the bash launcher
  const gid = (params as FleetLaunchParams & { effectiveGroupId?: string }).effectiveGroupId ?? params.groupId;
  if (gid) args.push("--group-id", gid);
  if (params.groupLabel) args.push("--group-label", params.groupLabel);
  if (params.groupMode) args.push("--group-mode", params.groupMode);
  // scout: report only (report.md) — no commit/PR on the child side
  if (params.kind === "scout") args.push("--kind", "scout");
  // T-003: task delivery posture (default no-mistakes, already resolved in execute)
  if (params.deliveryPosture) args.push("--delivery-posture", params.deliveryPosture);
  if (params.groupFailPolicy) args.push("--group-fail-policy", params.groupFailPolicy);
  // T-011: gate meccanico (solo no-mistakes + gate.yaml, risolto in execute) + autoPr da gate.yaml
  if (params.gate) args.push("--gate");
  if (params.gate && params.autoPr !== undefined) args.push("--auto-pr", params.autoPr ? "true" : "false");

  const logPath = join(STATE_HOME, `${taskId}.log`);
  try {
    const logFd = openSync(logPath, "a");
    const child: ChildProcess = spawn("bash", ["-c", `exec "$@"`, "pi-fleet-launcher", ...args], {
      cwd: homedir(),
      stdio: ["ignore", logFd, logFd],
      detached: true,
    });
    child.unref();
    return { ok: true, logPath };
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : String(e) };
  }
}

// ------------------------------------------------------------ wake/report ----
function shortGroupId(gid: string): string {
  return gid.replace(/^grp-/, "").slice(0, 8);
}
const TERMINAL_STATES_WAKE = new Set<TaskState>(["done", "failed", "aborted"]);
function isTerminalStateWake(s: string): boolean { return TERMINAL_STATES_WAKE.has(s as TaskState); }
function formatTaskLine(t: TaskStateFile, groupCounts?: Map<string, { done: number; total: number }>): string {
  const dur = t.startedAt ? ` (${Math.round((Date.now() - t.startedAt) / 1000)}s fa)` : "";
  const sum = t.summary && t.state !== "running" && t.state !== "spawning"
    ? ` — ${t.summary.length > 140 ? t.summary.slice(0, 137) + "…" : t.summary}`
    : "";
  let grp = "";
  if (t.groupId && (t.groupSize ?? 1) > 1) {
    const c = groupCounts?.get(t.groupId);
    const pol = t.groupFailPolicy === "immediate" ? " fail:immediate" : "";
    if (c) grp = ` (grp:${shortGroupId(t.groupId)} ${c.done}/${c.total}${pol})`;
    else grp = ` (grp:${shortGroupId(t.groupId)} ${t.groupSize}${pol})`;
  } else if (t.groupId && t.groupLabel) {
    grp = ` (grp:${shortGroupId(t.groupId)})`;
  }
  let inbox = "";
  try {
    const mod = getFleetInboxSync();
    if (mod && typeof mod.listPending === "function") {
      const n = mod.listPending(STATE_HOME, t.id).length;
      if (n > 0) inbox = ` (inbox: ${n})`;
    }
  } catch { /* fail soft */ }
  // T-011: gate outcome (launcher anti-fraud verification) and automatic PR
  let gateS = "";
  if (t.gate) gateS = t.gate.passed ? " (gate:✓)" : " (gate:✗)";
  let prS = "";
  if (t.prUrl && t.state === "done") {
    const prNum = t.prUrl.match(/\/pull\/(\d+)/)?.[1];
    prS = prNum ? ` (pr:#${prNum})` : ` (pr:${t.prUrl.length > 60 ? t.prUrl.slice(0, 57) + "…" : t.prUrl})`;
  }
  return `- **${t.title ?? t.id}** [${t.state}]${inbox}${grp}${gateS}${prS}${dur}${sum} — ${t.project ?? ""}`;
}

function sendGroupDigest(pi: ExtensionAPI, groupId: string, results: GroupTaskInfo[]): void {
  // SILENT (display:false): the user must not see the raw fleet.
  // Content = directive for the main: read the reports on disk and synthesize.
  const ids = results.map((r) => r.id).join(", ");
  const dir = STATE_HOME;
  const content = `[silent fleet-notice] Task group completed (${results.length} tasks): ${ids}.\n` +
    `Do not show this message. Read the files ${dir}/<id>.json of these tasks for the reports and produce ` +
    `YOUR OWN concise summary for the user (key points, important files, status). No raw dump of the reports.`;
  pi.sendMessage(
    { customType: "fleet_notice", content, display: false, details: { groupId, results } },
    { triggerTurn: true, deliverAs: "followUp" },
  );
}
function fallbackDigest(groupId: string, results: GroupTaskInfo[]): string {
  const list = results.map((r) => `- ${r.title ?? r.id} [${r.state}]`).join("\n");
  return `⚑ pi-fleet — group ${groupId} complete (${results.length}/${results.length})\n${list}\n\nProvide a concise summary for the group.`;
}

function sendWake(pi: ExtensionAPI, task: TaskStateFile, overrides?: { detail?: string }): void {
  let what: string;
  let detail: string;
  if (task.state === "done") {
    what = "finished";
    const sum = (task.summary ?? "").trim();
    const files = task.changedFiles?.length
      ? `\nChanged files: ${task.changedFiles.map((f) => "`" + f + "`").join(", ")}`
      : "";
    // FULL report: for audit/code review the long summary is the deliverable.
    // The old "wall of text" was duplication (full + formatTaskLine line +
    // main re-print), not length — here no duplicates nor truncations.
    detail = `Result:\n${sum || "(no summary)"}${files}`;
  } else if (task.state === "needs_input") {
    what = "needs your input";
    detail = "(input requested — reply with fleet_steer, close with fleet_abort)";
  } else {
    what = "FAILED";
    const reason = (task.summary ?? "").trim();
    detail = reason ? `Reason: ${reason}` : "Use fleet_status / fleet_peek to investigate.";
  }
  // optional override: the watcher (e.g. group_failed_immediate) can replace the
  // detail with the group context without duplicating the sending logic
  if (overrides?.detail !== undefined) detail = overrides.detail;
  const content = `⚑ pi-fleet — task **${task.title ?? task.id}** ${what} (${task.id}).\n${detail}`;
  // SILENT: the user does not see the raw fleet. display:false + (triggerTurn for
  // failed/needs_input; for done a group digest suffices — if a single done,
  // wake anyway because the main must synthesize). The content is a directive.
  const silent = `[silent fleet-notice] ${content}\nDo not show this message. Synthesize it yourself for the user.`;
  const triggerTurn = true;
  pi.sendMessage(
    {
      customType: "fleet_notice",
      content: silent,
      display: false,
      details: { fleetTaskId: task.id, state: task.state },
    },
    { triggerTurn, deliverAs: "followUp" },
  );
}

// T-002 (5b.2): ATTENTION wake for inbox escalation. Separate helper from
// sendWake (a parallel task adds an optional param to sendWake: the merge
// is done by the captain, here sendWake's body is NOT touched). Same pattern
// pi.sendMessage/customType fleet_notice + triggerTurn.
function sendAttention(pi: ExtensionAPI, task: TaskStateFile, subject: string): void {
  const content = `⚑ pi-fleet — task **${task.title ?? task.id}** (${task.id}): ${subject}`;
  // SILENT: the user does not see the raw fleet; the content is a directive for the main.
  const silent = `[silent fleet-notice] ${content}\nDo not show this message. Synthesize it yourself for the user.`;
  pi.sendMessage(
    {
      customType: "fleet_notice",
      content: silent,
      display: false,
      details: { fleetTaskId: task.id, state: task.state, kind: "inbox_escalation" },
    },
    { triggerTurn: true, deliverAs: "followUp" },
  );
}

// ------------------------------------------------------------- watcher ----
/**
 * Reconcile at startup: active tasks (running/needs_input/spawning) whose herdr
 * pane no longer exists are zombies (restart, crash, pilot closed the tab).
 * If the done-marker exists → done, otherwise failed. Avoids phantom wakes.
 */
async function reconcileStaleTasks(): Promise<void> {
  const tasks = listTasks().filter((t) => ACTIVE_STATES.has(t.state));
  if (tasks.length === 0) return;
  const res = await runHerdr(["agent", "list"], 10_000);
  if (!res.ok) return;
  let panes = new Set<string>();
  try {
    const parsed = JSON.parse(res.out) as { result?: { agents?: Array<{ pane_id?: string }> } };
    panes = new Set((parsed.result?.agents ?? []).map((a) => a.pane_id ?? ""));
  } catch {
    return;
  }
  for (const t of tasks) {
    if (t.paneId && panes.has(t.paneId)) continue;
    const donePath = join(STATE_HOME, `${t.id}.done.json`);
    let state: TaskState = "failed";
    if (existsSync(donePath)) {
      state = "done";
      try { rmSync(donePath); } catch { /* ignore */ }
    } else if (existsSync(join(STATE_HOME, `${t.id}.abort`))) {
      state = "aborted";
    }
    if (state !== t.state) {
      t.state = state;
      t.doneAt = Date.now();
      writeTask(t);
      // T-004: audit trail branch-outcomes (best-effort, non blocca il reconcile)
      try { getFleetOutcomesSync()?.appendOutcome(STATE_HOME, t); } catch { /* best-effort */ }
    }
  }
}

// L3.5 barrier: mappa gruppi a livello modulo (condivisa tra rebuild e watcher)
const groupMap: Map<string, GroupRecord> = new Map();
// preload barrier module async (best-effort, sync fallback uses fallbackDigest)
void getFleetGroup().catch(() => {});
// T-004: preload the outcomes module (async, best-effort) so the sync getter is ready in the watcher
void getFleetOutcomes().catch(() => {});
// T-002 (5b.2): inbox re-ring attivi per task (guard anti-duplicati: taskId → stop())
const reRingInFlight = new Map<string, () => void>();
void getFleetInbox().catch(() => {});

function startWatcher(pi: ExtensionAPI, watch: Map<string, TaskState>): () => void {
  // Seed: states ALREADY present at startup must not wake (no
  // phantom notifications for tasks finished before the watcher started).
  for (const task of listTasks()) watch.set(task.id, task.state);
  // L3.5: load groups from disk if the module is available (sync path)
  try {
    const mod = getFleetGroupSync();
    if (mod) {
      const rebuilt = mod.rebuildGroupsFromDisk(STATE_HOME, listTasks());
      for (const [k, v] of rebuilt) groupMap.set(k, v);
    }
  } catch { /* fail soft */ }

  const timer = setInterval(() => {
    for (const task of listTasks()) {
      const prev = watch.get(task.id);
      const isTerminal = task.state === "failed" || task.state === "needs_input" || task.state === "done";
      if (prev !== task.state && isTerminal) {
        // T-004: audit trail branch-outcomes — BEFORE the group/wake logic.
        // Best-effort: the registry must never break the wake.
        try { getFleetOutcomesSync()?.appendOutcome(STATE_HOME, task); } catch { /* best-effort */ }
        // L3.5 barrier logic — groupSize on disk is a placeholder (1), it is derived
        // from the REAL COUNT of tasks sharing the same groupId.
        const mod = getFleetGroupSync();
        let realGroupSize = task.groupSize ?? 1;
        if (task.groupId) {
          try {
            realGroupSize = listTasks().filter((t) => (t.groupId ?? "") === task.groupId).length;
          } catch { /* fail soft */ }
        }
        if (realGroupSize < 1) realGroupSize = 1;
        const hasGroup = !!(task.groupId && realGroupSize > 1 && (task.groupMode ?? "barrier") === "barrier");
        if (mod && hasGroup) {
          // align groupSize so recordTaskDone uses the real expected (not the placeholder)
          task.groupSize = realGroupSize;
          try {
            if (task.state === "needs_input") {
              // needs_input breaks the barrier: immediate wake + record for consistency
              try { mod.recordTaskDone(STATE_HOME, groupMap, task); } catch { /* ignore */ }
              watch.set(task.id, task.state);
              sendWake(pi, task);
            } else {
              const ev = mod.recordTaskDone(STATE_HOME, groupMap, task);
              if (ev.kind === "buffered") {
                watch.set(task.id, task.state);
                // non svegliare, solo aggiorna watch.set
              } else if (ev.kind === "group_complete") {
                watch.set(task.id, task.state);
                sendGroupDigest(pi, ev.groupId, ev.results);
              } else if (ev.kind === "needs_input") {
                watch.set(task.id, task.state);
                sendWake(pi, task);
              } else if (ev.kind === "group_failed_immediate") {
                // immediate policy: failed in group → wake NOW with group context
                watch.set(task.id, task.state);
                const done = ev.group.results.size;
                const pending = ev.group.pending.size;
                const lbl = ev.group.label ? ` "${ev.group.label}"` : "";
                const reason = (task.summary ?? "").trim();
                const mot = reason ? `Reason: ${reason}` : "Use fleet_status / fleet_peek to investigate.";
                sendWake(pi, task, {
                  detail: `Group ${shortGroupId(ev.group.groupId)}${lbl} (immediate policy): ${done} done, ${pending} pending.\n${mot}`,
                });
              }
            }
          } catch {
            watch.set(task.id, task.state);
            sendWake(pi, task);
          }
        } else {
          // single or streaming or module unavailable → immediate wake
          watch.set(task.id, task.state);
          sendWake(pi, task);
        }
      } else {
        watch.set(task.id, task.state);
      }
    }
    // T-002 (5b.2): inbox re-ring — for active tasks (running/needs_input) with
    // pending un-acked messages start the reRing (one timer per task, guarded by
    // reRingInFlight to avoid duplicates). Escalation → wake the captain.
    try {
      const mod = getFleetInboxSync();
      if (mod) {
        for (const task of listTasks()) {
          if (task.state !== "running" && task.state !== "needs_input") continue;
          const pending = mod.listPending(STATE_HOME, task.id);
          const needsRing = pending.some(
            (m) => !m.fireAndForget && (m.replays ?? 0) < RING_MAX_REPLAYS,
          );
          if (needsRing && !reRingInFlight.has(task.id)) {
            const stop = mod.reRing({
              stateHome: STATE_HOME,
              taskId: task.id,
              intervalMs: RING_INTERVAL_MS,
              maxReplays: RING_MAX_REPLAYS,
              deliver: (msg: InboxMsg) => {
                const t = readTask(task.id);
                if (!t?.paneId || isTerminalStateWake(t.state)) return false;
                const paneId = t.paneId;
                const send = async (message: string): Promise<boolean> => {
                  const res = await runHerdr(["agent", "prompt", paneId, message], 15_000);
                  return res.ok;
                };
                // il deliver del modulo registra replays++/lastReplayAt su disco
                return mod.deliver(STATE_HOME, task.id, msg.seq, send);
              },
              onEscalation: (tid, msg) => {
                sendAttention(pi, task, `task ${tid} did not ack message #${msg.seq} after ${msg.replays} attempts`);
              },
              onIdle: (tid) => { reRingInFlight.delete(tid); },
            });
            reRingInFlight.set(task.id, stop);
          }
        }
        // stop the reRings of tasks no longer active (done/failed/aborted) or gone
        for (const [id, stop] of reRingInFlight) {
          const t = readTask(id);
          if (!t || (t.state !== "running" && t.state !== "needs_input")) {
            try { stop(); } catch { /* ignore */ }
            reRingInFlight.delete(id);
          }
        }
      }
    } catch { /* fail soft */ }
    for (const id of [...watch.keys()]) {
      if (!existsSync(join(STATE_HOME, `${id}.json`))) watch.delete(id);
    }
  }, POLL_MS);
  return () => clearInterval(timer);
}

// ----------------------------------------------------- background-work ----
let providerUnregister: (() => void) | null = null;

interface BackgroundWorkProviderShape {
  name: string;
  listActiveWork(): readonly { id: string; sessionId: string }[];
  wakeChannels?: readonly string[];
  reconcile?(context: { sessionId: string; nowMs: number }): void;
}

// ---------------------------------------------------------------- tools ----
// The "subagents" are not child processes: they are INDEPENDENT pi sessions in the
// herdr pane, coordinated via the shared files in ~/.pi/fleet. They all load this
// extension → the watcher/fleet_notice dispatch MUST only fire in the captain
// (cwd = HOME, AGENTS.md policy). In children the extension stays mute: no
// watcher, no reconcile, only the consultation tools.
const IS_CAPTAIN: boolean =
  process.env.PI_FLEET_CHILD === "1"
    ? false
    : process.env.PI_FLEET_CAPTAIN === "1" || process.cwd() === homedir();

export default function piFleetExtension(pi: ExtensionAPI): void {
  stateDir();
  mkdirSync(TASKS_DIR, { recursive: true });

  // --- fleet_launch ---
  pi.registerTool({
    name: "fleet_launch",
    label: "Fleet Launch",
    description:
      "Spawns a VISIBLE sub-agent: runs it in a dedicated herdr 'fleet' workspace (tab --no-focus) with pi inside (same model as the main session), in an isolated treehouse worktree, hands it the brief and frees the chat. The child does NOT steal focus and takes no space in the captain's tab: it is visible ONLY in herdr's agents sidebar on the left (until you open it). At task end the report arrives in the chat (success without interruption; failed/needs_input wake the main agent in the turn).",
    promptSnippet: "Spawn a background herdr sub-agent (agents-sidebar only) for a delegation task",
    promptGuidelines: [
      "AUTOMATICALLY call fleet_launch for ANY non-trivial request about a project: reading/analyzing, editing, implementing, fixing, testing, refactoring. Do NOT wait for the user to type fleet_launch and do NOT ask for confirmation — delegation is the default. Handle inline ONLY questions answerable from context, fleet management, and trivial one-liners.",
      "project is REQUIRED (absolute path, ~/path, or short name if FLEET_PROJECTS_DIR is set): derive it from the user's message or the last task's project; ask one short question only if truly ambiguous. Never launch without project. Keep worktree enabled.",
      "For multiple independent requests, launch them in PARALLEL (max 5 per turn) instead of sequentially.",
      "CRITICAL: After fleet_launch returns, STOP IMMEDIATELY and END YOUR TURN. Do NOT call fleet_status, fleet_peek, fleet_watch_arm_pi, or any other fleet tool to check progress. The task runs detached in background - you will be WOKEN automatically via fleet_notice when it finishes (done=silent followUp, failed/needs_input=triggerTurn). Polling wastes context and blocks the session. Your turn is OVER after launch.",
      "When you receive a fleet_notice group complete (e.g. \"⚑ pi-fleet — group ... complete\"), IMMEDIATELY produce a concise synthesis per group: key findings, important files, status per task. Do NOT just echo the raw fleet list — synthesize into a clear summary for the user. This synthesis is the ONLY verbose output the user should see for the group; the raw fleet list is just the trigger.",
    ],
    parameters: Type.Object({
      title: Type.String({ description: "Short task title" }),
      brief: Type.String({ description: "Complete task instructions (markdown)" }),
      project: Type.String({ description: "Project: absolute path (e.g. /home/user/projects/my-app or ~/projects/my-app) or short name if FLEET_PROJECTS_DIR is set. REQUIRED." }),
      worktree: Type.Optional(Type.Boolean({ description: "Use an isolated treehouse worktree (default: true)" })),
      model: Type.Optional(Type.String({ description: "Model override, e.g. 'opencode-go/deepseek-v4-flash' (default: parent session model)" })),
      timeoutMin: Type.Optional(Type.Number({ description: "Timeout in minutes (default: 360)" })),
      groupId: Type.Optional(Type.String({ description: "Group id for barrier digest (e.g. grp-20260828-a1b2c3). Auto-generated via batch window if omitted." })),
      groupLabel: Type.Optional(Type.String({ description: "Optional label for the group (shown in digest)" })),
      groupMode: Type.Optional(Type.String({ description: "Group mode: barrier (wait all) or streaming (per-task). Default barrier." })),
      kind: Type.Optional(Type.Union([Type.Literal("ship"), Type.Literal("scout")], { description: "Task kind: ship (default) or scout (report only, no commit/PR)" })),
      deliveryPosture: Type.Optional(Type.String({ description: "Task delivery posture (no-mistakes|direct-PR|local-only|yolo). Default: from postures.json config or no-mistakes." })),
      groupFailPolicy: Type.Optional(Type.String({ description: "waitAll (default) | immediate: a failed group task wakes the captain immediately" })),
    }),
    // L3.5: if you launch N in parallel in the same turn, reuse the same groupId (auto-batch)
    // The guideline helps the model pass an explicit groupId if it wants separate groups.

    async execute(_toolCallId: string, params: FleetLaunchParams, _signal?: unknown, _onUpdate?: unknown, ctx?: { model?: { id?: string; provider?: string } }) {
      const resolved = resolveProject(params.project);
      if (!resolved.ok) {
        const details: { taskId: string; state: string; logPath?: string; title: string; reason?: string } = {
          taskId: "",
          state: "rejected",
          title: params.title,
          reason: resolved.error,
        };
        return {
          content: [{ type: "text", text: `fleet_launch: ${resolved.error}` }],
          details,
        };
      }
      const project = resolved.path;
      // T-003: delivery posture — param > postures.json config > default no-mistakes
      let posture = params.deliveryPosture;
      const postureMod = await getFleetPosture();
      if (!posture) posture = postureMod?.getPosture(project) ?? "no-mistakes";
      if (!(postureMod?.isValidPosture(posture) ?? false)) posture = "no-mistakes";
      const id = `${slugify(params.title) || "task"}-${Math.floor(Math.random() * 1000)}`;
      const briefPath = join(TASKS_DIR, `${id}.brief.md`);
      writeFileSync(briefPath, params.brief);

      // L3.5 batch window: auto-group for closely-spaced launches (<3s)
      let effectiveGroupId: string | undefined = params.groupId;
      if (!effectiveGroupId) {
        if (lastGroupId && Date.now() - lastGroupTime < 3000) {
          effectiveGroupId = lastGroupId;
          lastGroupSize += 1;
          lastGroupTime = Date.now();
        } else {
          effectiveGroupId = `grp-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
          lastGroupId = effectiveGroupId;
          lastGroupTime = Date.now();
          lastGroupSize = 1;
        }
      } else {
        lastGroupId = effectiveGroupId;
        lastGroupTime = Date.now();
        lastGroupSize = 1;
      }
      // groupLabel/mode presi da params se presenti
      const effectiveGroupMode = (params.groupMode as "barrier" | "streaming" | undefined) ?? "barrier";

      const task: TaskStateFile = {
        id,
        title: params.title,
        project,
        state: "spawning",
        startedAt: Date.now(),
        lastBeatAt: Date.now(),
        doneAt: null,
        timeoutMs: (params.timeoutMin ?? 360) * 60000,
        groupId: effectiveGroupId,
        groupSize: 1, // placeholder — il coordinatore conta reale su disco, o si aggiorna via batch
        groupLabel: params.groupLabel,
        groupMode: effectiveGroupMode,
        kind: params.kind ?? "ship",
        deliveryPosture: posture,
        groupFailPolicy: params.groupFailPolicy,
      };
      writeTask(task);

      const launchParams = { ...params, project, effectiveGroupId } as FleetLaunchParams & { effectiveGroupId?: string };
      launchParams.deliveryPosture = posture;
      // T-011 mechanical gate: active ONLY when posture no-mistakes AND the project
      // has gate.yaml. Backward compatibility: other postures and projects without
      // gate.yaml change nothing. autoPr from gate.yaml (default false — NEVER open a PR without config).
      const gateYamlPath = join(project, "gate.yaml");
      if (posture === "no-mistakes" && existsSync(gateYamlPath)) {
        launchParams.gate = true;
        launchParams.autoPr = false;
        try {
          const raw = readFileSync(gateYamlPath, "utf8");
          const m = raw.match(/^\s*autoPr\s*:\s*(true|false)\s*$/m);
          if (m?.[1] === "true") launchParams.autoPr = true;
        } catch { /* unreadable gate.yaml → autoPr false (fail-open on the gate) */ }
      }
      // Inherits the ACTIVE model of the main session (ctx.model) composing
      // ALWAYS `provider/id` (e.g. "opencode-go/deepseek-v4-flash"): the env
      // vars PI_MODEL/PI_DEFAULT_MODEL are static at startup and do NOT follow
      // mid-session changes (/model, Ctrl+P). NEVER the bare id: pi models resolves
      // bare ids only if UNIQUE, and models like "deepseek-v4-flash" collide across
      // providers → pi starts and exits ~2.6s due to ambiguity. An explicit user
      // override wins; if the provider is not composable → PI_DEFAULT_MODEL,
      // otherwise no --model (the launcher has its own fallback chain).
      let effectiveModel = params.model;
      if (!effectiveModel && ctx?.model?.id) {
        const provider = ctx.model.provider || process.env.PI_PROVIDER;
        if (provider) effectiveModel = `${provider}/${ctx.model.id}`;
      }
      effectiveModel = effectiveModel ?? process.env.PI_DEFAULT_MODEL;
      if (effectiveModel) launchParams.model = effectiveModel;
      const res = spawnLauncher(id, params.title, briefPath, launchParams);
      const state = res.ok ? "spawning" : "failed";
      if (!res.ok) {
        task.state = "failed";
        writeTask(task);
      }
      const details: { taskId: string; state: string; logPath?: string; title: string; reason?: string } = {
        taskId: id,
        state,
        logPath: res.logPath,
        title: params.title,
      };
      return {
        content: [{
          type: "text",
          text: res.ok
            ? `⚑ Task **${params.title}** launched (${id}) on **${project}**. STOP: do not call fleet_status/fleet_peek. The task runs detached in background (herdr tab + worktree). You will be woken automatically on completion. Your turn ends here.`
            : `fleet_launch failed: ${res.error}`,
        }],
        details,
      };
    },
  });

  // --- fleet_status ---
  pi.registerTool({
    name: "fleet_status",
    label: "Fleet Status",
    description: "Lists all pi-fleet tasks with state, project and herdr pane. Supports group filter and shows grp:xxx done/total progress.",
    promptSnippet: "List active pi-fleet tasks and their states",
    parameters: Type.Object({
      limit: Type.Optional(Type.Number({ description: "Max rows (default: 30)" })),
      groupId: Type.Optional(Type.String({ description: "Filter by group (full groupId or 8-char prefix)" })),
    }),
    async execute(_toolCallId, params: { limit?: number; groupId?: string }) {
      let allTasks = listTasks();
      // group filter if requested — matches groupId or id fallback for singles
      if (params.groupId) {
        const gid = params.groupId;
        allTasks = allTasks.filter((t) => (t.groupId ?? t.id) === gid || (t.groupId ?? "").startsWith(gid) || t.id === gid);
      }
      const tasks = allTasks.slice(0, params.limit ?? 30);
      // groupCounts per formatTaskLine (done/total)
      let groupCounts: Map<string, { done: number; total: number }> | undefined;
      let groupSummaries: Array<{ groupId: string; label?: string; expected: number; done: number; pendingIds: string[] }> = [];
      try {
        const mod = getFleetGroupSync();
        if (mod && typeof (mod as unknown as { buildGroupSummaries?: unknown }).buildGroupSummaries === "function") {
          const fn = (mod as unknown as { buildGroupSummaries: (tasks: unknown[]) => typeof groupSummaries }).buildGroupSummaries;
          groupSummaries = fn(allTasks as unknown as Array<{ id: string; state: string; groupId?: string; groupSize?: number; groupLabel?: string }>);
          groupCounts = new Map(groupSummaries.map((g) => [g.groupId, { done: g.done, total: g.expected }]));
        } else {
          // fallback: group by groupId counting terminal states
          const byGroup = new Map<string, TaskStateFile[]>();
          for (const t of allTasks) {
            if (!t.groupId || (t.groupSize ?? 1) <= 1) continue;
            if (!byGroup.has(t.groupId)) byGroup.set(t.groupId, []);
            byGroup.get(t.groupId)!.push(t);
          }
          for (const [gid, members] of byGroup) {
            const expected = Math.max(members[0]?.groupSize ?? members.length, members.length);
            const done = members.filter((m) => isTerminalStateWake(m.state)).length;
            const pendingIds = members.filter((m) => !isTerminalStateWake(m.state)).map((m) => m.id);
            groupSummaries.push({ groupId: gid, label: members[0]?.groupLabel, expected, done, pendingIds });
          }
          groupCounts = new Map(groupSummaries.map((g) => [g.groupId, { done: g.done, total: g.expected }]));
        }
      } catch { /* ignore */ }
      // T-002 (5b.2): conteggio inbox pendenti per task (calcolo leggero, fail soft)
      const clean = tasks.map((t) => {
        const base = { ...t, briefFile: undefined as string | undefined };
        let inboxPending: number | undefined;
        try {
          const mod = getFleetInboxSync();
          if (mod && typeof mod.listPending === "function") {
            const n = mod.listPending(STATE_HOME, t.id).length;
            if (n > 0) inboxPending = n;
          }
        } catch { /* fail soft */ }
        return { ...base, inboxPending };
      });
      let text: string;
      const hasGroups = tasks.some((t) => t.groupId && (t.groupSize ?? 1) > 1);
      if (hasGroups && !params.groupId) {
        // output grouped by group
        const byGroup = new Map<string, TaskStateFile[]>();
        const singles: TaskStateFile[] = [];
        for (const t of tasks) {
          if (t.groupId && (t.groupSize ?? 1) > 1) {
            if (!byGroup.has(t.groupId)) byGroup.set(t.groupId, []);
            byGroup.get(t.groupId)!.push(t);
          } else singles.push(t);
        }
        const lines: string[] = [];
        for (const [gid, members] of byGroup) {
          const g = groupSummaries.find((x) => x.groupId === gid);
          const label = g?.label ? ` (${g.label})` : "";
          const prog = g ? `${g.done}/${g.expected}` : `${members.length}`;
          lines.push(`**Group ${shortGroupId(gid)}${label} — ${prog} complete:**`);
          for (const m of members) lines.push(`  ${formatTaskLine(m, groupCounts)}`);
        }
        if (singles.length) {
          lines.push(`**Singles:**`);
          for (const s of singles) lines.push(`  ${formatTaskLine(s, groupCounts)}`);
        }
        text = `**pi-fleet fleet (${tasks.length})**:\n${lines.join("\n")}\n\nStructured details in details.`;
      } else {
        const lines = tasks.length ? tasks.map((t) => formatTaskLine(t, groupCounts)) : ["(no tasks)"];
        text = `**pi-fleet fleet (${tasks.length})**:\n${lines.join("\n")}\n\nStructured details in details.`;
      }
      return {
        content: [{ type: "text", text }],
        details: { tasks: clean, groups: groupSummaries },
      };
    },
  });

  // --- fleet_outcomes ---
  pi.registerTool({
    name: "fleet_outcomes",
    label: "Fleet Outcomes",
    description: "Query/audit of the branch-outcomes registry (see T-004): ~/.pi/fleet/branch-outcomes.jsonl, append-only, one JSON line per terminal/needs_input transition of each task. raw=true returns the raw JSONL, otherwise a readable list.",
    promptSnippet: "Query the branch-outcomes audit trail (append-only JSONL) for terminal/needs_input transitions",
    parameters: Type.Object({
      limit: Type.Optional(Type.Number({ description: "Max rows (default: 20)" })),
      project: Type.Optional(Type.String({ description: "Filter by project (partial path match)" })),
      verdict: Type.Optional(Type.Union([
        Type.Literal("done"),
        Type.Literal("failed"),
        Type.Literal("aborted"),
        Type.Literal("needs_input"),
      ], { description: "Filter by verdict (done|failed|aborted|needs_input)" })),
      raw: Type.Optional(Type.Boolean({ description: "true → return the raw JSONL; default → readable text" })),
    }),
    async execute(_toolCallId, params: { limit?: number; project?: string; verdict?: "done" | "failed" | "aborted" | "needs_input"; raw?: boolean }) {
      const mod = getFleetOutcomesSync();
      if (!mod) {
        return {
          content: [{ type: "text", text: "fleet_outcomes: outcomes module unavailable (lazy load failed)." }],
          details: { count: 0, file: join(STATE_HOME, "branch-outcomes.jsonl") },
        };
      }
      const file = mod.outcomesFile(STATE_HOME);
      const rows = mod.queryOutcomes(STATE_HOME, {
        limit: params.limit ?? 20,
        project: params.project,
        verdict: params.verdict,
      });
      let text: string;
      if (params.raw) {
        text = rows.length ? rows.join("\n") : "(no entries in the branch-outcomes registry)";
      } else {
        const lines = rows.map((row) => {
          try {
            const o = JSON.parse(row) as { ts?: number; taskId?: string; verdict?: string; summary?: string; project?: string; changedFiles?: unknown[] };
            const sum = (o.summary ?? "").replace(/\s+/g, " ").trim();
            const s = sum.length > 200 ? sum.slice(0, 197) + "…" : sum;
            const files = Array.isArray(o.changedFiles) && o.changedFiles.length ? ` (${o.changedFiles.length} files)` : "";
            return `- ${o.ts ?? "?"} · ${o.taskId ?? "?"} [${o.verdict ?? "?"}]${files} — ${s || "(no summary)"}`;
          } catch {
            return `- (unparseable line) ${row.slice(0, 200)}`;
          }
        });
        text = rows.length
          ? `**branch-outcomes registry (${rows.length} rows)** — ${file}:\n${lines.join("\n")}`
          : `(no entries in the branch-outcomes registry) — ${file}`;
      }
      return {
        content: [{ type: "text", text }],
        details: { count: rows.length, file },
      };
    },
  });

  // --- fleet_peek ---
  pi.registerTool({
    name: "fleet_peek",
    label: "Fleet Peek",
    description: "Reads the latest output of a pi-fleet task's herdr pane.",
    promptSnippet: "Read the herdr pane output of a pi-fleet task",
    parameters: Type.Object({
      id: Type.String({ description: "Task id (see fleet_status)" }),
    }),
    async execute(_toolCallId, params: { id: string }) {
      const task = readTask(params.id);
      let output = "";
      let paneId = "";
      if (task?.paneId) {
        const res = await runHerdr(["agent", "read", task.paneId], 15_000);
        output = res.out.slice(-4000);
        paneId = task.paneId;
      } else {
        output = "Task or pane not found. Use fleet_status.";
      }
      return { content: [{ type: "text", text: output || "(no output)" }], details: { taskId: params.id, paneId } };
    },
  });

  // --- fleet_steer ---
  pi.registerTool({
    name: "fleet_steer",
    label: "Fleet Steer",
    description: "Writes a message into the prompt of a pi-fleet task's child (e.g. answer to needs_input or course correction). Durable by default: the message persists on disk (inbox) until the child acks; if not acked within an interval it is re-delivered (re-ring) and after N repetitions the captain is notified. replay:false = old fire-and-forget behavior.",
    promptSnippet: "Send a message into a pi-fleet task's running child",
    parameters: Type.Object({
      id: Type.String({ description: "Task id (see fleet_status)" }),
      message: Type.String({ description: "Message to send to the child" }),
      replay: Type.Optional(Type.Boolean({ description: "Durable message with ack and re-ring (default true). replay:false = fire-and-forget (old behavior)." })),
    }),
    async execute(_toolCallId, params: { id: string; message: string; replay?: boolean }) {
      const task = readTask(params.id);
      const replay = params.replay ?? true;
      let delivered = false;
      let note = "";
      let seq: number | undefined;
      if (!task) {
        note = "Task or pane not found. Use fleet_status.";
      } else {
        // 1. ALWAYS WRITE TO DISK (durable): ack/re-ring use the file
        const inbox = getFleetInboxSync();
        if (inbox) {
          try {
            const enq = inbox.enqueue(STATE_HOME, task.id, params.message, { replay });
            if (enq.ok) seq = enq.seq;
          } catch { /* fail soft: fallback diretto sotto */ }
        }
        // 2. Immediate delivery if there is a live pane and non-terminal state (as today)
        const paneId = task.paneId;
        if (paneId && !isTerminalStateWake(task.state)) {
          const send = async (message: string): Promise<boolean> => {
            const res = await runHerdr(["agent", "prompt", paneId, message], 15_000);
            return res.ok;
          };
          if (seq !== undefined && inbox) {
            try {
              delivered = await inbox.deliver(STATE_HOME, task.id, seq, send);
            } catch { delivered = false; }
          } else {
            // back-compat fallback (inbox module unavailable or enqueue failed)
            const res = await runHerdr(["agent", "prompt", paneId, params.message], 15_000);
            delivered = res.ok;
            if (!res.ok) note = `Delivery failed: ${res.out}`;
          }
          if (seq !== undefined) {
            const seqTag = ` #${seq}`;
            const modeTag = replay ? " — ack expected" : " — fire-and-forget";
            note = delivered
              ? `Message delivered to the child (inbox${seqTag}${modeTag}).`
              : `Delivery failed (message${seqTag} stays in the inbox, will be re-delivered).`;
          }
          if (delivered && task.state === "needs_input") {
            task.state = "running";
            writeTask(task);
          }
        } else {
          note = seq !== undefined
            ? `Task without an active pane (or terminal state): message #${seq} queued in the inbox (will be delivered by the watcher when the task is active).`
            : "Task without an active pane and inbox unavailable: nothing delivered.";
        }
      }
      let inboxPending: number | undefined;
      try {
        const inbox = getFleetInboxSync();
        if (inbox && seq !== undefined) {
          const n = inbox.listPending(STATE_HOME, params.id).length;
          if (n > 0) inboxPending = n;
        }
      } catch { /* fail soft */ }
      return { content: [{ type: "text", text: note }], details: { taskId: params.id, delivered, seq, inboxPending } };
    },
  });

  // --- fleet_posture ---
  pi.registerTool({
    name: "fleet_posture",
    label: "Fleet Posture",
    description: "Manages the projects' delivery posture (see T-003): no-mistakes|direct-PR|local-only|yolo. get → current posture; set → writes to postures.json. The posture is passed to the child in the prompt as DELIVERY_POSTURE.",
    promptSnippet: "Get/set the delivery posture of a project (no-mistakes|direct-PR|local-only|yolo)",
    parameters: Type.Object({
      action: Type.Union([Type.Literal("get"), Type.Literal("set")], { description: "get → current posture of the project; set → sets and writes to postures.json" }),
      project: Type.String({ description: "Project: absolute path (or short name if FLEET_PROJECTS_DIR is set), like fleet_launch." }),
      posture: Type.Optional(Type.String({ description: "Delivery posture (no-mistakes|direct-PR|local-only|yolo). Only with action=set." })),
    }),
    async execute(_toolCallId: string, params: { action: "get" | "set"; project: string; posture?: string }) {
      type Details = { ok: boolean; action: "get" | "set"; project?: string; posture?: string; error?: string };
      let details: Details;
      let text: string;
      const resolved = resolveProject(params.project);
      if (!resolved.ok) {
        details = { ok: false, action: params.action, error: resolved.error };
        text = `fleet_posture: ${resolved.error}`;
      } else {
        const mod = await getFleetPosture();
        if (!mod) {
          details = { ok: false, action: params.action };
          text = "fleet_posture: fleet-posture module unavailable.";
        } else if (params.action === "get") {
          const posture = mod.getPosture(resolved.path);
          details = { ok: true, action: "get", project: resolved.path, posture };
          text = `Delivery posture of **${resolved.path}**: **${posture}** (default if not configured: no-mistakes).`;
        } else {
          const posture = params.posture;
          if (!posture) {
            details = { ok: false, action: "set", error: "missing posture" };
            text = "fleet_posture: missing 'posture' with action=set (no-mistakes|direct-PR|local-only|yolo).";
          } else if (!mod.isValidPosture(posture)) {
            details = { ok: false, action: "set", error: `invalid posture ${posture}` };
            text = `fleet_posture: invalid posture '${posture}' (no-mistakes|direct-PR|local-only|yolo).`;
          } else {
            try {
              mod.setPosture(resolved.path, posture);
              details = { ok: true, action: "set", project: resolved.path, posture };
              text = `Delivery posture of **${resolved.path}** set to **${posture}**.`;
            } catch (e) {
              details = { ok: false, action: "set", error: e instanceof Error ? e.message : String(e) };
              text = `fleet_posture: write error: ${e instanceof Error ? e.message : String(e)}`;
            }
          }
        }
      }
      return { content: [{ type: "text", text }], details };
    },
  });

  // --- fleet_abort ---
  pi.registerTool({
    name: "fleet_abort",
    label: "Fleet Abort",
    description: "Aborts a pi-fleet task: closes the herdr pane (and the tab if dedicated), releases the worktree, marks aborted.",
    promptSnippet: "Abort a pi-fleet task (close pane/tab, release worktree)",
    parameters: Type.Object({
      id: Type.String({ description: "Task id (see fleet_status)" }),
    }),
    async execute(_toolCallId, params: { id: string }) {
      const task = readTask(params.id);
      let state = "not_found";
      if (task) {
        writeFileSync(join(STATE_HOME, `${task.id}.abort`), `${Date.now()}\n`);
        // Dedicated tab in the fleet workspace (or legacy task split pane):
        // close both when present, tolerating failures.
        if (task.paneId) await runHerdr(["pane", "close", task.paneId], 10_000);
        if (task.tabId) await runHerdr(["tab", "close", task.tabId], 10_000);
        if (task.state === "running" || task.state === "needs_input" || task.state === "spawning") {
          task.state = "aborted";
          writeTask(task);
          // T-004: aborted does NOT transit through the watcher (isTerminal excludes it) → append here,
          // so the audit trail also covers abort via tool (T-004 acceptance criterion)
          try { getFleetOutcomesSync()?.appendOutcome(STATE_HOME, task); } catch { /* best-effort */ }
        }
        state = task.state;
      }
      return {
        content: [{ type: "text", text: state === "aborted" ? `Task ${params.id} aborted (pane closed, worktree being released).` : `Task ${params.id}: state ${state}.` }],
        details: { taskId: params.id, state },
      };
    },
  });

  // --- fleet_attach ---
  pi.registerTool({
    name: "fleet_attach",
    label: "Fleet Attach",
    description: "Moves the herdr focus onto a pi-fleet task's pane to watch it live (steals focus, use when needed).",
    promptSnippet: "Focus the herdr pane of a pi-fleet task",
    parameters: Type.Object({
      id: Type.String({ description: "Task id (see fleet_status)" }),
    }),
    async execute(_toolCallId, params: { id: string }) {
      const task = readTask(params.id);
      let focused = false;
      let note = "Task not found. Use fleet_status.";
      if (task) {
        const res = await runHerdr(["agent", "focus", task.paneId ?? task.id], 10_000);
        focused = res.ok;
        note = res.ok ? `Focus on task ${params.id}.` : `Focus failed: ${res.out}`;
      }
      return { content: [{ type: "text", text: note }], details: { taskId: params.id, focused } };
    },
  });

  // --- fleet_bootstrap (T-006) ---
  pi.registerTool({
    name: "fleet_bootstrap",
    label: "Fleet Bootstrap",
    description: "Verifies tools, cleans stale state and prints a fleet digest (see T-006)",
    promptSnippet: "Verify fleet tools, clean stale state and print a fleet digest",
    parameters: Type.Object({
      verbose: Type.Optional(Type.Boolean({ description: "Include full tool-by-tool report and cleanup details (default: false)" })),
    }),
    async execute(_toolCallId: string, params: { verbose?: boolean }) {
      const mod = await getFleetBootstrap();
      let tools: CheckedTool[] = [];
      let cleanup: string[] = [];
      let digest = "";
      if (mod) {
        tools = mod.checkTools();
        cleanup = mod.cleanupStale(STATE_HOME, listTasks);
        let groupSummaries: GroupSummaryLike[] | undefined;
        try {
          const gmod = getFleetGroupSync();
          if (gmod) groupSummaries = gmod.buildGroupSummaries(listTasks());
        } catch { /* fail soft */ }
        digest = mod.fleetDigest(STATE_HOME, listTasks, groupSummaries);
      } else {
        digest = "(bootstrap module unavailable — import failed)";
      }
      const missing = tools.filter((t) => !t.ok);
      const toolLines = tools.map((t) => {
        const auth = t.auth !== undefined ? `, auth ${t.auth ? "ok" : "ko"}` : "";
        return `  - ${t.tool} → ${t.ok ? `ok (${t.path ?? ""}${auth})` : "MISSING"}`;
      });
      const text = [
        `**Fleet bootstrap** — ${missing.length > 0 ? `⚠ ${missing.length} problem(s): ${missing.map((m) => m.tool).join(", ")}` : "all ok"}`,
        digest,
        `**Tools (${tools.length - missing.length}/${tools.length} ok):**\n${toolLines.join("\n")}`,
        cleanup.length > 0 ? `**Cleanups (${cleanup.length}):**\n${cleanup.map((c) => `  - ${c}`).join("\n")}` : "**Cleanups:** none",
      ].join("\n\n");
      return {
        content: [{ type: "text", text }],
        details: { tools, cleanup, digest },
      };
    },
  });

  // --- fleet_learn (5b.5) ---
  pi.registerTool({
    name: "fleet_learn",
    label: "Fleet Learn",
    description:
      "Records a dated operational learning (fact) in ~/.pi/fleet/learnings.md (runtime-global, never in git). Dedup by title in the last 24h: if the title already exists, replaces the section instead of duplicating. Use it for evidence-backed facts (from which task/observation) that will be useful in future sessions.",
    promptSnippet: "Record an operational learning in learnings.md",
    parameters: Type.Object({
      title: Type.String({ description: "Short learning title" }),
      fact: Type.String({ description: "The operational fact (evidence-backed: from which task/observation)" }),
      implication: Type.Optional(Type.String({ description: "Operational implication (optional)" })),
    }),
    async execute(_toolCallId, params: { title: string; fact: string; implication?: string }) {
      const fl = await getFleetLearn();
      const details: {
        ok: boolean;
        replaced: boolean;
        file: string | null;
      } = { ok: false, replaced: false, file: null };
      let text: string;
      if (!fl) {
        text = "fleet-learn module not loaded (import failed).";
      } else {
        try {
          const res = fl.addLearning(STATE_HOME, params.title, params.fact, params.implication);
          details.ok = true;
          details.replaced = res.replaced;
          details.file = res.path;
          const verb = res.replaced ? "updated (24h dedup)" : "added";
          text = `Learning ${verb}: \"${params.title}\" → ${res.path}`;
        } catch (e) {
          text = `fleet_learn failed: ${e instanceof Error ? e.message : String(e)}`;
        }
      }
      return { content: [{ type: "text", text }], details };
    },
  });

  // --- fleet_captain_pref (5b.5) ---
  pi.registerTool({
    name: "fleet_captain_pref",
    label: "Fleet Captain Pref",
    description:
      "Reads or writes a captain preference in ~/.pi/fleet/captain.md (or captain-shared.md with shared:true; runtime-global, never in git). 'key: value' format, order and comments preserved. get → value or null; set → confirmation with the written line.",
    promptSnippet: "Get or set a captain preference",
    parameters: Type.Object({
      action: Type.Union([Type.Literal("get"), Type.Literal("set")], { description: "get or set" }),
      key: Type.String({ description: "Preference key" }),
      value: Type.Optional(Type.String({ description: "Value (only with action=set)" })),
      shared: Type.Optional(Type.Boolean({ description: "true → captain-shared.md (shareable); default false → captain.md" })),
    }),
    async execute(_toolCallId, params: { action: "get" | "set"; key: string; value?: string; shared?: boolean }) {
      const fl = await getFleetLearn();
      const details: {
        ok: boolean;
        key: string;
        shared: boolean;
        value: string | null;
        line: string | null;
        file: string | null;
      } = { ok: false, key: params.key, shared: params.shared ?? false, value: null, line: null, file: null };
      let text: string;
      if (!fl) {
        text = "fleet-learn module not loaded (import failed).";
      } else {
        try {
          if (params.action === "get") {
            const res = fl.getPref(STATE_HOME, params.key, { shared: params.shared ?? false });
            details.ok = true;
            details.value = res;
            text = res === null ? "null" : res;
          } else {
            if (params.value === undefined) {
              text = "fleet_captain_pref set requires 'value'.";
            } else {
              const res = fl.setPref(STATE_HOME, params.key, params.value, { shared: params.shared ?? false });
              details.ok = true;
              details.line = res.line;
              details.file = res.path;
              text = `Preference written: ${res.line} → ${res.path}`;
            }
          }
        } catch (e) {
          text = `fleet_captain_pref failed: ${e instanceof Error ? e.message : String(e)}`;
        }
      }
      return { content: [{ type: "text", text }], details };

    },
  });

  // --- fleet_stow (T-012) — memory pruning pass, AT THE END of the tool list ---
  pi.registerTool({
    name: "fleet_stow",
    label: "Fleet Stow",
    description: "Memory pruning pass for captain/learnings. Tiers aging (30 days) / perishable (7 days) / pinned; stale → refresh or archive in ~/.pi/fleet/memory-archive.md (never delete uniques); dedup duplicates; optional startup budget (default 7500 tok) with overflow report. dryRun=true → report only, zero writes.",
    promptSnippet: "Run a memory pruning pass (stow)",
    parameters: Type.Object({
      dryRun: Type.Optional(Type.Boolean({ description: "true → report only, zero writes" })),
      verbose: Type.Optional(Type.Boolean({ description: "true → extended detail" })),
    }),
    async execute(_toolCallId, params: { dryRun?: boolean; verbose?: boolean }) {
      const fl = await getFleetLearn();
      const details: {
        refreshed: number;
        archived: number;
        removed: number;
        overflow: number;
        budget: { limitTokens: number; usedTokens: number; overflow: boolean };
        ok: boolean;
        dryRun: boolean;
      } = { refreshed: 0, archived: 0, removed: 0, overflow: 0, budget: { limitTokens: 0, usedTokens: 0, overflow: false }, ok: false, dryRun: params.dryRun === true };
      if (!fl) {
        return { content: [{ type: "text", text: "fleet-learn module not loaded (import failed)." }], details };
      }
      try {
        const report = fl.stowPass(STATE_HOME, { dryRun: params.dryRun === true });
        details.refreshed = report.refreshed;
        details.archived = report.archived;
        details.removed = report.removed;
        details.overflow = report.overflow;
        details.budget = report.budget;
        details.ok = true;
        const budget = `${report.budget.usedTokens}/${report.budget.limitTokens} tok${report.budget.overflow ? " (OVERFLOW)" : ""}`;
        const fileCounts = Object.entries(report.fileCounts)
          .map(([f, n]) => `${f}=${n}`)
          .join(", ");
        const lines: string[] = [
          `[pi-fleet stow] ${report.dryRun ? "dryRun" : "pass"}: refreshed=${report.refreshed}, archived=${report.archived}, removed=${report.removed}, overflow=${report.overflow}, budget=${budget}`,
          `fileCounts: ${fileCounts}`,
        ];
        if (params.verbose === true) {
          lines.push("Stale/unvalidated/overflow memories are archived (never deleted: they end up in memory-archive.md with Provenance).");
        }
        return {
          content: [{ type: "text", text: lines.join("\n") }],
          details,
        };
      } catch (e) {
        const text = `fleet_stow failed: ${e instanceof Error ? e.message : String(e)}`;
        return { content: [{ type: "text", text }], details };
      }
    },
  });

  // ------------------------------------------------------ lifecycle -----
  // L3 external watcher: feature flag with in-process fallback (M2)
  // If fleet-watch-arm.ts or bin/fleet-watch-arm.sh exist and we are captain,
  // mountFleetWatchArm manages generation/lock/arm/wake/drain + the fleet_watch_arm_pi tool.
  // Otherwise fall back to the in-process 3s polling watcher.
  const EXT_WATCH_ARM_SH = join(EXT_DIR, "..", "bin", "fleet-watch-arm.sh");
  const EXT_WATCH_ARM_TS = join(EXT_DIR, "fleet-watch-arm.ts");
  const USE_EXTERNAL_WATCHER = IS_CAPTAIN && (existsSync(EXT_WATCH_ARM_TS) || existsSync(EXT_WATCH_ARM_SH));

  let generation = 0;
  let stopWatcher: (() => void) | null = null;
  const watch = new Map<string, TaskState>();
  let externalMounted = false;

  if (USE_EXTERNAL_WATCHER) {
    try {
      const fleetRoot = resolve(EXT_DIR, "..");
      const res = mountFleetWatchArm(pi, { stateHome: STATE_HOME, extDir: EXT_DIR, root: fleetRoot });
      if (res.ok) {
        externalMounted = true;
      } else {
        console.warn(`[pi-fleet] external watcher not mounted: ${res.message} — fallback in-process`);
      }
    } catch (e) {
      console.warn(`[pi-fleet] external watcher mount failed: ${e instanceof Error ? e.message : String(e)} — fallback in-process`);
    }
    // Best-effort drain of pending wakes even if the mount fails (Pi was closed)
    if (!externalMounted) {
      const drainScript = join(resolve(EXT_DIR, ".."), "bin", "fleet-wake-drain.sh");
      if (existsSync(drainScript)) {
        try {
          spawnSync("bash", [drainScript], {
            cwd: resolve(EXT_DIR, ".."),
            encoding: "utf8",
            env: { ...process.env, FLEET_STATE_HOME: STATE_HOME, FLEET_ROOT_OVERRIDE: resolve(EXT_DIR, "..") },
            timeout: 5000,
          });
        } catch { /* best-effort */ }
      }
    }
  }

  pi.on("session_start", () => {
    if (!IS_CAPTAIN) return;
    // L3.5: rebuild groups from disk (also needed for fallback if the external watcher mounts)
    void (async () => {
      try {
        const mod = await getFleetGroup();
        if (mod) {
          const rebuilt = mod.rebuildGroupsFromDisk(STATE_HOME, listTasks());
          for (const [k, v] of rebuilt) groupMap.set(k, v);
        }
      } catch { /* fail soft */ }
    })();
    if (externalMounted) {
      // Verify the external watcher is really alive (fresh beat <90s), otherwise in-process fallback
      let externalAlive = false;
      try {
        const beatPath = join(STATE_HOME, ".last-watcher-beat");
        const st = statSync(beatPath);
        const ageSec = (Date.now() - st.mtimeMs) / 1000;
        if (ageSec < 90) externalAlive = true;
      } catch {
        try {
          const lockPath = join(STATE_HOME, ".watch.lock");
          const st2 = statSync(lockPath);
          const ageSec2 = (Date.now() - st2.mtimeMs) / 1000;
          if (ageSec2 < 120) externalAlive = true;
        } catch {}
      }
      if (externalAlive) {
        void reconcileStaleTasks();
        return;
      }
      console.warn("[pi-fleet] external watcher seems dead (no fresh beat/lock), starting in-process fallback watcher");
    }
    generation++;
    stopWatcher?.();
    void (async () => {
      await reconcileStaleTasks();
      stopWatcher = startWatcher(pi, watch);
    })();
  });

  // T-006 — bootstrap at session_start. SEPARATE hook from the one above
  // (multiple session_start registrations are intentional to avoid colliding with
  // parallel tasks touching the existing block). Best-effort, never blocking.
  pi.on("session_start", () => {
    if (!IS_CAPTAIN) return;
    void (async () => {
      try {
        const mod = await getFleetBootstrap();
        if (!mod) return;
        const tools = mod.checkTools();
        const cleanup = mod.cleanupStale(STATE_HOME, listTasks);
        let groupSummaries: GroupSummaryLike[] | undefined;
        try {
          const gmod = getFleetGroupSync();
          if (gmod) groupSummaries = gmod.buildGroupSummaries(listTasks());
        } catch { /* fail soft */ }
        const digest = mod.fleetDigest(STATE_HOME, listTasks, groupSummaries);
        console.log(`[pi-fleet bootstrap] ${digest.replace(/\n/g, " | ")}`);
        const missing = tools.filter((t) => !t.ok);
        const needsInputCount = listTasks().filter((t) => t.state === "needs_input").length;
        if (missing.length > 0 || needsInputCount > 0) {
          const problems: string[] = [];
          if (missing.length > 0) problems.push(`missing tools: ${missing.map((m) => m.tool).join(", ")}`);
          if (needsInputCount > 0) problems.push(`${needsInputCount} task(s) awaiting input`);
          // Short and clean message for the initial user, WITHOUT interrupt
          // (triggerTurn:false): session startup is never blocked.
          pi.sendMessage(
            {
              customType: "fleet_bootstrap",
              content: `[pi-fleet] At startup: ${problems.join("; ")}.\n${digest}`,
              display: true,
              details: { tools, cleanup, digest },
            },
            { triggerTurn: false, deliverAs: "followUp" },
          );
        }
      } catch { /* fail soft: bootstrap must never block startup */ }
    })();
  });

  pi.on("session_shutdown", () => {
    if (externalMounted) return; // gestito dal modulo esterno (stopGeneration)
    generation++;
    stopWatcher?.();
    stopWatcher = null;
  });

  // 5b.5 — captain preferences + learnings (hook SEPARATE from the L3.5 session_start above:
  // T-006/coordination touch that area; here only best-effort captain-only is added)
  pi.on("session_start", () => {
    if (!IS_CAPTAIN) return;
    void (async () => {
      try {
        const fl = await getFleetLearn();
        if (!fl) return;
        fl.ensureFiles(STATE_HOME);
        const prefs = fl.readCaptain(STATE_HOME);
        const nPrefs = fl.countPrefs(STATE_HOME);
        const nLearnings = fl.countLearnings(STATE_HOME);
        console.log(`[pi-fleet] captain prefs: ${nPrefs} keys, ${nLearnings} learnings`);
        if (prefs.trim()) console.log(`[pi-fleet] captain.md bootstrap:\n${prefs.trimEnd()}`);
      } catch { /* best-effort */ }
    })();
  });

  // T-012 — stow-lite: memory pruning pass (hook SEPARATE from the T-006/T-007 ones,
  // multiple session_start registrations are intentional). Cadence max 1 pass/day:
  // guard on ~/.pi/fleet/.stow-last-pass (today's date). Fail-soft, zero-blocking.
  pi.on("session_start", () => {
    if (!IS_CAPTAIN) return;
    void (async () => {
      try {
        const fl = await getFleetLearn();
        if (!fl || typeof fl.stowPass !== "function") return; // retrocompat: versione senza T-012
        const lastPassPath = join(STATE_HOME, ".stow-last-pass");
        const today = new Date().toISOString().slice(0, 10);
        let alreadyToday = false;
        try {
          if (existsSync(lastPassPath)) {
            const mtime = new Date(statSync(lastPassPath).mtime).toISOString().slice(0, 10);
            alreadyToday = mtime === today;
          }
        } catch { /* fail-soft */ }
        if (alreadyToday) return;
        const report = fl.stowPass(STATE_HOME, { dryRun: false });
        try {
          writeFileSync(lastPassPath, `${today}\n`, "utf8");
        } catch { /* fail-soft: the marker is best-effort */ }
        console.log(
          `[pi-fleet stow] refreshed=${report.refreshed} archived=${report.archived} removed=${report.removed} overflow=${report.overflow} budget=${report.budget.usedTokens}/${report.budget.limitTokens}`,
        );
      } catch { /* best-effort: il pruning non deve mai bloccare l'avvio */ }
    })();
  });
}