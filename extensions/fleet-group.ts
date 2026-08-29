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

// ------------------------------------------------------------------ types ---

/** Possible state of a task (aligned with TaskStateFile in index.ts). */
export type GroupTaskState = "spawning" | "running" | "done" | "failed" | "aborted" | "needs_input";

/** Terminal states of the group — used for barrier flush. */
export const GROUP_TERMINAL_STATES: ReadonlySet<GroupTaskState> = new Set<GroupTaskState>([
  "done",
  "failed",
  "aborted",
]);

/** Minimal task info needed by the barrier coordinator. */
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
  kind?: "ship" | "scout";
  /** Group failure policy: waitAll (default) | immediate (a failed task wakes right away). */
  groupFailPolicy?: "waitAll" | "immediate";
}

/**
 * TaskStateFile as written to disk by launcher/extension.
 * Optional group fields for backward compatibility (old tasks without a group).
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
  kind?: "ship" | "scout";
  groupFailPolicy?: "waitAll" | "immediate";
}

/** In-memory record for a barrier group. */
export interface GroupRecord {
  groupId: string;
  expected: number;
  pending: Set<string>;
  results: Map<string, GroupTaskInfo>;
  createdAt: number;
  label?: string;
  /** Failure policy: waitAll (default) | immediate (a failed task wakes right away). */
  failPolicy?: "waitAll" | "immediate";
}

export type GroupEvent =
  | { kind: "group_complete"; groupId: string; results: GroupTaskInfo[] }
  | { kind: "needs_input"; task: GroupTaskInfo; group: GroupRecord }
  | { kind: "group_failed_immediate"; task: GroupTaskInfo; group: GroupRecord }
  | { kind: "buffered"; taskId: string; groupId: string };

// ----------------------------------------------------------- helpers base ---

/**
 * Returns true if the state is terminal (done/failed/aborted).
 * needs_input is treated as a special case — NOT terminal here.
 */
export function isTerminalState(state: string): boolean {
  return GROUP_TERMINAL_STATES.has(state as GroupTaskState);
}

/**
 * Returns true if the group is complete (no pending left).
 */
export function isGroupComplete(group: GroupRecord): boolean {
  return group.pending.size === 0;
}

/**
 * Decides whether the task should be buffered instead of waking right away.
 * Only barrier + done/failed is buffered; streaming never.
 * Exception: with groupFailPolicy "immediate" the FAILED is not buffered
 * (wakes right away); done/aborted stay waitAll even with the immediate policy.
 */
export function shouldBuffer(task: GroupTaskInfo): boolean {
  if (task.groupMode !== "barrier") return false;
  if (task.state === "failed" && task.groupFailPolicy === "immediate") return false;
  return task.state === "done" || task.state === "failed";
}

// ------------------------------------------------------- task conversion ---

/** Converts a TaskStateFile read from disk into GroupTaskInfo for the coordinator. */
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
    kind: task.kind,
    groupFailPolicy: task.groupFailPolicy,
  };
}

// ------------------------------------------------------- disk persistence ---

interface PersistedGroup {
  groupId: string;
  expected: number;
  pending: string[];
  results: Record<string, GroupTaskInfo>;
  createdAt: number;
  label?: string;
  failPolicy?: "waitAll" | "immediate";
}

function groupsDir(stateHome: string): string {
  return join(stateHome, ".wake-groups");
}

/**
 * Persists a GroupRecord to disk atomically (tmp + rename).
 * Creates the directory if missing.
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
    failPolicy: record.failPolicy,
  };
  const dest = join(dir, `${record.groupId}.json`);
  const tmp = `${dest}.tmp-${process.pid}-${Date.now()}`;
  writeFileSync(tmp, JSON.stringify(payload, null, 2) + "\n", "utf8");
  renameSync(tmp, dest);
}

/**
 * Loads all persisted groups from STATE_HOME/.wake-groups/*.json.
 * Corrupted files are ignored (they don't block the load).
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
        // backward compatible: file without failPolicy → waitAll (default)
        failPolicy:
          data.failPolicy === "immediate"
            ? "immediate"
            : data.failPolicy === "waitAll"
              ? "waitAll"
              : undefined,
      };
      out.set(record.groupId, record);
    } catch {
      // corrupted or mid-write file — ignore
    }
  }
  return out;
}

/**
 * Removes a group's persisted file (called after the digest is delivered).
 */
