/** pi-fleet · per-project delivery posture — T-003 */

import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

// Same expression as extensions/index.ts (consistent with FLEET_STATE_HOME).
const STATE_HOME = process.env.FLEET_STATE_HOME ?? join(homedir(), ".pi", "fleet");
export const POSTURES_FILE = join(STATE_HOME, "postures.json");

// ------------------------------------------------------------------ types ---

/** Declarable delivery postures per project (semantics in README.md). */
export const POSTURES = ["no-mistakes", "direct-PR", "local-only", "yolo"] as const;
export type DeliveryPosture = (typeof POSTURES)[number];
export const DEFAULT_POSTURE: DeliveryPosture = "no-mistakes";

/** Persisted map: { "<projectPath>": posture }. */
export interface PosturesMap {
  [projectPath: string]: string;
}

/**
 * Reserved top-level key of postures.json holding fleet-wide settings.
 * Project paths never collide (they are absolute or ~-paths).
 */
export const CONFIG_KEY = "$config";

/**
 * T-013: max depth a nested task may have (captain = depth 0, its children = 1, ...).
 * A task at depth N can launch children only when N < nestedMaxDepth. Default 2 =
 * captain → nested child (1) → leaf grandchildren (2), i.e. one orchestration level.
 */
export const DEFAULT_NESTED_MAX_DEPTH = 2;

export interface PosturesConfig {
  nestedMaxDepth?: number;
}

// ------------------------------------------------------------ helpers ------

export function isValidPosture(s: unknown): s is DeliveryPosture {
  return typeof s === "string" && (POSTURES as readonly string[]).includes(s);
}

/** Parses the raw file; null on missing/corrupt. */
function readRaw(): unknown {
  try {
    if (!existsSync(POSTURES_FILE)) return null;
    return JSON.parse(readFileSync(POSTURES_FILE, "utf8"));
  } catch {
    return null;
  }
}

/** The flat posture map, with the reserved $config key stripped out. */
function readPostures(): PosturesMap {
  const data = readRaw();
  if (typeof data !== "object" || data === null || Array.isArray(data)) return {};
  const { [CONFIG_KEY]: _config, ...map } = data as Record<string, unknown>;
  return map as PosturesMap;
}

/**
 * T-013: nested launch depth cap from postures.json `$config.nestedMaxDepth`.
 * Positive integer >= 1; anything else falls back to the default (2).
 */
export function getNestedMaxDepth(): number {
  const data = readRaw();
  if (typeof data !== "object" || data === null || Array.isArray(data)) return DEFAULT_NESTED_MAX_DEPTH;
  const cfg = (data as Record<string, unknown>)[CONFIG_KEY];
  if (typeof cfg !== "object" || cfg === null || Array.isArray(cfg)) return DEFAULT_NESTED_MAX_DEPTH;
  const v = (cfg as Record<string, unknown>).nestedMaxDepth;
  if (typeof v !== "number" || !Number.isInteger(v) || v < 1) return DEFAULT_NESTED_MAX_DEPTH;
  return v;
}

/** Current posture of the project; default "no-mistakes" if absent/invalid. */
export function getPosture(projectPath: string): string {
  const value = readPostures()[projectPath];
  return isValidPosture(value) ? value : DEFAULT_POSTURE;
}

/** Sets the project posture. Atomic write (tmp+rename), recreates the file if missing. */
export function setPosture(projectPath: string, posture: string): void {
  if (!isValidPosture(posture)) {
    throw new Error(`Invalid posture '${posture}'. Allowed: ${POSTURES.join(", ")}`);
  }
  mkdirSync(STATE_HOME, { recursive: true });
  const map = readPostures();
  map[projectPath] = posture;
  // T-013: preserve the reserved $config key across posture writes
  const raw = readRaw();
  const config =
    typeof raw === "object" && raw !== null && !Array.isArray(raw)
      ? (raw as Record<string, unknown>)[CONFIG_KEY]
      : undefined;
  const out: Record<string, unknown> =
    config !== undefined ? { [CONFIG_KEY]: config, ...map } : { ...map };
  const tmp = `${POSTURES_FILE}.tmp`;
  writeFileSync(tmp, JSON.stringify(out, null, 2) + "\n");
  renameSync(tmp, POSTURES_FILE);
}