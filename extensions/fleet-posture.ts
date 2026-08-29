/** pi-fleet · delivery posture per progetto — T-003 */

import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

// Stessa espressione di extensions/index.ts (coerente con FLEET_STATE_HOME).
const STATE_HOME = process.env.FLEET_STATE_HOME ?? join(homedir(), ".pi", "fleet");
export const POSTURES_FILE = join(STATE_HOME, "postures.json");

// ------------------------------------------------------------------ tipi ---

/** Delivery posture dichiarabili per progetto (semantica in README.md). */
export const POSTURES = ["no-mistakes", "direct-PR", "local-only", "yolo"] as const;
export type DeliveryPosture = (typeof POSTURES)[number];
export const DEFAULT_POSTURE: DeliveryPosture = "no-mistakes";

/** Mappa persistita: { "<projectPath>": posture }. */
export interface PosturesMap {
  [projectPath: string]: string;
}

// ------------------------------------------------------------ helpers ------

export function isValidPosture(s: unknown): s is DeliveryPosture {
  return typeof s === "string" && (POSTURES as readonly string[]).includes(s);
}

function readPostures(): PosturesMap {
  try {
    if (!existsSync(POSTURES_FILE)) return {};
    const raw = readFileSync(POSTURES_FILE, "utf8");
    const data: unknown = JSON.parse(raw);
    if (typeof data !== "object" || data === null || Array.isArray(data)) return {};
    return data as PosturesMap;
  } catch {
    // File corrotto/assente → mappa vuota; setPosture ricrea da zero.
    return {};
  }
}

/** Posture corrente del progetto; default "no-mistakes" se assente/non valida. */
export function getPosture(projectPath: string): string {
  const value = readPostures()[projectPath];
  return isValidPosture(value) ? value : DEFAULT_POSTURE;
}

/** Imposta la posture del progetto. Scrittura atomica (tmp+rename), ricrea il file se assente. */
export function setPosture(projectPath: string, posture: string): void {
  if (!isValidPosture(posture)) {
    throw new Error(`Invalid posture '${posture}'. Allowed: ${POSTURES.join(", ")}`);
  }
  mkdirSync(STATE_HOME, { recursive: true });
  const map = readPostures();
  map[projectPath] = posture;
  const tmp = `${POSTURES_FILE}.tmp`;
  writeFileSync(tmp, JSON.stringify(map, null, 2) + "\n");
  renameSync(tmp, POSTURES_FILE);
}