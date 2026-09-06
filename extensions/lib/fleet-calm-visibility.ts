/**
 * pi-fleet · Fleet Calm — central transcript visibility policy (gh-9)
 *
 * Ported from Firstmate's `.pi/extensions/lib/fm-calm-visibility.ts` (MIT,
 * Kun Chen — see the NOTICE in extensions/lib/fleet-calm.ts). This module owns
 * ONLY the allowlist-style presentation policy: which transcript classes are
 * visible while Calm is on, the on/off preference state, and the pi-fleet
 * operational-user-row classifier (the wake/steer envelopes pi-fleet itself
 * injects — NOT firstmate's synthetic-kind taxonomy, see below).
 *
 * Visible classes (identical to Firstmate's proven policy):
 *   genuine-user-prompt, genuine-agent-response, working-status.
 * Every other audited class is policy-hidden when pi exposes a supported
 * presentation boundary. Which classes a given adapter ACTUALLY hides is the
 * adapter's decision; this module is the single source of truth for the policy.
 *
 * pi-fleet's own operational user rows (no U+2063 envelopes, plain text):
 *   - "FLEET WATCHER WAKE: ..." — external watcher wakes (fleet-watch-arm.ts
 *     sendWake / bin/fleet-watch.sh startup drain), delivered user-role into
 *     the captain's session or as display:true fleet_notice custom messages.
 *   - "T-019 health watchdog (...): ..." — pane-health steers (bin/fleet-watch.sh),
 *     also delivered user-role via `herdr agent prompt`.
 * The classifier is intentionally prefix-exact so a genuine user prompt is
 * never misclassified; hiding is presentation-only (the message stays in
 * context/session/export).
 */

import { homedir } from "node:os";
import { join } from "node:path";
import { getPref, setPref } from "../fleet-learn.js";

// ------------------------------------------------------------------ policy --

export const FLEET_CALM_PREFERENCE_KEY = "calm";

export const CALM_TRANSCRIPT_CLASSES = [
  "genuine-user-prompt",
  "genuine-agent-response",
  "assistant-working-note",
  "assistant-thinking",
  "assistant-tool-call",
  "tool-result",
  "tool-image",
  "user-bash",
  "skill-invocation",
  "custom-message",
  "custom-entry",
  "compaction-summary",
  "branch-summary",
  "working-status",
  "command-status",
  "system-notice",
  "cache-notice",
  "project-trust-warning",
  "synthetic-user",
  "synthetic-assistant",
  "unknown",
] as const;

export type CalmTranscriptClass = (typeof CALM_TRANSCRIPT_CLASSES)[number];

// "assistant-working-note" is deliberately absent: Calm hides mid-turn
// assistant working notes, keeping the genuine final reply.
const CALM_VISIBLE_CLASSES = new Set<CalmTranscriptClass>([
  "genuine-user-prompt",
  "genuine-agent-response",
  "working-status",
]);

// ------------------------------------------------------------ runtime state --

export const FLEET_CALM_PRESENTATION_EVENT = "pi-fleet:calm-presentation";

export type CalmPresentationState = {
  active: boolean;
  stockExportRendering: boolean;
};

let calm = false;
let stockExportRendering = false;

export function calmTranscriptClassIsVisible(itemClass: CalmTranscriptClass): boolean {
  return CALM_VISIBLE_CLASSES.has(itemClass);
}

export function setCalmPresentation(active: boolean): void {
  calm = active;
}

export function setCalmStockExportRendering(active: boolean): void {
  stockExportRendering = active;
}

/** True while a stock /export (or /share) rendering pass is in progress. */
export function calmStockExportRendering(): boolean {
  return stockExportRendering;
}

export function calmPresentationIsActive(): boolean {
  return calm;
}

/** True when Calm hides the given transcript class in live rendering. */
export function calmPresentationHides(itemClass: CalmTranscriptClass): boolean {
  return calm && !stockExportRendering && !calmTranscriptClassIsVisible(itemClass);
}

// ------------------------------------------------------------- persistence --

/** Same resolution as extensions/index.ts (isolated under FLEET_STATE_HOME). */
export function fleetStateHome(): string {
  return process.env.FLEET_STATE_HOME ?? join(homedir(), ".pi", "fleet");
}

export function calmPreferencePath(): string {
  return join(fleetStateHome(), "captain.md");
}

/**
 * Read the persisted Calm choice. Absent/unreadable captain.md → off.
 * Only the exact value "on" enables Calm (no legacy "max" value exists in
 * pi-fleet, unlike Firstmate's history).
 */
export function loadCalmPreference(stateHome = fleetStateHome()): boolean {
  return getPref(stateHome, FLEET_CALM_PREFERENCE_KEY) === "on";
}

/**
 * Persist the Calm choice through pi-fleet's canonical preference mechanism
 * (captain.md "key: value" line via fleet-learn.setPref — atomic tmp+rename,
 * the same store the fleet_captain_pref tool and notify.sound use). Survives
 * session restarts; the value round-trips through loadCalmPreference.
 */
export function persistCalmPreference(
  active: boolean,
  stateHome = fleetStateHome(),
): { path: string; line: string } {
  return setPref(stateHome, FLEET_CALM_PREFERENCE_KEY, active ? "on" : "off");
}

// --------------------------------------- pi-fleet operational user classifier --
// pi-fleet's OWN user-role operational envelopes. Prefix-exact, so genuine user
// prompts are never classified. Presentation-only: never rewrites the message.

const FLEET_OPERATIONAL_PREFIXES = ["FLEET WATCHER WAKE:", "T-019 health watchdog ("] as const;

/** True when `text` is one of pi-fleet's own user-role operational envelopes. */
export function isFleetOperationalUserText(text: string): boolean {
  if (typeof text !== "string" || text.length === 0) return false;
  return FLEET_OPERATIONAL_PREFIXES.some((prefix) => text.startsWith(prefix));
}

/** True when `customType` is one of pi-fleet's own operational custom messages. */
export function isFleetOperationalCustomType(customType: string | undefined): boolean {
  return customType === "fleet_notice";
}