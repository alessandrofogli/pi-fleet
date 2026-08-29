/** pi-fleet · bootstrap alla session_start (T-006) */

import { spawnSync } from "node:child_process";
import { existsSync, readdirSync, renameSync, rmSync, statSync } from "node:fs";
import { join } from "node:path";

// ------------------------------------------------------------------ tipi ---

/** Esito del check di un tool binario. `auth` è presente solo per `gh`. */
export interface CheckedTool {
  tool: string;
  ok: boolean;
  path?: string;
  auth?: boolean;
}

/**
 * Vista minima di un task necessaria a digest/pulizia.
 * Strutturale con TaskStateFile (index.ts): nessun import runtime.
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

/** Sintesi gruppo come prodotta da buildGroupSummaries (fleet-group.ts). */
export interface GroupSummaryLike {
  groupId: string;
  label?: string;
  expected: number;
  done: number;
  pendingIds: string[];
}

// ------------------------------------------------------------- checkTools ---

/** Tool binari da verificare alla session_start (zero-config, solo report). */
const BIN_TOOLS = ["jq", "herdr", "treehouse", "git", "gh"] as const;

/**
 * Verifica la presenza dei tool binari via `which` (spawnSync).
 * Per `gh` aggiunge `auth` = esito di `gh auth status` (informativo).
 * Non installa nulla: segnala soltanto.
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
const STALE_BAD_MS = 7 * 24 * 60 * 60 * 1000; // 7 giorni

/**
 * Pulizia SICURA dello stato su disco (mai distruttiva sui task attivi):
 *  - marker `<id>.done.json` orfani (nessun `<id>.json` corrispondente)
 *    → spostati in `<id>.done.json.orphan`;
 *  - file `<id>.json.bad` più vecchi di 7 giorni → eliminati;
 *  - task attivi il cui pane herdr non esiste più e senza done-marker:
 *    NON toccati qui (lo fa `reconcileStaleTasks` in index.ts) — solo segnalati.
 *
 * Ritorna la lista delle azioni eseguite/segnalate (descrizioni testuali).
 */
export function cleanupStale(stateHome: string, listTasks: () => FleetTaskLike[]): string[] {
  const actions: string[] = [];
  let names: string[] = [];
  try {
    names = readdirSync(stateHome);
  } catch {
    return actions;
  }

  // 1) done-marker orfani → <id>.done.json.orphan
  for (const name of names) {
    if (!name.endsWith(".done.json")) continue;
    const id = name.slice(0, -".done.json".length);
    try {
      if (!existsSync(join(stateHome, `${id}.json`))) {
        renameSync(join(stateHome, name), join(stateHome, `${name}.orphan`));
        actions.push(`spostato marker orfano ${name} → ${name}.orphan`);
      }
    } catch {
      /* best-effort */
    }
  }

  // 2) file .json.bad anziani (>7gg) → elimina
  const now = Date.now();
  for (const name of names) {
    if (!name.endsWith(".json.bad")) continue;
    try {
      const st = statSync(join(stateHome, name));
      if (now - st.mtimeMs > STALE_BAD_MS) {
        rmSync(join(stateHome, name));
        actions.push(`rimosso ${name} (anziano >7gg)`);
      }
    } catch {
      /* best-effort */
    }
  }

  // 3) segnalazione task attivi senza pane herdr (NON toccare: reconcileStaleTasks)
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
        /* parse fallito: niente segnalazione */
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
          actions.push(`trovati ${zombies.length} task attivi senza pane herdr (li gestisce reconcileStaleTasks)`);
        }
      }
    }
  } catch {
    /* herdr assente o errore → fail soft, nessuna segnalazione */
  }

  return actions;
}

// ------------------------------------------------------------- fleetDigest ---

/**
 * Digest breve della flotta: totali per stato, gruppi attivi (riusa la logica
 * gruppi se disponibile via `groupSummaries`, altrimenti conteggio semplice),
 * task needs_input più rilevanti.
 */
export function fleetDigest(
  stateHome: string,
  listTasks: () => FleetTaskLike[],
  groupSummaries?: GroupSummaryLike[],
): string {
  void stateHome;
  const tasks = listTasks();

  // totali per stato
  const counts = new Map<string, number>();
  for (const t of tasks) counts.set(t.state, (counts.get(t.state) ?? 0) + 1);
  const byState =
    [...counts.entries()]
      .sort((a, b) => a[0].localeCompare(b[0]))
      .map(([s, n]) => `${s}:${n}`)
      .join(", ") || "(nessun task)";

  // gruppi attivi: via buildGroupSummaries se disponibile, altrimenti conteggio
  // semplice dei groupId con almeno un membro in stato attivo
  let activeGroups: number;
  if (groupSummaries) {
    activeGroups = groupSummaries.filter((g) => g.pendingIds.length > 0).length;
  } else {
    activeGroups = new Set(
      tasks.filter((t) => t.groupId && ACTIVE_STATES.has(t.state)).map((t) => t.groupId),
    ).size;
  }

  // needs_input più rilevanti (più recenti per start)
  const needsInput = tasks.filter((t) => t.state === "needs_input");
  const relevant = needsInput
    .slice()
    .sort((a, b) => (b.startedAt ?? 0) - (a.startedAt ?? 0))
    .slice(0, 5);

  const lines: string[] = [];
  lines.push(`Flotta pi-fleet: ${tasks.length} task (${byState})`);
  lines.push(`Gruppi attivi: ${activeGroups}`);
  if (relevant.length > 0) {
    lines.push(`Needs input (${needsInput.length}):`);
    for (const t of relevant) lines.push(`- ${t.title ?? t.id} [${t.id}]`);
  } else {
    lines.push("Needs input: nessuno");
  }
  return lines.join("\n");
}