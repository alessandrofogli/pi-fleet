/**
 * pi-fleet · extension Pi (M2)
 *
 * Avvolge il launcher CLI (bin/herdr-launch.sh) in un'estensione Pi:
 *  - fleet_launch  : spawna un task come TAB HERDR visibile (pi figlio + worktree)
 *  - fleet_status  : lista task e stati
 *  - fleet_peek    : legge l'output del pane del task
 *  - fleet_steer   : scrive nella prompt del figlio (es. risposta a needs_input)
 *  - fleet_abort   : chiude tab + rilascia worktree + marca aborted
 *  - fleet_attach  : porta il focus herdr sul tab del task
 *  - watcher in-process: risveglia la chat (sendMessage triggerTurn) quando un
 *    task entra in failed/needs_input (i done sono silenziosi, come da decisioni F0)
 *  - registra i task come background-work provider di pi-subagents (FleetView)
 */

import { spawn, type ChildProcess } from "node:child_process";
import { existsSync, mkdirSync, openSync, readdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

const EXT_DIR = dirname(fileURLToPath(import.meta.url));
const LAUNCHER = join(EXT_DIR, "..", "bin", "herdr-launch.sh");
const STATE_HOME = process.env.FLEET_STATE_HOME ?? join(homedir(), ".pi", "fleet");
const TASKS_DIR = join(STATE_HOME, "tasks");
const WAKE_CHANNEL = "pi-fleet.wake.v1";
const POLL_MS = 3000;

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
 * Risolve il progetto del task. Il main agent sta in ~ e i progetti vivono in
 * ~/Documents/GitHub: accettiamo un NOME ("MiroFish-private") o un path assoluto.
 */
function resolveProject(raw: string): { ok: true; path: string } | { ok: false; error: string } {
  if (raw.startsWith("/")) {
    if (existsSync(raw)) return { ok: true, path: raw };
    return { ok: false, error: `Percorso non trovato: ${raw}` };
  }
  const gh = join(homedir(), "Documents", "GitHub", raw);
  if (existsSync(gh)) return { ok: true, path: gh };
  let available = "";
  try {
    const hub = join(homedir(), "Documents", "GitHub");
    available = readdirSync(hub)
      .filter((d) => { try { return statSync(join(hub, d)).isDirectory(); } catch { return false; } })
      .slice(0, 15)
      .join(", ");
  } catch { /* ignore */ }
  return {
    ok: false,
    error: `Progetto '${raw}' non trovato in ~/Documents/GitHub. Usa un nome tra: ${available || "(cartella vuota)"} — oppure un path assoluto.`,
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
}

function spawnLauncher(taskId: string, title: string, briefPath: string, params: FleetLaunchParams): { ok: boolean; error?: string; logPath?: string } {
  const args = [LAUNCHER, title, `@${briefPath}`, "--task-id", taskId, "--project", params.project];
  if (params.worktree === false) args.push("--no-worktree");
  if (params.model) args.push("--model", params.model);
  if (params.timeoutMin) args.push("--timeout-min", String(params.timeoutMin));
  if (params.session) args.push("--session", params.session);

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
function formatTaskLine(t: TaskStateFile): string {
  const dur = t.startedAt ? ` (${Math.round((Date.now() - t.startedAt) / 1000)}s fa)` : "";
  const sum = t.summary && t.state !== "running" && t.state !== "spawning"
    ? ` — ${t.summary.length > 140 ? t.summary.slice(0, 137) + "…" : t.summary}`
    : "";
  return `- **${t.title ?? t.id}** [${t.state}]${dur}${sum} — ${t.project ?? ""}`;
}

function sendWake(pi: ExtensionAPI, task: TaskStateFile): void {
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
  const content = `⚑ pi-fleet — task **${task.title ?? task.id}** ${what} (${task.id}).\n${detail}`;
  // Parità Firstmate (fm-primary-pi-watch.ts): il report dei done entra in chat
  // come followUp SENZA triggerTurn (visibile, niente interruzione LLM); il turno
  // viene forzato solo per failed/needs_input (quando serve davvero il capitano).
  const triggerTurn = task.state !== "done";
  pi.sendMessage(
    {
      customType: "fleet_notice",
      content,
      display: true,
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

function startWatcher(pi: ExtensionAPI, watch: Map<string, TaskState>): () => void {
  // Seed: gli stati GIÀ presenti all'avvio non devono fare wake (niente
  // notifiche fantasma per task finiti/finiti prima che il watcher parta).
  for (const task of listTasks()) watch.set(task.id, task.state);

  const timer = setInterval(() => {
    for (const task of listTasks()) {
      const prev = watch.get(task.id);
      if (prev !== task.state && (task.state === "failed" || task.state === "needs_input" || task.state === "done")) {
        watch.set(task.id, task.state);
        sendWake(pi, task);
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

/** Fallback: scrive direttamente nel registry globale condiviso da pi-subagents. */
function registerFallbackProvider(provider: BackgroundWorkProviderShape): (() => void) | null {
  try {
    const reg = (globalThis as Record<PropertyKey, unknown>)[Symbol.for("pi-subagents.background-work.v1")] as
      | { version: number; providers: Map<string, unknown> }
      | undefined;
    if (!reg || !(reg.providers instanceof Map)) return null;
    reg.providers.set(provider.name, provider);
    return () => {
      if (reg.providers.get(provider.name) === provider) reg.providers.delete(provider.name);
    };
  } catch {
    return null;
  }
}

async function registerBackgroundWork(): Promise<void> {
  const provider: BackgroundWorkProviderShape = {
    name: "pi-fleet",
    listActiveWork: () =>
      listTasks()
        .filter((t) => ACTIVE_STATES.has(t.state))
        .map((t) => ({ id: t.id, sessionId: process.env.PI_SESSION_FILE ?? "" })),
    wakeChannels: [WAKE_CHANNEL],
  };
  try {
    const mod = await import("pi-subagents/background-work");
    providerUnregister = mod.registerBackgroundWorkProvider(provider);
  } catch (e) {
    providerUnregister = registerFallbackProvider(provider);
    console.warn(
      `[pi-fleet] import pi-subagents/background-work fallito (${e instanceof Error ? e.message : String(e)}); usato il registry globale.`,
    );
  }
}

// ---------------------------------------------------------------- tools ----
// I "subagent" non sono processi figli: sono sessioni pi INDIPENDENTI nel pane
// herdr, coordinate via i file condivisi in ~/.pi/fleet. Tutte caricano questa
// estensione → il watcher/invio dei fleet_notice DEVE scattare SOLO nel capitano
// (cwd = HOME, policy AGENTS.md). Nei figli l'estensione resta muta: niente
// watcher, niente reconcile, niente provider background-work (l'import sul
// registro condiviso sbaglierebbe il sessionId), solo i tool di consultazione.
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
      "Spawna un sub-agent VISIBILE: crea un tab herdr con pi dentro (stesso modello della sessione main), in una worktree treehouse isolata, gli consegna il brief e libera la chat. A fine task il report arriva nella chat (successo senza interruzione; failed/needs_input risvegliano il main agent nel turno).",
    promptSnippet: "Spawn a visible herdr tab sub-agent for a delegation task",
    promptGuidelines: [
      "AUTOMATICALLY call fleet_launch for ANY non-trivial request about a project (~/Documents/GitHub): reading/analyzing, editing, implementing, fixing, testing, refactoring. Do NOT wait for the user to type fleet_launch and do NOT ask for confirmation — delegation is the default. Handle inline ONLY questions answerable from context, fleet management, and trivial one-liners.",
      "project is REQUIRED: derive it from the user's message (e.g. 'mirofish' -> 'MiroFish-private') or the last task's project; ask one short question only if truly ambiguous. Never launch without project. Keep worktree enabled.",
      "For multiple independent requests, launch them in PARALLEL (max 5 per turn) instead of sequentially.",
      "After launching, END YOUR TURN IMMEDIATELY. Do NOT poll, monitor, or re-check with fleet_status/fleet_peek — the report is delivered to the chat automatically (silent on done, waking on failed/needs_input). The chat is free until then.",
    ],
    parameters: Type.Object({
      title: Type.String({ description: "Breve titolo del task" }),
      brief: Type.String({ description: "Istruzioni complete del task (markdown)" }),
      project: Type.String({ description: "Progetto: NOME in ~/Documents/GitHub (es. 'MiroFish-private') o path assoluto. OBBLIGATORIO." }),
      worktree: Type.Optional(Type.Boolean({ description: "Usa una worktree treehouse isolata (default: true)" })),
      model: Type.Optional(Type.String({ description: "Override modello, es. 'opencode-go/deepseek-v4-flash' (default: modello della sessione parent)" })),
      timeoutMin: Type.Optional(Type.Number({ description: "Timeout in minuti (default: 360)" })),
    }),
    async execute(_toolCallId: string, params: FleetLaunchParams, _signal?: unknown, _onUpdate?: unknown, ctx?: { model?: { id?: string } }) {
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

      const task: TaskStateFile = {
        id,
        title: params.title,
        project,
        state: "spawning",
        startedAt: Date.now(),
        lastBeatAt: Date.now(),
        doneAt: null,
        timeoutMs: (params.timeoutMin ?? 360) * 60000,
      };
      writeTask(task);

      const launchParams = { ...params, project };
      // Eredita il modello ATTIVO della sessione main (ctx.model.id): le env
      // PI_MODEL/PI_DEFAULT_MODEL sono statiche all'avvio e NON seguono i
      // cambi a metà sessione (/model, Ctrl+P). model esplicito dell'utente vince.
      const effectiveModel = params.model ?? ctx?.model?.id;
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
            ? `⚑ Task **${params.title}** lanciato (${id}) su **${project}**.`
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
    description: "Lista tutti i task pi-fleet con stato, progetto e pane herdr.",
    promptSnippet: "List active pi-fleet tasks and their states",
    parameters: Type.Object({
      limit: Type.Optional(Type.Number({ description: "Max righe (default: 30)" })),
    }),
    async execute(_toolCallId, params: { limit?: number }) {
      const tasks = listTasks().slice(0, params.limit ?? 30);
      const clean = tasks.map((t) => ({ ...t, briefFile: undefined as string | undefined }));
      const lines = tasks.length ? tasks.map(formatTaskLine) : ["(nessun task)"];
      return {
        content: [{ type: "text", text: `**Flotta pi-fleet (${tasks.length})**:\n${lines.join("\n")}\n\nDettagli strutturati in details.` }],
        details: { tasks: clean },
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
    description: "Interrompe un task pi-fleet: chiude il tab herdr, rilascia la worktree, marca aborted.",
    promptSnippet: "Abort a pi-fleet task (close tab, release worktree)",
    parameters: Type.Object({
      id: Type.String({ description: "Task id (vedi fleet_status)" }),
    }),
    async execute(_toolCallId, params: { id: string }) {
      const task = readTask(params.id);
      let state = "not_found";
      if (task) {
        writeFileSync(join(STATE_HOME, `${task.id}.abort`), `${Date.now()}\n`);
        if (task.tabId) await runHerdr(["tab", "close", task.tabId], 10_000);
        if (task.state === "running" || task.state === "needs_input" || task.state === "spawning") {
          task.state = "aborted";
          writeTask(task);
        }
        state = task.state;
      }
      return {
        content: [{ type: "text", text: state === "aborted" ? `Task ${params.id} in abort (tab chiuso, worktree in rilascio).` : `Task ${params.id}: stato ${state}.` }],
        details: { taskId: params.id, state },
      };
    },
  });

  // --- fleet_attach ---
  pi.registerTool({
    name: "fleet_attach",
    label: "Fleet Attach",
    description: "Porta il focus herdr sul tab di un task pi-fleet per vederlo live (ruba il focus, usalo quando serve).",
    promptSnippet: "Focus the herdr tab of a pi-fleet task",
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
  let generation = 0;
  let stopWatcher: (() => void) | null = null;
  const watch = new Map<string, TaskState>();

  pi.on("session_start", () => {
    if (!IS_CAPTAIN) return;
    generation++;
    stopWatcher?.();
    void (async () => {
      await reconcileStaleTasks();
      stopWatcher = startWatcher(pi, watch);
    })();
    void registerBackgroundWork();
  });

  pi.on("session_shutdown", () => {
    generation++;
    stopWatcher?.();
    stopWatcher = null;
    providerUnregister?.();
    providerUnregister = null;
  });

  void registerBackgroundWorkSafe();
}

/** Nei figli (sessioni pi separate ma NON capitano) il provider non va registrato. */
async function registerBackgroundWorkSafe(): Promise<void> {
  if (!IS_CAPTAIN) return;
  await registerBackgroundWork();
}