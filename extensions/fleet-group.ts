/** pi-fleet · group barrier coordinator — L3.5 */

import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";

// ------------------------------------------------------------------ tipi ---

/** Stato possibile di un task (allineato a TaskStateFile in index.ts). */
export type GroupTaskState = "spawning" | "running" | "done" | "failed" | "aborted" | "needs_input";

/** StatI terminali del gruppo — usati per barrier flush. */
export const GROUP_TERMINAL_STATES: ReadonlySet<GroupTaskState> = new Set<GroupTaskState>([
  "done",
  "failed",
  "aborted",
]);

/** Info minima di un task necessaria al coordinatore barrier. */
export interface GroupTaskInfo {
  id: string;
  title?: string;
  state: GroupTaskState;
  summary?: string;
  changedFiles?: string[];
  groupId: string;
  groupSize: number;
  groupLabel?: string;
  groupMode: "barrier" | "streaming";
}

/**
 * TaskStateFile come scritto su disco da launcher/estensione.
 * Campi gruppo opzionali per retrocompatibilità (task vecchi senza gruppo).
 */
export interface TaskStateFile {
  id: string;
  title?: string;
  project?: string;
  worktree?: boolean;
  cwd?: string;
  briefFile?: string;
  state: GroupTaskState;
  startedAt?: number;
  lastBeatAt?: number;
  doneAt?: number | null;
  timeoutMs?: number;
  paneId?: string;
  tabId?: string;
  workspaceId?: string;
  summary?: string;
  changedFiles?: string[];
  // L3.5 — opzionali, retrocompatibili
  groupId?: string;
  groupSize?: number;
  groupLabel?: string;
  groupMode?: "barrier" | "streaming";
}

/** Record in memoria per un gruppo barrier. */
export interface GroupRecord {
  groupId: string;
  expected: number;
  pending: Set<string>;
  results: Map<string, GroupTaskInfo>;
  createdAt: number;
  label?: string;
}

export type GroupEvent =
  | { kind: "group_complete"; groupId: string; results: GroupTaskInfo[] }
  | { kind: "needs_input"; task: GroupTaskInfo; group: GroupRecord }
  | { kind: "buffered"; taskId: string; groupId: string };

// ----------------------------------------------------------- helpers base ---

/**
 * Ritorna true se lo stato è terminale (done/failed/aborted).
 * needs_input è trattato come caso speciale — NON è terminale qui.
 */
export function isTerminalState(state: string): boolean {
  return GROUP_TERMINAL_STATES.has(state as GroupTaskState);
}

/**
 * Ritorna true se il gruppo è completo (nessun pending rimasto).
 */
export function isGroupComplete(group: GroupRecord): boolean {
  return group.pending.size === 0;
}

/**
 * Decide se il task va bufferizzato invece di svegliare subito.
 * Solo barrier + done/failed viene bufferizzato; streaming mai.
 */
export function shouldBuffer(task: GroupTaskInfo): boolean {
  if (task.groupMode !== "barrier") return false;
  return task.state === "done" || task.state === "failed";
}

// ------------------------------------------------------- conversione task ---

/** Converte un TaskStateFile letto da disco in GroupTaskInfo per il coordinatore. */
export function toGroupTaskInfo(task: TaskStateFile): GroupTaskInfo {
  return {
    id: task.id,
    title: task.title,
    state: task.state,
    summary: task.summary,
    changedFiles: task.changedFiles,
    groupId: task.groupId ?? task.id,
    groupSize: task.groupSize ?? 1,
    groupLabel: task.groupLabel,
    groupMode: task.groupMode ?? "barrier",
  };
}

// ------------------------------------------------------- persistenza su disco ---

interface PersistedGroup {
  groupId: string;
  expected: number;
  pending: string[];
  results: Record<string, GroupTaskInfo>;
  createdAt: number;
  label?: string;
}

