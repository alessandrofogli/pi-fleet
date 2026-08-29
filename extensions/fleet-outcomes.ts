/** pi-fleet · branch outcomes / audit trail — T-004 */

import { appendFileSync, mkdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";

// ------------------------------------------------------------------ types ---

/** Verdict written to the registry for a relevant task transition. */
export type OutcomeVerdict = "done" | "failed" | "aborted" | "needs_input";

/** Line of the append-only branch-outcomes.jsonl registry (one line = one JSON). */
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
 * Minimal task shape required by appendOutcome, aligned with TaskStateFile
 * (index.ts / fleet-group.ts) but without a static dependency on either.
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
 * In-process dedup: Map<taskId + verdict + doneAt, true>.
 * The same transition is never written twice — neither on duplicate calls from
 * the same process nor when watcher+reconcile touch the same task in the same round.
 */
const _seen = new Map<string, true>();

function dedupKey(taskId: string, verdict: OutcomeVerdict, ts: number): string {
  return `${taskId}\u0000${verdict}\u0000${ts}`;
}

// ------------------------------------------------------------------ file ---

/** Registry path: <stateHome>/branch-outcomes.jsonl (append-only). */
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
      // spawning/running/other: not a relevant transition → no line
      return null;
  }
}

/**
 * Appends a line to the registry (best-effort, sync).
 *
 * - In-memory dedup by (taskId, verdict, doneAt): the same transition
 *   can arrive from multiple hooks (watcher, reconcile, fleet_abort) but is
 *   written only once.
 * - Fields always present; reportPath null if absent on the task.
 * - fs.appendFileSync with weak retry (1 retry); any error is swallowed:
 *   the registry must NEVER break the wake.
 *
 * @returns true if the line was written, false if duplicated/skipped/error.
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
        // weak retry: give up on the second failed attempt (best-effort)
        if (attempt === 1) return false;
      }
    }
    if (written) _seen.set(key, true);
    return written;
  } catch {
    // never propagate: the caller is on the wake/digest path
    return false;
  }
}

/**
 * Reads the registry, filters and returns the last N lines (default limit 20)
 * in chronological order (= file order, append-only).
 *
 * - project: partial (case-sensitive) match on the project path.
 * - verdict: done|failed|aborted|needs_input.
 * - fromTs: only lines with ts >= fromTs.
 * - Corrupted lines: ignored (append-only, never touch the file).
 */
export function queryOutcomes(stateHome: string, opts: OutcomeQuery = {}): string[] {
  const { limit = 20, project, verdict, fromTs } = opts;
  const file = outcomesFile(stateHome);
  let raw = "";
  try {
    raw = readFileSync(file, "utf8");
  } catch {
    // file not created yet → no results
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
      // corrupted or mid-write line — ignore
    }
  }
  return matched.slice(-Math.max(1, limit));
}