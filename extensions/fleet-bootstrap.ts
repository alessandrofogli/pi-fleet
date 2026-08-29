/** pi-fleet · bootstrap at session_start (T-006) */

import { spawnSync } from "node:child_process";
import { existsSync, readdirSync, renameSync, rmSync, statSync } from "node:fs";
import { join } from "node:path";

// ------------------------------------------------------------------ types ---

/** Outcome of a binary tool check. `auth` is present only for `gh`. */
export interface CheckedTool {
  tool: string;
  ok: boolean;
  path?: string;
  auth?: boolean;
}

/**
 * Minimal view of a task needed for digest/cleanup.
 * Structural with TaskStateFile (index.ts): no runtime import.
 */
export interface FleetTaskLike {
  id: string;
  title?: string;
  state: string;
  startedAt?: number;
  lastBeatAt?: number;
  groupId?: string;
  groupSize?: number;
  groupLabel?: string;
  paneId?: string;
}

/** Group summary as produced by buildGroupSummaries (fleet-group.ts). */
export interface GroupSummaryLike {
  groupId: string;
  label?: string;
  expected: number;
  done: number;
  pendingIds: string[];
}

// ------------------------------------------------------------- checkTools ---

/** Binary tools to verify at session_start (zero-config, report only). */
const BIN_TOOLS = ["jq", "herdr", "treehouse", "git", "gh"] as const;

/**
 * Verifies the presence of the binary tools via `which` (spawnSync).
 * For `gh` it adds `auth` = outcome of `gh auth status` (informative).
 * Installs nothing: only reports.
 */
export function checkTools(): CheckedTool[] {
  const out: CheckedTool[] = [];
  for (const tool of BIN_TOOLS) {
    try {
      const which = spawnSync("which", [tool], { encoding: "utf8" });
      const ok = which.status === 0;
      const path = ok ? (which.stdout ?? "").trim() : undefined;
      if (tool === "gh" && ok) {
        const auth = spawnSync("gh", ["auth", "status"], { encoding: "utf8" });
        out.push({ tool, ok, path, auth: auth.status === 0 });
      } else {
        out.push({ tool, ok, path });
      }
    } catch {
      out.push({ tool, ok: false });
    }
  }
  return out;
}

// ----------------------------------------------------------- cleanupStale ---

const ACTIVE_STATES = new Set(["spawning", "running", "needs_input"]);
const STALE_BAD_MS = 7 * 24 * 60 * 60 * 1000; // 7 days

/**
 * SAFE cleanup of the state on disk (never destructive on active tasks):
 *  - orphan `<id>.done.json` markers (no matching `<id>.json`)
 *    → moved to `<id>.done.json.orphan`;
 *  - `<id>.json.bad` files older than 7 days → deleted;
 *  - active tasks whose herdr pane no longer exists and without done-marker:
 *    NOT touched here (that's `reconcileStaleTasks` in index.ts) — only reported.
 *
 * Returns the list of executed/reported actions (textual descriptions).
 */
export function cleanupStale(stateHome: string, listTasks: () => FleetTaskLike[]): string[] {
  const actions: string[] = [];
  let names: string[] = [];
  try {
    names = readdirSync(stateHome);
  } catch {
    return actions;
  }

  // 1) orphan done-markers → <id>.done.json.orphan
  for (const name of names) {
    if (!name.endsWith(".done.json")) continue;
    const id = name.slice(0, -".done.json".length);
    try {
      if (!existsSync(join(stateHome, `${id}.json`))) {
        renameSync(join(stateHome, name), join(stateHome, `${name}.orphan`));
        actions.push(`moved orphan marker ${name} → ${name}.orphan`);
      }
    } catch {
      /* best-effort */
    }
  }

  // 2) old .json.bad files (>7 days) → delete
  const now = Date.now();
  for (const name of names) {
    if (!name.endsWith(".json.bad")) continue;
    try {
      const st = statSync(join(stateHome, name));
      if (now - st.mtimeMs > STALE_BAD_MS) {
        rmSync(join(stateHome, name));
        actions.push(`removed ${name} (older than 7 days)`);
      }
    } catch {
      /* best-effort */
    }
  }

  // 3) report active tasks without a herdr pane (DO NOT touch: reconcileStaleTasks)
  try {
    const res = spawnSync(
      "herdr",
      ["--session", process.env.HERDR_SESSION ?? "default", "agent", "list"],
      { encoding: "utf8", timeout: 10_000 },
    );
    if (res.status === 0) {
      const panes = new Set<string>();
      try {
        const parsed = JSON.parse(res.stdout || "{}") as {
          result?: { agents?: Array<{ pane_id?: string }> };
        };
        for (const a of parsed.result?.agents ?? []) if (a.pane_id) panes.add(a.pane_id);
      } catch {
        /* parse failed: no report */
      }
      if (panes.size > 0) {
        const zombies = listTasks().filter(
          (t) =>
            ACTIVE_STATES.has(t.state) &&
            !!t.paneId &&
            !panes.has(t.paneId) &&
            !existsSync(join(stateHome, `${t.id}.done.json`)),
        );
        if (zombies.length > 0) {
          actions.push(`found ${zombies.length} active tasks without a herdr pane (handled by reconcileStaleTasks)`);
        }
      }
    }
  } catch {
    /* herdr absent or error → fail soft, no report */
  }

  return actions;
}

// ------------------------------------------------------------- fleetDigest ---

/**
 * Short fleet digest: totals per state, active groups (reuses the group logic
 * if available via `groupSummaries`, otherwise a simple count),
 * most relevant needs_input tasks.
 */
export function fleetDigest(
  stateHome: string,
  listTasks: () => FleetTaskLike[],
  groupSummaries?: GroupSummaryLike[],
): string {
  void stateHome;
  const tasks = listTasks();

  // totals per state
  const counts = new Map<string, number>();
  for (const t of tasks) counts.set(t.state, (counts.get(t.state) ?? 0) + 1);
  const byState =
    [...counts.entries()]
      .sort((a, b) => a[0].localeCompare(b[0]))
      .map(([s, n]) => `${s}:${n}`)
      .join(", ") || "(no tasks)";

  // active groups: via buildGroupSummaries if available, otherwise a simple
  // count of groupIds with at least one member in an active state
  let activeGroups: number;
  if (groupSummaries) {
    activeGroups = groupSummaries.filter((g) => g.pendingIds.length > 0).length;
  } else {
    activeGroups = new Set(
      tasks.filter((t) => t.groupId && ACTIVE_STATES.has(t.state)).map((t) => t.groupId),
    ).size;
  }

  // most relevant needs_input (most recent by start)
  const needsInput = tasks.filter((t) => t.state === "needs_input");
  const relevant = needsInput
    .slice()
    .sort((a, b) => (b.startedAt ?? 0) - (a.startedAt ?? 0))
    .slice(0, 5);

  const lines: string[] = [];
  lines.push(`pi-fleet fleet: ${tasks.length} tasks (${byState})`);
  lines.push(`Active groups: ${activeGroups}`);
  if (relevant.length > 0) {
    lines.push(`Needs input (${needsInput.length}):`);
    for (const t of relevant) lines.push(`- ${t.title ?? t.id} [${t.id}]`);
  } else {
    lines.push("Needs input: none");
  }
  return lines.join("\n");
}