export function removeGroup(stateHome: string, groupId: string): void {
  const p = join(groupsDir(stateHome), `${groupId}.json`);
  try {
    rmSync(p);
  } catch {
    // already removed or never existed
  }
  // cleans up possible orphan tmps of the same group
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
 * Gets an existing group or creates a new one.
 * If the task reports expected===1 but a record with expected>1 already exists,
 * the record's expected wins (batch enlarged after the first launch).
 */
export function getOrCreateGroup(
  groupMap: Map<string, GroupRecord>,
  info: GroupTaskInfo,
): GroupRecord {
  const gid = info.groupId;
  const existing = groupMap.get(gid);
  if (existing) {
    // if the task file has a different expected, keep the largest (enlarged batch)
    if (info.groupSize > existing.expected) {
      existing.expected = info.groupSize;
    }
    if (info.groupLabel && !existing.label) {
      existing.label = info.groupLabel;
    }
    if (info.groupFailPolicy === "immediate" && !existing.failPolicy) {
      existing.failPolicy = info.groupFailPolicy;
    }
    return existing;
  }
  // create a new record: pending holds all the initially expected ids
  // if we don't know the individual ids, pending starts with this id plus placeholder
  // a more precise reconstruction happens in rebuildGroupsFromDisk
  const pending = new Set<string>();
  // if expected >1 but we only know this id, put at least this id in pending
  // the other ids will be added as tasks arrive or via rebuild
  pending.add(info.id);
  const record: GroupRecord = {
    groupId: gid,
    expected: info.groupSize,
    pending,
    results: new Map<string, GroupTaskInfo>(),
    createdAt: Date.now(),
    label: info.groupLabel,
    failPolicy: info.groupFailPolicy,
  };
  groupMap.set(gid, record);
  return record;
}

// ------------------------------------------------------- recordTaskDone ---

/**
 * Core barrier logic.
 *
 * - Resolves groupId/mode/expected from the task (backward compatible).
 * - If needs_input → immediate event (breaks the barrier).
 * - If barrier + done/failed + expected>1 → buffers, persists, and when pending is empty → group_complete.
 * - If single (expected===1) → group_complete right away (backward compatible).
 */
export function recordTaskDone(
  stateHome: string,
  groupMap: Map<string, GroupRecord>,
  task: TaskStateFile,
): GroupEvent {
  const info = toGroupTaskInfo(task);

  // effective expected: if the task says 1 but a bigger group already exists, use that
  const existing = groupMap.get(info.groupId);
  const effectiveExpected =
    existing && info.groupSize === 1 && existing.expected > 1 ? existing.expected : info.groupSize;
  info.groupSize = effectiveExpected;

  // get or create the record
  const group = getOrCreateGroup(groupMap, info);
  // make sure expected is aligned
  if (effectiveExpected > group.expected) group.expected = effectiveExpected;
  if (info.groupLabel && !group.label) group.label = info.groupLabel;
  if (info.groupFailPolicy === "immediate" && !group.failPolicy) group.failPolicy = info.groupFailPolicy;

  // needs_input always breaks the barrier — immediate wake
  if (task.state === "needs_input") {
    // don't buffer, don't mark as result
    // make sure the group is persisted for recovery (pending stays)
    try {
      persistGroup(stateHome, group);
    } catch { /* best-effort */ }
    return { kind: "needs_input", task: info, group };
  }

  // single → complete right away (no buffering)
  if (group.expected <= 1) {
    // for consistency, add to results and empty pending
    group.results.set(info.id, info);
    group.pending.delete(info.id);
    // single does not need barrier persistence, but clean up any orphan file
    try { removeGroup(stateHome, group.groupId); } catch { /* ignore */ }
    return { kind: "group_complete", groupId: group.groupId, results: [info] };
  }

  // multi-task group + groupFailPolicy "immediate" + failed → wake NOW.
  // Does NOT buffer, but still records the result in the group and persists:
  // the group stays pending and the digest fires when the others finish.
  // done/aborted stay waitAll (buffered) even with the immediate policy.
  if (task.state === "failed" && info.groupFailPolicy === "immediate") {
    group.results.set(info.id, info);
    group.pending.delete(info.id);
    try { persistGroup(stateHome, group); } catch { /* best-effort */ }
    return { kind: "group_failed_immediate", task: info, group };
  }

  // multi-task group: decide whether to buffer
  if (shouldBuffer(info)) {
    group.results.set(info.id, info);
    group.pending.delete(info.id);
    // if pending initially held only this id (group created lazily),
    // pending is now empty but expected says 3 → not really complete.
    // Fix: if results.size < expected, the group is NOT complete even if pending is empty.
    // In that case pending should be rebuilt as "missing" and we must NOT emit group_complete.
    // However the correct strategy is: pending holds the known missing ids.
    // If we created the group with a single id but expected=3, pending.size==0 after
    // the first removal means we still don't know the other ids.
    // We use the results size to understand whether we are really at the expected count.
    const reallyComplete = group.results.size >= group.expected && group.pending.size === 0;

    // If we are not complete but pending is empty, we don't persist as "complete":
    // we keep pending empty but results.size < expected → buffered.
    // Completion will fire when results.size == expected.
    // To avoid a false group_complete on the first lazy write, check results.size.
    try {
      persistGroup(stateHome, group);
    } catch { /* best-effort */ }

    if (reallyComplete || (group.results.size === group.expected)) {
      // all arrived
      const sorted = [...group.results.values()].sort((a, b) =>
        (a.title ?? a.id).localeCompare(b.title ?? b.id),
      );
      return { kind: "group_complete", groupId: group.groupId, results: sorted };
    }
    // if pending is empty but not all results arrived (lazy group), stays buffered
    // the caller must not wake
    return { kind: "buffered", taskId: info.id, groupId: group.groupId };
  }

  // streaming or non-buffered state (aborted, running, etc.) → immediate group_complete
  // (aborted in barrier: we treat it as an immediate wake with group context)
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
    // if terminal but the group is not complete yet, still buffered to not lose the result
    // (the digest will arrive when the last one finishes). For aborted inside a barrier we prefer buffered.
    if (group.expected > 1 && info.groupMode === "barrier") {
      return { kind: "buffered", taskId: info.id, groupId: group.groupId };
    }
    return { kind: "group_complete", groupId: group.groupId, results: [info] };
  }

  // non-terminal (spawning/running) — should not reach recordTaskDone, but handled
  return { kind: "buffered", taskId: info.id, groupId: group.groupId };
}