function groupsDir(stateHome: string): string {
  return join(stateHome, ".wake-groups");
}

/**
 * Persiste un GroupRecord su disco in modo atomico (tmp + rename).
 * Crea la directory se mancante.
 */
export function persistGroup(stateHome: string, record: GroupRecord): void {
  const dir = groupsDir(stateHome);
  mkdirSync(dir, { recursive: true });
  const payload: PersistedGroup = {
    groupId: record.groupId,
    expected: record.expected,
    pending: [...record.pending],
    results: Object.fromEntries(record.results.entries()),
    createdAt: record.createdAt,
    label: record.label,
  };
  const dest = join(dir, `${record.groupId}.json`);
  const tmp = `${dest}.tmp-${process.pid}-${Date.now()}`;
  writeFileSync(tmp, JSON.stringify(payload, null, 2) + "\n", "utf8");
  renameSync(tmp, dest);
}

/**
 * Carica tutti i gruppi persistiti da STATE_HOME/.wake-groups/*.json.
 * File corrotti vengono ignorati (non bloccano il load).
 */
export function loadGroups(stateHome: string): Map<string, GroupRecord> {
  const dir = groupsDir(stateHome);
  const out = new Map<string, GroupRecord>();
  let names: string[] = [];
  try {
    names = readdirSync(dir);
  } catch {
    return out;
  }
  for (const name of names) {
    if (!name.endsWith(".json")) continue;
    const full = join(dir, name);
    try {
      const raw = readFileSync(full, "utf8");
      const data = JSON.parse(raw) as PersistedGroup;
      if (typeof data.groupId !== "string" || typeof data.expected !== "number") continue;
      const record: GroupRecord = {
        groupId: data.groupId,
        expected: data.expected,
        pending: new Set<string>(Array.isArray(data.pending) ? data.pending : []),
        results: new Map<string, GroupTaskInfo>(
          data.results && typeof data.results === "object"
            ? Object.entries(data.results as Record<string, GroupTaskInfo>)
            : [],
        ),
        createdAt: typeof data.createdAt === "number" ? data.createdAt : Date.now(),
        label: typeof data.label === "string" ? data.label : undefined,
      };
      out.set(record.groupId, record);
    } catch {
      // file corrotto o a metà scrittura — ignora
    }
  }
  return out;
}

/**
 * Rimuove il file persistito di un gruppo (chiamato dopo digest consegnato).
 */
export function removeGroup(stateHome: string, groupId: string): void {
  const p = join(groupsDir(stateHome), `${groupId}.json`);
  try {
    rmSync(p);
  } catch {
    // già rimosso o mai esistito
  }
  // pulisce eventuali tmp orfani dello stesso gruppo
  try {
    const dir = groupsDir(stateHome);
    if (!existsSync(dir)) return;
    for (const name of readdirSync(dir)) {
      if (name.startsWith(`${groupId}.json.tmp-`)) {
        try { rmSync(join(dir, name)); } catch { /* ignore */ }
      }
    }
  } catch { /* ignore */ }
}

// ------------------------------------------------------- getOrCreateGroup ---

/**
 * Recupera un gruppo esistente o ne crea uno nuovo.
 * Se il task riporta expected===1 ma esiste già un record con expected>1,
 * prevale l'expected del record (batch allargato dopo il primo launch).
 */
export function getOrCreateGroup(
  groupMap: Map<string, GroupRecord>,
  info: GroupTaskInfo,
): GroupRecord {
  const gid = info.groupId;
  const existing = groupMap.get(gid);
  if (existing) {
    // se il file task ha expected diverso, tieni il più grande (batch allargato)
    if (info.groupSize > existing.expected) {
      existing.expected = info.groupSize;
    }
    if (info.groupLabel && !existing.label) {
      existing.label = info.groupLabel;
    }
    return existing;
  }
  // crea nuovo record: pending contiene tutti gli id attesi inizialmente
  // se non conosciamo gli id singoli, pending parte con l'id stesso più placeholder
  // ricostruzione più precisa avviene in rebuildGroupsFromDisk
  const pending = new Set<string>();
  // se expected >1 ma conosciamo solo questo id, metti almeno questo id in pending
  // gli altri id verranno aggiunti man mano che i task arrivano o via rebuild
  pending.add(info.id);
  const record: GroupRecord = {
    groupId: gid,
    expected: info.groupSize,
    pending,
    results: new Map<string, GroupTaskInfo>(),
    createdAt: Date.now(),
    label: info.groupLabel,
  };
  groupMap.set(gid, record);
  return record;
}

