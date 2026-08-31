/**
 * pi-fleet · captain audible reply (completion notification) — T-028
 *
 * The bell fires ONLY when the CAPTAIN emits a user-visible reply: both when it
 * answers the user directly and when, after a watcher wake, it reports the
 * children's work (the hook lives in index.ts: agent_settled + a run that
 * produced a DISPLAYED assistant message).
 *
 * NEVER from children (separate processes — the IS_CAPTAIN gate in index.ts
 * keeps them silent) and NEVER from the internal silent wakes themselves: those
 * are role "custom" messages with display:false, which never count as assistant
 * output (see isDisplayedAssistantMessage).
 *
 * Config: captain preference `notify.sound: on|off` in captain.md (written with
 * `fleet_captain_pref`), DEFAULT ON. Missing or invalid values → ON (sound).
 *
 * This module is deliberately dependency-free (mirrors the fleet-posture.ts
 * config-read pattern): the preference is read from the SAME captain.md that
 * `fleet_captain_pref` writes, using the SAME "key: value" line format of
 * fleet-learn.ts parsePrefLine — kept in sync there (case-insensitive key,
 * `^([A-Za-z0-9_.-]+)\s*:\s*(.*)$`).
 *
 * All decision logic is pure/pluggable so the headless smoke
 * (tests/smoke-sound.sh) can drive it without a real pi session.
 */

import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

// Same expression as extensions/index.ts (consistent with FLEET_STATE_HOME).
const STATE_HOME = process.env.FLEET_STATE_HOME ?? join(homedir(), ".pi", "fleet");

/** Captain preference key controlling the audible reply (captain.md "key: value" line). */
export const NOTIFY_SOUND_KEY = "notify.sound";

/** Bell payload: a single BEL control char — non-intrusive, zero text payload. */
export const BELL = "\x07";

// ------------------------------------------------------------ bell sink ----

/** Where the bell goes (default: BEL to the captain's terminal, TTY only). */
export type SoundSink = (payload: string) => void;

const defaultSink: SoundSink = (payload) => {
  try {
    if (process.stdout.isTTY) process.stdout.write(payload);
  } catch {
    /* the bell must never break the captain turn */
  }
};

let sink: SoundSink = defaultSink;

/** Test hook: replace the bell sink (headless smokes capture the payload). */
export function setSoundSink(next: SoundSink): void {
  sink = next;
}

/** Restore the default terminal-BEL sink. */
export function resetSoundSink(): void {
  sink = defaultSink;
}

/** Emit the bell through the current sink (fail-soft, never throws). */
export function ringBell(): void {
  try {
    sink(BELL);
  } catch {
    /* fail soft */
  }
}

// -------------------------------------------------------- config parse ----

/**
 * Parse the `notify.sound` preference value:
 *   - "off" (case-insensitive) → sound disabled (false)
 *   - "on" / missing (null/undefined) / any other invalid value → enabled (true)
 */
export function parseSoundConfig(raw: string | null | undefined): boolean {
  return raw?.trim().toLowerCase() !== "off";
}

/**
 * Read the `notify.sound` line from the captain preference file (captain.md).
 * Mirrors fleet-learn.ts getPref/parsePrefLine so `fleet_captain_pref` (the
 * writer) and this reader stay aligned. Missing/unreadable file → null, which
 * parseSoundConfig resolves to the default (ON).
 */
export function readSoundPref(stateHome: string = STATE_HOME): string | null {
  try {
    const path = join(stateHome, "captain.md");
    if (!existsSync(path)) return null;
    for (const line of readFileSync(path, "utf8").split("\n")) {
      const hit = /^([A-Za-z0-9_.-]+)\s*:\s*(.*)$/.exec(line.trim());
      if (hit && hit[1].trim().toLowerCase() === NOTIFY_SOUND_KEY) return hit[2];
    }
    return null;
  } catch {
    return null;
  }
}

/** Is the audible reply enabled for this state home? Default ON unless `off`. */
export function isSoundEnabled(stateHome: string = STATE_HOME): boolean {
  return parseSoundConfig(readSoundPref(stateHome));
}

// ------------------------------------------------------- turn tracking ----

/**
 * Length of the VISIBLE text of an agent message content (string or content
 * parts). Only `type: "text"` parts count: tool calls (`toolCall`) and hidden
 * thinking (`thinking`) are not displayed to the user.
 */
export function messageVisibleTextLength(content: unknown): number {
  if (typeof content === "string") return content.trim().length;
  if (Array.isArray(content)) {
    let n = 0;
    for (const part of content) {
      if (
        part &&
        typeof part === "object" &&
        (part as { type?: string }).type === "text" &&
        typeof (part as { text?: string }).text === "string"
      ) {
        n += (part as { text: string }).text.trim().length;
      }
    }
    return n;
  }
  return 0;
}

/**
 * A message counts as a DISPLAYED captain reply iff it is an assistant message
 * whose content contains visible text. The silent fleet wakes (display:false)
 * are role "custom" — never assistant — so they are never counted here.
 */
export function isDisplayedAssistantMessage(role: string | undefined, content: unknown): boolean {
  return role === "assistant" && messageVisibleTextLength(content) > 0;
}

/** Per-agent-run tracker fed by agent_start / message_end in index.ts. */
export interface SoundTracker {
  /** Reset the per-run flag (register on agent_start). */
  onAgentStart(): void;
  /** Record a message end (register on message_end). */
  onMessageEnd(role: string | undefined, content: unknown): void;
  /** True when the current run produced a displayed assistant message. */
  shouldRing(): boolean;
}

/** Per-agent-run counter of displayed assistant messages (agent_start resets). */
export function createSoundTracker(): SoundTracker {
  let displayedMessageSeen = false;
  return {
    onAgentStart() {
      displayedMessageSeen = false;
    },
    onMessageEnd(role: string | undefined, content: unknown) {
      if (isDisplayedAssistantMessage(role, content)) displayedMessageSeen = true;
    },
    shouldRing() {
      return displayedMessageSeen;
    },
  };
}

// ------------------------------------------------------ full decision -----

/**
 * Complete decision + emission for a settled captain turn (agent_settled):
 * ring iff the run produced a displayed assistant message AND the config is
 * enabled. Returns true when the bell rang (used by the smoke).
 */
export function ringForSettledTurn(stateHome: string = STATE_HOME, tracker: SoundTracker): boolean {
  if (!tracker.shouldRing()) return false;
  if (!isSoundEnabled(stateHome)) return false;
  ringBell();
  return true;
}