// ------------------------------------------------ rebuildGroupsFromDisk ---

/**
 * Rebuilds the groups by scanning all TaskStateFiles on disk.
 * Used at Pi restart to recover the barrier state after closure.
 *
 * - Groups by groupId (fallback task.id).
 * - For each group computes pending (spawning|running|needs_input) and results (terminal).
 * - expected = max between declared groupSize and the group's real cardinality.
 */
export function rebuildGroupsFromDisk(
  stateHome: string,
  allTasks: TaskStateFile[],
): Map<string, GroupRecord> {
  // first try loading the persisted ones (they have more faithful label/createdAt)
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
    // expected is the max between declared and real cardinality
    const expected = Math.max(maxDeclared, tasks.length);
    const label = tasks.find((t) => t.groupLabel)?.groupLabel ?? persisted.get(gid)?.label;
    // group policy: tasks with explicit immediate win, then the persisted one
    const failPolicy =
      tasks.find((t) => t.groupFailPolicy === "immediate")?.groupFailPolicy ??
      persisted.get(gid)?.failPolicy;
    const createdAt =
      persisted.get(gid)?.createdAt ??
      Math.min(...tasks.map((t) => t.startedAt ?? Date.now()));

    const pending = new Set<string>();
    const results = new Map<string, GroupTaskInfo>();

    // if a persisted record exists, start from it and reconcile
    const base = persisted.get(gid);
    if (base) {
      for (const [k, v] of base.results) results.set(k, v);
      for (const pid of base.pending) pending.add(pid);
    }

    for (const t of tasks) {
      const info = toGroupTaskInfo(t);
      // align groupSize to the effective gid
      info.groupId = gid;
      if (isTerminalState(t.state)) {
        results.set(t.id, info);
        pending.delete(t.id);
      } else if (t.state === "needs_input") {
        pending.add(t.id);
      } else {
        // spawning | running → pending
        pending.add(t.id);
        // remove from results if it had been put there by chance
        results.delete(t.id);
      }
    }

    // if there is no persisted base and pending is empty but not all are terminal, rebuild
    // (case: just-created tasks)
    if (!base && pending.size === 0 && results.size < expected) {
      // tasks not yet appeared on disk — implicit pendings
      // we cannot know the ids, we leave pending empty but expected keeps the count
      // completion will fire when results.size == expected
    }

    const record: GroupRecord = {
      groupId: gid,
      expected,
      pending,
      results,
      createdAt,
      label,
      failPolicy,
    };
    out.set(gid, record);
  }

  // also include persisted groups that no longer have tasks on disk (orphans)
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
 * Generates the group digest - CONCISE, without verbose subagent dumps.
 * Only header + list of titles/states. The main will give the synthetic account.
 */
export function formatGroupDigest(group: GroupRecord | string, resultsSorted: GroupTaskInfo[], label?: string): string {
  const groupId = typeof group === "string" ? group : group.groupId;
  const total = typeof group === "string" ? resultsSorted.length : group.expected;
  const groupLabel = typeof group === "string" ? label ?? resultsSorted.find((r) => r.groupLabel)?.groupLabel : group.label;
  const done = resultsSorted.length;
  const labelPart = groupLabel ? ` "${groupLabel}"` : "";
  const header = `\u2691 pi-fleet \u2014 group${labelPart} complete (${done}/${total}) \u2014 ${groupId}`;
  const list = resultsSorted
    .slice()
    .sort((a, b) => (a.title ?? a.id).localeCompare(b.title ?? b.id))
    .map((r) => `- ${r.title ?? r.id} [${r.state}]`)
    .join("\n");
  return `${header}\n${list}\n\nProvide a concise account for the group (do not repeat the subagent reports verbatim).`;
}