// ------------------------------------------------------- recordTaskDone ---

/**
 * Logica core della barrier.
 *
 * - Risolve groupId/mode/expected dal task (retrocompatibile).
 * - Se needs_input → evento immediato (rompe la barrier).
 * - Se barrier + done/failed + expected>1 → bufferizza, persiste, e quando pending vuoto → group_complete.
 * - Se singolo (expected===1) → group_complete subito (retrocompatibile).
 */
export function recordTaskDone(
  stateHome: string,
  groupMap: Map<string, GroupRecord>,
  task: TaskStateFile,
): GroupEvent {
  const info = toGroupTaskInfo(task);

  // expected effettivo: se il task dice 1 ma esiste già un gruppo più grande, usa quello
  const existing = groupMap.get(info.groupId);
  const effectiveExpected =
    existing && info.groupSize === 1 && existing.expected > 1 ? existing.expected : info.groupSize;
  info.groupSize = effectiveExpected;

  // ottieni o crea il record
  const group = getOrCreateGroup(groupMap, info);
  // assicurati che expected sia allineato
  if (effectiveExpected > group.expected) group.expected = effectiveExpected;
  if (info.groupLabel && !group.label) group.label = info.groupLabel;

  // needs_input rompe sempre la barrier — wake immediato
  if (task.state === "needs_input") {
    // non bufferizzare, non marcare come result
    // assicurati che il gruppo sia persistito per recovery (pending resta)
    try {
      persistGroup(stateHome, group);
    } catch { /* best-effort */ }
    return { kind: "needs_input", task: info, group };
  }

  // singolo → completo subito (nessun buffering)
  if (group.expected <= 1) {
    // per coerenza, aggiungi a results e svuota pending
    group.results.set(info.id, info);
    group.pending.delete(info.id);
    // single non necessita persistenza barrier, ma pulisci eventuale file orfano
    try { removeGroup(stateHome, group.groupId); } catch { /* ignore */ }
    return { kind: "group_complete", groupId: group.groupId, results: [info] };
  }

  // gruppo multi-task: decide se bufferizzare
  if (shouldBuffer(info)) {
    group.results.set(info.id, info);
    group.pending.delete(info.id);
    // se pending era inizialmente solo con questo id (gruppo creato lazy),
    // pending ora è vuoto ma expected dice 3 → non è davvero completo.
    // Correggi: se results.size < expected, il gruppo NON è completo anche se pending vuoto.
    // In quel caso pending va ricostruito come "mancanti" e NON emettiamo group_complete.
    // Tuttavia la strategia corretta è: pending contiene gli id mancanti noti.
    // Se abbiamo creato il gruppo con un solo id ma expected=3, pending.size==0 dopo
    // la prima rimozione significa che non conosciamo ancora gli altri id.
    // Usiamo la size di results per capire se siamo davvero a quota expected.
    const reallyComplete = group.results.size >= group.expected && group.pending.size === 0;

    // Se non siamo completi ma pending è vuoto, non persistiamo come "completo":
    // teniamo pending vuoto ma results.size < expected → buffered.
    // Il completamento scatterà quando results.size == expected.
    // Per evitare falso group_complete alla prima scrittura lazy, controlla results.size.
    try {
      persistGroup(stateHome, group);
    } catch { /* best-effort */ }

    if (reallyComplete || (group.results.size === group.expected)) {
      // tutti arrivati
      const sorted = [...group.results.values()].sort((a, b) =>
        (a.title ?? a.id).localeCompare(b.title ?? b.id),
      );
      return { kind: "group_complete", groupId: group.groupId, results: sorted };
    }
    // se pending vuoto ma non tutti i results arrivati (gruppo lazy), resta buffered
    // il chiamante non deve svegliare
    return { kind: "buffered", taskId: info.id, groupId: group.groupId };
  }

  // streaming o stato non bufferizzato (aborted, running, etc.) → group_complete immediato
  // (aborted in barrier: lo trattiamo come wake immediato con contesto gruppo)
  if (isTerminalState(info.state)) {
    group.results.set(info.id, info);
    group.pending.delete(info.id);
    try { persistGroup(stateHome, group); } catch { /* best-effort */ }
    if (isGroupComplete(group) && group.results.size >= group.expected) {
      const sorted = [...group.results.values()].sort((a, b) =>
        (a.title ?? a.id).localeCompare(b.title ?? b.id),
      );
      return { kind: "group_complete", groupId: group.groupId, results: sorted };
    }
    // se terminale ma gruppo non ancora completo, comunque buffered per non perdere il result
    // (il digest arriverà quando l'ultimo finisce). Per aborted dentro barrier preferiamo buffered.
    if (group.expected > 1 && info.groupMode === "barrier") {
      return { kind: "buffered", taskId: info.id, groupId: group.groupId };
    }
    return { kind: "group_complete", groupId: group.groupId, results: [info] };
  }

  // non terminale (spawning/running) — non dovrebbe arrivare a recordTaskDone, ma gestito
  return { kind: "buffered", taskId: info.id, groupId: group.groupId };
}

