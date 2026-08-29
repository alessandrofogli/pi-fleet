/**
 * pi-fleet · extension Pi (M2)
 *
 * Avvolge il launcher CLI (bin/herdr-launch.sh) in un'estensione Pi:
 *  - fleet_launch  : spawna un task come PANE HERDR AFFIANCATO (split, non tab)
 *  - fleet_status  : lista task e stati
 *  - fleet_peek    : legge l'output del pane del task
 *  - fleet_steer   : scrive nella prompt del figlio (es. risposta a needs_input)
 *  - fleet_abort   : chiude pane/tab + rilascia worktree + marca aborted
 *  - fleet_attach  : porta il focus herdr sul pane del task
 *  - watcher in-process: risveglia la chat (sendMessage triggerTurn) quando un
 *    task entra in failed/needs_input (i done sono silenziosi, come da decisioni F0)
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
// L3.5 barrier — helpers opzionali caricati lazy per fail soft
let _fleetGroup: typeof import("./fleet-group.js") | null = null;
async function getFleetGroup(): Promise<typeof import("./fleet-group.js") | null> {
  if (_fleetGroup) return _fleetGroup;
  try { _fleetGroup = await import("./fleet-group.js"); return _fleetGroup; } catch { return null; }
}
function getFleetGroupSync(): typeof import("./fleet-group.js") | null {
  return _fleetGroup;
}

const EXT_DIR = dirname(fileURLToPath(import.meta.url));
const LAUNCHER = join(EXT_DIR, "..", "bin", "herdr-launch.sh");
const STATE_HOME = process.env.FLEET_STATE_HOME ?? join(homedir(), ".pi", "fleet");
const TASKS_DIR = join(STATE_HOME, "tasks");
const WAKE_CHANNEL = "pi-fleet.wake.v1";
const POLL_MS = 3000;
// L3.5 batch window: tutti i fleet_launch dello stesso turno LLM (<3s) condividono lo stesso groupId
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
  groupFailPolicy?: "waitAll" | "immediate";
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
    // MAI cancellare: se il parse fallisce il file potrebbe essere a metà
    // scrittura (il launcher scrive in modo atomico, ma il primo giro M1 no).
    // Lo rinomina .bad così è ispezionabile e un poll successivo può rileggere.
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

/** Slug leggibile da titolo: ascii, minuscole, max 30 char (es. 'Analisi modelli' → 'analisi-modelli'). */
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
  groupFailPolicy?: "waitAll" | "immediate";
}

function spawnLauncher(taskId: string, title: string, briefPath: string, params: FleetLaunchParams): { ok: boolean; error?: string; logPath?: string } {
  const args = [LAUNCHER, title, `@${briefPath}`, "--task-id", taskId, "--project", params.project];
  if (params.worktree === false) args.push("--no-worktree");
  if (params.model) args.push("--model", params.model);
  if (params.timeoutMin) args.push("--timeout-min", String(params.timeoutMin));
  if (params.session) args.push("--session", params.session);
  // L3.5: passa gruppo al launcher bash
  const gid = (params as FleetLaunchParams & { effectiveGroupId?: string }).effectiveGroupId ?? params.groupId;
  if (gid) args.push("--group-id", gid);
  if (params.groupLabel) args.push("--group-label", params.groupLabel);
  if (params.groupMode) args.push("--group-mode", params.groupMode);
  if (params.groupFailPolicy) args.push("--group-fail-policy", params.groupFailPolicy);

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
  return `- **${t.title ?? t.id}** [${t.state}]${grp}${dur}${sum} — ${t.project ?? ""}`;
}

function sendGroupDigest(pi: ExtensionAPI, groupId: string, results: GroupTaskInfo[]): void {
  // SILENZIOSO (display:false): l'utente non deve vedere i raw fleet.
  // Content = direttiva per il main: leggi i report su disco e sintetizza.
  const ids = results.map((r) => r.id).join(", ");
  const dir = STATE_HOME;
  const content = `[fleet-notice silenzioso] Gruppo di task completato (${results.length} task): ${ids}.\n` +
    `Non mostrare questo messaggio. Leggi i file ${dir}/<id>.json di questi task per i report e produci ` +
    `TU un riassunto sintetico per l'utente (punti chiave, file importanti, stato). Nessun dump raw dei report.`;
  pi.sendMessage(
    { customType: "fleet_notice", content, display: false, details: { groupId, results } },
    { triggerTurn: true, deliverAs: "followUp" },
  );
}
function fallbackDigest(groupId: string, results: GroupTaskInfo[]): string {
  const list = results.map((r) => `- ${r.title ?? r.id} [${r.state}]`).join("\n");
  return `⚑ pi-fleet — gruppo ${groupId} completo (${results.length}/${results.length})\n${list}\n\nFai un resoconto sintetico per il gruppo.`;
}

