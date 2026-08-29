/** pi-fleet · branch outcomes / audit trail — T-004 */

import { appendFileSync, mkdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";

// ------------------------------------------------------------------ tipi ---

/** Verdetto scritto nel registro per una transizione rilevante del task. */
export type OutcomeVerdict = "done" | "failed" | "aborted" | "needs_input";

/** Riga del registro append-only branch-outcomes.jsonl (una riga = un JSON). */
export interface BranchOutcome {
  ts: number;
  taskId: string;
  title: string;
  project: string;
  verdict: OutcomeVerdict;
  summary: string;
  changedFiles: string[];
  reportPath: string | null;
  groupId: string | null;
}

/**
 * Shape minima del task richiesta da appendOutcome, allineata a TaskStateFile
 * (index.ts / fleet-group.ts) ma senza dipendenza statica sull'uno o sull'altro.
 */
export interface OutcomeTask {
  id: string;
  title?: string;
  project?: string;
  state: string;
  doneAt?: number | null;
  summary?: string;
  changedFiles?: string[];
  reportPath?: string | null;
  groupId?: string;
}

export interface OutcomeQuery {
  limit?: number;
  project?: string;
  verdict?: OutcomeVerdict;
  fromTs?: number;
}

// ------------------------------------------------------------------ dedup ---

/**
 * Dedup in-process: Map<taskId + verdict + doneAt, true>.
 * La stessa transizione non viene scritta due volte — né nelle chiamate
 * duplicate dello stesso processo né nel caso watcher+reconcile tocchino
 * lo stesso task nello stesso giro.
 */
const _seen = new Map<string, true>();

function dedupKey(taskId: string, verdict: OutcomeVerdict, ts: number): string {
  return `${taskId}\u0000${verdict}\u0000${ts}`;
}

// ------------------------------------------------------------------ file ---

/** Path del registro: <stateHome>/branch-outcomes.jsonl (append-only). */
export function outcomesFile(stateHome: string): string {
  return join(stateHome, "branch-outcomes.jsonl");
}

function verdictFor(state: string): OutcomeVerdict | null {
  switch (state) {
    case "done":
    case "failed":
    case "aborted":
    case "needs_input":
      return state;
    default:
      // spawning/running/altro: transizione non rilevante → niente riga
      return null;
  }
}

/**
 * Appende una riga al registro (best-effort, sync).
 *
 * - Dedup in memoria per (taskId, verdict, doneAt): la stessa transizione
 *   può arrivare da più hook (watcher, reconcile, fleet_abort) ma viene
 *   scritta una volta sola.
 * - Campi sempre presenti; reportPath null se assente sul task.
 * - fs.appendFileSync con weak retry (1 riprova); qualsiasi errore
 *   viene inghiottito: il registro non deve MAI rompere il wake.
 *
 * @returns true se la riga è stata scritta, false se duplicata/saltata/errore.
 */
export function appendOutcome(stateHome: string, task: OutcomeTask): boolean {
  try {
    const verdict = verdictFor(task.state);
    if (!verdict) return false;
    const ts = task.doneAt ?? Date.now();
    const key = dedupKey(task.id, verdict, ts);
    if (_seen.has(key)) return false;
    const line: BranchOutcome = {
      ts,
      taskId: task.id,
      title: task.title ?? task.id,
      project: task.project ?? "",
      verdict,
      summary: task.summary ?? "",
      changedFiles: Array.isArray(task.changedFiles) ? task.changedFiles : [],
      reportPath: task.reportPath ?? null,
      groupId: task.groupId ?? null,
    };
    const file = outcomesFile(stateHome);
    const payload = JSON.stringify(line) + "\n";
    let written = false;
    for (let attempt = 0; attempt < 2 && !written; attempt++) {
      try {
        mkdirSync(dirname(file), { recursive: true });
        appendFileSync(file, payload, "utf8");
        written = true;
      } catch {
        // weak retry: al secondo tentativo fallito si rinuncia (best-effort)
        if (attempt === 1) return false;
      }
    }
    if (written) _seen.set(key, true);
    return written;
  } catch {
    // mai propagare: il chiamante è nel percorso di wake/digest
    return false;
  }
}

/**
 * Legge il registro, filtra e ritorna le ultime N righe (limite default 20)
 * in ordine cronologico (= ordine del file, append-only).
 *
 * - project: match parziale (case-sensitive) sul percorso del progetto.
 * - verdict: done|failed|aborted|needs_input.
 * - fromTs: solo righe con ts >= fromTs.
 * - Righe corrotte: ignorate (append-only, mai toccare il file).
 */
export function queryOutcomes(stateHome: string, opts: OutcomeQuery = {}): string[] {
  const { limit = 20, project, verdict, fromTs } = opts;
  const file = outcomesFile(stateHome);
  let raw = "";
  try {
    raw = readFileSync(file, "utf8");
  } catch {
    // file non ancora creato → nessun risultato
    return [];
  }
  const lines = raw.split("\n").filter((l) => l.trim().length > 0);
  const matched: string[] = [];
  for (const line of lines) {
    try {
      const o = JSON.parse(line) as BranchOutcome;
      if (typeof o !== "object" || o === null || typeof o.taskId !== "string") continue;
      if (fromTs !== undefined && (o.ts ?? 0) < fromTs) continue;
      if (project && !(o.project ?? "").includes(project)) continue;
      if (verdict && o.verdict !== verdict) continue;
      matched.push(line);
    } catch {
      // riga corrotta o a metà scrittura — ignora
    }
  }
  return matched.slice(-Math.max(1, limit));
}