// ------------------------------------------------ rebuildGroupsFromDisk ---

/**
 * Ricostruisce i gruppi scansionando tutti i TaskStateFile su disco.
 * Usato al restart di Pi per recuperare lo stato barrier dopo chiusura.
 *
 * - Raggruppa per groupId (fallback task.id).
 * - Per ogni gruppo calcola pending (spawning|running|needs_input) e results (terminali).
 * - expected = max tra groupSize dichiarato e cardinalità reale del gruppo.
 */
export function rebuildGroupsFromDisk(
  stateHome: string,
  allTasks: TaskStateFile[],
): Map<string, GroupRecord> {
  // prima prova a caricare quelli persistiti (hanno label/createdAt più fedeli)
  const persisted = loadGroups(stateHome);
  const grouped = new Map<string, TaskStateFile[]>();

  for (const t of allTasks) {
    const gid = t.groupId ?? t.id;
    const arr = grouped.get(gid);
    if (arr) arr.push(t);
    else grouped.set(gid, [t]);
  }

  const out = new Map<string, GroupRecord>();

  for (const [gid, tasks] of grouped) {
    const maxDeclared = Math.max(...tasks.map((t) => t.groupSize ?? 1), 1);
    // expected è il max tra dichiarato e cardinalità reale
    const expected = Math.max(maxDeclared, tasks.length);
    const label = tasks.find((t) => t.groupLabel)?.groupLabel ?? persisted.get(gid)?.label;
    const createdAt =
      persisted.get(gid)?.createdAt ??
      Math.min(...tasks.map((t) => t.startedAt ?? Date.now()));

    const pending = new Set<string>();
    const results = new Map<string, GroupTaskInfo>();

    // se esiste un record persistito, parti da quello e riconcilia
    const base = persisted.get(gid);
    if (base) {
      for (const [k, v] of base.results) results.set(k, v);
      for (const pid of base.pending) pending.add(pid);
    }

    for (const t of tasks) {
      const info = toGroupTaskInfo(t);
      // allinea groupSize al gid effettivo
      info.groupId = gid;
      if (isTerminalState(t.state)) {
        results.set(t.id, info);
        pending.delete(t.id);
      } else if (t.state === "needs_input") {
        pending.add(t.id);
      } else {
        // spawning | running → pending
        pending.add(t.id);
        // rimuovi da results se per caso era stato messo
        results.delete(t.id);
      }
    }

    // se non c'è base persistita e pending è vuoto ma non tutti terminali, ricostruisci
    // (caso: task appena creati)
    if (!base && pending.size === 0 && results.size < expected) {
      // mancano task non ancora comparsi su disco — pendings impliciti
      // non possiamo conoscere gli id, lasciamo pending vuoto ma expected tiene il conto
      // il completamento scatterà quando results.size == expected
    }

    const record: GroupRecord = {
      groupId: gid,
      expected,
      pending,
      results,
      createdAt,
      label,
    };
    out.set(gid, record);
  }

  // includi anche gruppi persistiti che non hanno più task su disco (orfani)
  for (const [gid, rec] of persisted) {
    if (!out.has(gid)) out.set(gid, rec);
  }

  return out;
}