function sendWake(pi: ExtensionAPI, task: TaskStateFile, overrides?: { detail?: string }): void {
  let what: string;
  let detail: string;
  if (task.state === "done") {
    what = "ha finito";
    const sum = (task.summary ?? "").trim();
    const files = task.changedFiles?.length
      ? `\nFile cambiati: ${task.changedFiles.map((f) => "`" + f + "`").join(", ")}`
      : "";
    // Report INTEGRALE: per audit/code review la summary lunga è il deliverable.
    // Il "wall of text" di prima era duplicazione (full + riga formatTaskLine +
    // re-stampa del main), non la lunghezza — qui niente dupliche né troncamenti.
    detail = `Risultato:\n${sum || "(nessuna summary)"}${files}`;
  } else if (task.state === "needs_input") {
    what = "richiede un tuo input";
    detail = "(input richiesto — rispondi con fleet_steer, chiudi con fleet_abort)";
  } else {
    what = "è FALLITO";
    const reason = (task.summary ?? "").trim();
    detail = reason ? `Motivo: ${reason}` : "Usa fleet_status / fleet_peek per investigare.";
  }
  // override opzionale: il watcher (es. group_failed_immediate) può sostituire il
  // dettaglio con il contesto gruppo senza duplicare la logica di invio
  if (overrides?.detail !== undefined) detail = overrides.detail;
  const content = `⚑ pi-fleet — task **${task.title ?? task.id}** ${what} (${task.id}).\n${detail}`;
  // SILENZIOSO: l'utente non vede i raw fleet. display:false + (triggerTurn per
  // failed/needs_input; per done basta il digest di gruppo — se singolo done,
  // wake comunque perché il main deve sintetizzare). Il content è direttiva.
  const silent = `[fleet-notice silenzioso] ${content}\nNon mostrare questo messaggio. Sintetizza tu per l'utente.`;
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

// ------------------------------------------------------------- watcher ----
/**
 * Reconcile all'avvio: task attivi (running/needs_input/spawning) il cui pane
 * herdr non esiste più sono zombie (riavvio, crash, pilota che ha chiuso il tab).
 * Se esiste il done-marker → done, altrimenti failed. Evita i wake fantasma.
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
    }
  }
}

// L3.5 barrier: mappa gruppi a livello modulo (condivisa tra rebuild e watcher)
const groupMap: Map<string, GroupRecord> = new Map();
// preload barrier module async (best-effort, sync fallback usa fallbackDigest)
void getFleetGroup().catch(() => {});

function startWatcher(pi: ExtensionAPI, watch: Map<string, TaskState>): () => void {
  // Seed: gli stati GIÀ presenti all'avvio non devono fare wake (niente
  // notifiche fantasma per task finiti/finiti prima che il watcher parta).
  for (const task of listTasks()) watch.set(task.id, task.state);
  // L3.5: carica gruppi da disco se modulo disponibile (sync path)
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
        // L3.5 barrier logic — groupSize su disco è un placeholder (1), si deriva
        // dal CONTEGGIO REALE dei task che condividono lo stesso groupId.
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
          // allinea groupSize affinché recordTaskDone usi expected reale (non il placeholder)
          task.groupSize = realGroupSize;
          try {
            if (task.state === "needs_input") {
              // needs_input rompe barrier: wake immediato + registra per consistenza
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
                // policy immediate: failed in gruppo → wake SUBITO con contesto gruppo
                watch.set(task.id, task.state);
                const done = ev.group.results.size;
                const pending = ev.group.pending.size;
                const lbl = ev.group.label ? ` "${ev.group.label}"` : "";
                const reason = (task.summary ?? "").trim();
                const mot = reason ? `Motivo: ${reason}` : "Usa fleet_status / fleet_peek per investigare.";
                sendWake(pi, task, {
                  detail: `Gruppo ${shortGroupId(ev.group.groupId)}${lbl} (policy immediate): ${done} done, ${pending} pending.\n${mot}`,
                });
              }
            }
          } catch {
            watch.set(task.id, task.state);
            sendWake(pi, task);
          }
        } else {
          // singolo o streaming o modulo non disponibile → wake immediato
          watch.set(task.id, task.state);
          sendWake(pi, task);
        }
      } else {
        watch.set(task.id, task.state);
      }
    }
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
// I "subagent" non sono processi figli: sono sessioni pi INDIPENDENTI nel pane
// herdr, coordinate via i file condivisi in ~/.pi/fleet. Tutte caricano questa
// estensione → il watcher/invio dei fleet_notice DEVE scattare SOLO nel capitano
// (cwd = HOME, policy AGENTS.md). Nei figli l'estensione resta muta: niente
// watcher, niente reconcile, solo i tool di consultazione.
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
      "Spawna un sub-agent VISIBILE: lo esegue in un workspace herdr 'fleet' dedicato (tab --no-focus) con pi dentro (stesso modello della sessione main), in una worktree treehouse isolata, gli consegna il brief e libera la chat. Il figlio NON ruba il focus e NON occupa spazio nel tab del capitano: è visibile SOLO nella sidebar agents di herdr a sinistra (fino a che non lo apri). A fine task il report arriva nella chat (successo senza interruzione; failed/needs_input risvegliano il main agent nel turno).",
    promptSnippet: "Spawn a background herdr sub-agent (agents-sidebar only) for a delegation task",
    promptGuidelines: [
      "AUTOMATICALLY call fleet_launch for ANY non-trivial request about a project: reading/analyzing, editing, implementing, fixing, testing, refactoring. Do NOT wait for the user to type fleet_launch and do NOT ask for confirmation — delegation is the default. Handle inline ONLY questions answerable from context, fleet management, and trivial one-liners.",
      "project is REQUIRED (absolute path, ~/path, or short name if FLEET_PROJECTS_DIR is set): derive it from the user's message or the last task's project; ask one short question only if truly ambiguous. Never launch without project. Keep worktree enabled.",
      "For multiple independent requests, launch them in PARALLEL (max 5 per turn) instead of sequentially.",
      "CRITICAL: After fleet_launch returns, STOP IMMEDIATELY and END YOUR TURN. Do NOT call fleet_status, fleet_peek, fleet_watch_arm_pi, or any other fleet tool to check progress. The task runs detached in background - you will be WOKEN automatically via fleet_notice when it finishes (done=silent followUp, failed/needs_input=triggerTurn). Polling wastes context and blocks the session. Your turn is OVER after launch.",
      "When you receive a fleet_notice group complete (e.g. \"⚑ pi-fleet — gruppo ... completo\"), IMMEDIATELY produce a concise synthesis per gruppo: key findings, important files, status per task. Do NOT just echo the raw fleet list — synthesize into a clear summary for the user. This synthesis is the ONLY verbose output the user should see for the group; the raw fleet list is just the trigger.",
    ],
    parameters: Type.Object({
      title: Type.String({ description: "Breve titolo del task" }),
      brief: Type.String({ description: "Istruzioni complete del task (markdown)" }),
      project: Type.String({ description: "Project: absolute path (e.g. /home/user/projects/my-app or ~/projects/my-app) or short name if FLEET_PROJECTS_DIR is set. REQUIRED." }),
      worktree: Type.Optional(Type.Boolean({ description: "Usa una worktree treehouse isolata (default: true)" })),
      model: Type.Optional(Type.String({ description: "Override modello, es. 'opencode-go/deepseek-v4-flash' (default: modello della sessione parent)" })),
      timeoutMin: Type.Optional(Type.Number({ description: "Timeout in minuti (default: 360)" })),
      groupId: Type.Optional(Type.String({ description: "Group id for barrier digest (e.g. grp-20260828-a1b2c3). Auto-generated via batch window if omitted." })),
      groupLabel: Type.Optional(Type.String({ description: "Optional label for the group (shown in digest)" })),
      groupMode: Type.Optional(Type.String({ description: "Group mode: barrier (wait all) or streaming (per-task). Default barrier." })),
      groupFailPolicy: Type.Optional(Type.String({ description: "waitAll (default) | immediate: failed in gruppo sveglia subito il capitano" })),
    }),
    // L3.5: se lanci N in parallelo nello stesso turno, riusa stesso groupId (auto-batch)
    // La guideline aiuta il modello a passare groupId esplicito se vuole gruppi separati.

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
      const id = `${slugify(params.title) || "task"}-${Math.floor(Math.random() * 1000)}`;
      const briefPath = join(TASKS_DIR, `${id}.brief.md`);
      writeFileSync(briefPath, params.brief);

      // L3.5 batch window: auto-gruppo per lanci ravvicinati (<3s)
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
        groupFailPolicy: params.groupFailPolicy,
      };
      writeTask(task);

      const launchParams = { ...params, project, effectiveGroupId } as FleetLaunchParams & { effectiveGroupId?: string };
      // Eredita il modello ATTIVO della sessione main (ctx.model) componendo
      // SEMPRE `provider/id` (es. "opencode-go/deepseek-v4-flash"): le env
      // PI_MODEL/PI_DEFAULT_MODEL sono statiche all'avvio e NON seguono i cambi
      // a metà sessione (/model, Ctrl+P). MAI il bare id: pi models risolve i
      // bare id solo se UNICI, e modelli come "deepseek-v4-flash" collidono tra
      // più provider → pi parte ed esce ~2.6s per ambiguità. L'override esplicito
      // dell'utente vince; se il provider non è componibile → PI_DEFAULT_MODEL,
      // altrimenti nessun --model (il launcher ha la sua catena di fallback).
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
            ? `⚑ Task **${params.title}** lanciato (${id}) su **${project}**. STOP: non chiamare fleet_status/fleet_peek. Il task gira detached in background (tab herdr + worktree). Verrai svegliato automaticamente al completamento. Il tuo turno finisce qui.`
            : `fleet_launch fallito: ${res.error}`,
        }],
        details,
      };
    },
  });

  // --- fleet_status ---
  pi.registerTool({
    name: "fleet_status",
    label: "Fleet Status",
    description: "Lista tutti i task pi-fleet con stato, progetto e pane herdr. Supporta filtro per gruppo e mostra avanzamento grp:xxx done/total.",
    promptSnippet: "List active pi-fleet tasks and their states",
    parameters: Type.Object({
      limit: Type.Optional(Type.Number({ description: "Max righe (default: 30)" })),
      groupId: Type.Optional(Type.String({ description: "Filtra per gruppo (groupId completo o prefisso 8)" })),
    }),
    async execute(_toolCallId, params: { limit?: number; groupId?: string }) {
      let allTasks = listTasks();
      // filtro per gruppo se richiesto — matcha groupId o fallback id per singoli
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
          // fallback: raggruppa per groupId contando terminal
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
      const clean = tasks.map((t) => ({ ...t, briefFile: undefined as string | undefined }));
      let text: string;
      const hasGroups = tasks.some((t) => t.groupId && (t.groupSize ?? 1) > 1);
      if (hasGroups && !params.groupId) {
        // output raggruppato per gruppo
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
          lines.push(`**Gruppo ${shortGroupId(gid)}${label} — ${prog} completi:**`);
          for (const m of members) lines.push(`  ${formatTaskLine(m, groupCounts)}`);
        }
        if (singles.length) {
          lines.push(`**Singoli:**`);
          for (const s of singles) lines.push(`  ${formatTaskLine(s, groupCounts)}`);
        }
        text = `**Flotta pi-fleet (${tasks.length})**:\n${lines.join("\n")}\n\nDettagli strutturati in details.`;
      } else {
        const lines = tasks.length ? tasks.map((t) => formatTaskLine(t, groupCounts)) : ["(nessun task)"];
        text = `**Flotta pi-fleet (${tasks.length})**:\n${lines.join("\n")}\n\nDettagli strutturati in details.`;
      }
      return {
        content: [{ type: "text", text }],
        details: { tasks: clean, groups: groupSummaries },
      };
    },
  });

  // --- fleet_peek ---
  pi.registerTool({
    name: "fleet_peek",
    label: "Fleet Peek",
    description: "Legge l'ultimo output del pane herdr di un task pi-fleet.",
    promptSnippet: "Read the herdr pane output of a pi-fleet task",
    parameters: Type.Object({
      id: Type.String({ description: "Task id (vedi fleet_status)" }),
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
        output = "Task o pane non trovato. Usa fleet_status.";
      }
      return { content: [{ type: "text", text: output || "(nessun output)" }], details: { taskId: params.id, paneId } };
    },
  });

  // --- fleet_steer ---
  pi.registerTool({
    name: "fleet_steer",
    label: "Fleet Steer",
    description: "Scrive un messaggio nella prompt del figlio di un task pi-fleet (es. risposta a needs_input o correzione di rotta).",
    promptSnippet: "Send a message into a pi-fleet task's running child",
    parameters: Type.Object({
      id: Type.String({ description: "Task id (vedi fleet_status)" }),
      message: Type.String({ description: "Messaggio da inviare al figlio" }),
    }),
    async execute(_toolCallId, params: { id: string; message: string }) {
      const task = readTask(params.id);
      let delivered = false;
      let note = "";
      if (!task?.paneId) {
        note = "Task o pane non trovato. Usa fleet_status.";
      } else {
        const res = await runHerdr(["agent", "prompt", task.paneId, params.message], 15_000);
        delivered = res.ok;
        note = res.ok ? "Messaggio consegnato al figlio." : `Invio fallito: ${res.out}`;
        if (res.ok && task.state === "needs_input") {
          task.state = "running";
          writeTask(task);
        }
      }
      return { content: [{ type: "text", text: note }], details: { taskId: params.id, delivered } };
    },
  });

  // --- fleet_abort ---
  pi.registerTool({
    name: "fleet_abort",
    label: "Fleet Abort",
    description: "Interrompe un task pi-fleet: chiude il pane herdr (e il tab se dedicato), rilascia la worktree, marca aborted.",
    promptSnippet: "Abort a pi-fleet task (close pane/tab, release worktree)",
    parameters: Type.Object({
      id: Type.String({ description: "Task id (vedi fleet_status)" }),
    }),
    async execute(_toolCallId, params: { id: string }) {
      const task = readTask(params.id);
      let state = "not_found";
      if (task) {
        writeFileSync(join(STATE_HOME, `${task.id}.abort`), `${Date.now()}\n`);
        // Tab dedicato nel workspace fleet (oppure pane split di task legacy):
        // chiudi entrambi quando presenti, tollerando fallimenti.
        if (task.paneId) await runHerdr(["pane", "close", task.paneId], 10_000);
        if (task.tabId) await runHerdr(["tab", "close", task.tabId], 10_000);
        if (task.state === "running" || task.state === "needs_input" || task.state === "spawning") {
          task.state = "aborted";
          writeTask(task);
        }
        state = task.state;
      }
      return {
        content: [{ type: "text", text: state === "aborted" ? `Task ${params.id} in abort (pane chiuso, worktree in rilascio).` : `Task ${params.id}: stato ${state}.` }],
        details: { taskId: params.id, state },
      };
    },
  });

  // --- fleet_attach ---
  pi.registerTool({
    name: "fleet_attach",
    label: "Fleet Attach",
    description: "Porta il focus herdr sul pane di un task pi-fleet per vederlo live (ruba il focus, usalo quando serve).",
    promptSnippet: "Focus the herdr pane of a pi-fleet task",
    parameters: Type.Object({
      id: Type.String({ description: "Task id (vedi fleet_status)" }),
    }),
    async execute(_toolCallId, params: { id: string }) {
      const task = readTask(params.id);
      let focused = false;
      let note = "Task non trovato. Usa fleet_status.";
      if (task) {
        const res = await runHerdr(["agent", "focus", task.paneId ?? task.id], 10_000);
        focused = res.ok;
        note = res.ok ? `Focus sul task ${params.id}.` : `Focus fallito: ${res.out}`;
      }
      return { content: [{ type: "text", text: note }], details: { taskId: params.id, focused } };
    },
  });

  // ------------------------------------------------------ ciclo di vita -----
  // L3 watcher esterno: feature flag con fallback in-process (M2)
  // Se fleet-watch-arm.ts o bin/fleet-watch-arm.sh esistono e siamo captain,
  // mountFleetWatchArm gestisce generation/lock/arm/wake/drain + tool fleet_watch_arm_pi.
  // Altrimenti fallback al watcher in-process polling 3s.
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
    // Drain best-effort di wake pendenti anche se mount fallisce (Pi era chiuso)
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
    // L3.5: ricostruisci gruppi da disco (anche se watcher esterno monta, serve per fallback)
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
      // Verifica che il watcher esterno sia davvero vivo (beat fresco <90s), altrimenti fallback in-process
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

  pi.on("session_shutdown", () => {
    if (externalMounted) return; // gestito dal modulo esterno (stopGeneration)
    generation++;
    stopWatcher?.();
    stopWatcher = null;
  });
}