// Helper per fleet_status: sintetizza gruppi da lista task (usato da index.ts)
export function buildGroupSummaries(
  tasks: Array<{ id: string; state: string; groupId?: string; groupSize?: number; groupLabel?: string }>,
): Array<{ groupId: string; label?: string; expected: number; done: number; pendingIds: string[] }> {
  const byGroup = new Map<string, typeof tasks>();
  for (const t of tasks) {
    const gid = t.groupId ?? t.id;
    const size = t.groupSize ?? 1;
    if (size <= 1 && !t.groupId) continue;
    if (!byGroup.has(gid)) byGroup.set(gid, []);
    byGroup.get(gid)!.push(t);
  }
  const out: Array<{ groupId: string; label?: string; expected: number; done: number; pendingIds: string[] }> = [];
  for (const [gid, members] of byGroup) {
    const expected = Math.max(members[0]?.groupSize ?? members.length, members.length);
    const done = members.filter((m) => isTerminalState(m.state)).length;
    const pendingIds = members.filter((m) => !isTerminalState(m.state)).map((m) => m.id);
    const label = members.find((m) => m.groupLabel)?.groupLabel;
    out.push({ groupId: gid, label, expected, done, pendingIds });
  }
  return out;
}

// --------------------------------------------------- formatGroupDigest ---

/**
 * Genera il markdown verboso del digest di gruppo.
 * Ordina per title (fallback id), include summary integrale e changedFiles.
 */
export function formatGroupDigest(group: GroupRecord | string, resultsSorted: GroupTaskInfo[], label?: string): string {
  // Overload: se group è string (groupId), costruisci header da results/label
  const groupId = typeof group === "string" ? group : group.groupId;
  const total = typeof group === "string" ? resultsSorted.length : group.expected;
  const groupLabel = typeof group === "string" ? label ?? resultsSorted.find((r) => r.groupLabel)?.groupLabel : group.label;
  const done = resultsSorted.length;
  const labelPart = groupLabel ? ` "${groupLabel}"` : "";
  const header = `\u2691 pi-fleet \u2014 gruppo${labelPart} completo (${done}/${total}) \u2014 ${groupId}`;

  const sections = resultsSorted
    .slice()
    .sort((a, b) => (a.title ?? a.id).localeCompare(b.title ?? b.id))
    .map((r, idx) => {
      const title = r.title ?? r.id;
      const stateLabel = r.state;
      const summary = (r.summary ?? "").trim() || "(nessuna summary)";
      const files = r.changedFiles?.length
        ? `\nFile cambiati: ${r.changedFiles.map((f) => "`" + f + "`").join(", ")}`
        : "";
      return `## Task ${idx + 1} \u2014 ${title} [${stateLabel}]\nRisultato:\n${summary}${files}`;
    });

  return [header, ...sections].join("\n\n");
}
