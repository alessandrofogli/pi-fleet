/** pi-fleet · captain preferences and persistent learnings (5b.5) */

import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";

// ------------------------------------------------------------------ file ---

/**
 * Runtime-global layout in STATE_HOME (~/.pi/fleet), NEVER in git:
 *  - captain.md         → preferences local to this machine ("key: value" lines)
 *  - captain-shared.md  → shareable preferences (for the future secondmate)
 *  - learnings.md       → dated entries "## YYYY-MM-DD — title" + Fact/Implication
 */

const CAPTAIN_HEADER = `# Captain preferences
# Preferences local to this machine (runtime-global, never in git).
# Format: "key: value" lines, # comments, free ## sections.
<!-- memory tiers: see fleet-stow-lite (T-012) -->
`;

const CAPTAIN_SHARED_HEADER = `# Captain preferences (shared)
# Shareable preferences (for the future secondmate).
# Format: "key: value" lines, # comments, free ## sections.
<!-- memory tiers: see fleet-stow-lite (T-012) -->
`;

const LEARNINGS_HEADER = `# Operational learnings
# Evidence-backed operational facts accumulated from sessions.
# Format: "## YYYY-MM-DD — title", then "Fact: ..." and "Implication: ...".
<!-- memory tiers: see fleet-stow-lite (T-012) -->
`;

// T-012 — header pointer for the pruning tiers (one line, idempotent).
const TIER_POINTER = "<!-- memory tiers: see fleet-stow-lite (T-012) -->";

function archivePath(stateHome: string): string {
  return join(stateHome, "memory-archive.md");
}

function budgetPath(stateHome: string): string {
  return join(stateHome, "startup-memory-budget");
}

function captainPath(stateHome: string): string {
  return join(stateHome, "captain.md");
}

function captainSharedPath(stateHome: string): string {
  return join(stateHome, "captain-shared.md");
}

function learningsPath(stateHome: string): string {
  return join(stateHome, "learnings.md");
}

/** Atomic write tmp+rename (same pattern as persistGroup). */
function atomicWrite(path: string, content: string): void {
  const tmp = `${path}.tmp-${process.pid}-${Date.now()}`;
  writeFileSync(tmp, content, "utf8");
  renameSync(tmp, path);
}

function readLines(path: string): string[] {
  try {
    return readFileSync(path, "utf8").split("\n");
  } catch (e) {
    throw new Error(`unable to read ${path}: ${e instanceof Error ? e.message : String(e)}`);
  }
}

/** Best-effort variant: missing file → empty list (never throws). */
function readLinesSafe(path: string): string[] {
  try {
    return readLines(path);
  } catch {
    return [];
  }
}

function writeLines(path: string, lines: string[]): void {
  let content = lines.join("\n");
  if (!content.endsWith("\n")) content += "\n";
  atomicWrite(path, content);
}

function writeIfMissing(path: string, content: string): void {
  if (existsSync(path)) return;
  atomicWrite(path, content);
}

/**
 * T-012 header pointer: adds the `<!-- memory tiers: ... -->` line if absent,
 * right after the contiguous header block (# comments / markers). Idempotent.
 */
function ensureTierPointer(stateHome: string, path: string): void {
  try {
    if (!existsSync(path)) return;
    const lines = readLines(path);
    if (lines.some((l) => l.includes("fleet-stow-lite (T-012)"))) return;
    let idx = 0;
    while (
      idx < lines.length &&
      (lines[idx].trim() === "" || lines[idx].trim().startsWith("#") || lines[idx].trim().startsWith("<!--"))
    ) {
      idx++;
    }
    lines.splice(idx, 0, TIER_POINTER);
    writeLines(path, lines);
  } catch {
    /* best-effort */
  }
}

// ------------------------------------------------------------- helpers ---

/** Parses a "key: value" line (comments/header ignored). Returns null if not a pref line. */
function parsePrefLine(line: string): { key: string; value: string } | null {
  const m = /^([A-Za-z0-9_.-]+)\s*:\s*(.*)$/.exec(line.trim());
  if (!m) return null;
  return { key: m[1], value: m[2] };
}

function normalize(str: string): string {
  return str.toLowerCase().replace(/\s+/g, " ").trim();
}

function isRecent(dateStr: string, now: number): boolean {
  const d = new Date(`${dateStr}T00:00:00Z`);
  if (Number.isNaN(d.getTime())) return false;
  return now - d.getTime() < 24 * 60 * 60 * 1000;
}

// ------------------------------------------------------------- API ---

export interface PrefOpts {
  /** true → captain-shared.md file; false (default) → captain.md */
  shared?: boolean;
  /** "## ..." section under which to place a new key (optional) */
  section?: string;
}

function prefsFile(stateHome: string, opts?: PrefOpts): string {
  return opts?.shared ? captainSharedPath(stateHome) : captainPath(stateHome);
}

/**
 * Creates the three files with headers if absent. Best-effort: never throws upward.
 */
export function ensureFiles(stateHome: string): void {
  try {
    mkdirSync(stateHome, { recursive: true });
    writeIfMissing(captainPath(stateHome), CAPTAIN_HEADER);
    writeIfMissing(captainSharedPath(stateHome), CAPTAIN_SHARED_HEADER);
    writeIfMissing(learningsPath(stateHome), LEARNINGS_HEADER);
    // T-012 — header pointer on existing files (at first pass/session_start)
    ensureTierPointer(stateHome, captainPath(stateHome));
    ensureTierPointer(stateHome, captainSharedPath(stateHome));
    ensureTierPointer(stateHome, learningsPath(stateHome));
  } catch (e) {
    console.warn(`[pi-fleet] captain prefs ensureFiles failed: ${e instanceof Error ? e.message : String(e)}`);
  }
}

/**
 * Content of captain.md (for digest/bootstrap). "" if absent or unreadable.
 */
export function readCaptain(stateHome: string): string {
  try {
    return readFileSync(captainPath(stateHome), "utf8");
  } catch {
    return "";
  }
}

/**
 * Value of the key in captain.md (or captain-shared.md with opts.shared).
 * Returns null if the key does not exist or the file is not readable.
 */
export function getPref(stateHome: string, key: string, opts?: PrefOpts): string | null {
  try {
    const path = prefsFile(stateHome, opts);
    if (!existsSync(path)) return null;
    const target = normalize(key);
    for (const line of readFileSync(path, "utf8").split("\n")) {
      const hit = parsePrefLine(line);
      if (hit && normalize(hit.key) === target) return hit.value;
    }
    return null;
  } catch {
    return null;
  }
}

/**
 * Updates or adds "key: value" in captain.md (or captain-shared.md).
 * - existing key (case-insensitive) → replaces ONLY the line, order and comments intact;
 * - new key → appends at the end (or under the `## <opts.section>` section if requested).
 * Atomic tmp+rename write. Returns path and the written line.
 */
export function setPref(
  stateHome: string,
  key: string,
  value: string,
  opts?: PrefOpts,
): { path: string; line: string } {
  const path = prefsFile(stateHome, opts);
  const k = key.trim();
  if (!k) throw new Error("empty key");
  const keyLine = `${k}: ${value}`;
  ensureFiles(stateHome);
  const lines = readLines(path);
  const target = normalize(k);
  for (let i = 0; i < lines.length; i++) {
    const hit = parsePrefLine(lines[i]);
    if (hit && normalize(hit.key) === target) {
      lines[i] = keyLine;
      writeLines(path, lines);
      return { path, line: keyLine };
    }
  }
  // new key: append (under the requested section, if any)
  while (lines.length && lines[lines.length - 1].trim() === "") lines.pop();
  const section = opts?.section?.trim();
  if (!section) {
    lines.push(keyLine);
  } else {
    const want = normalize(`## ${section}`);
    let headerIdx = -1;
    let lastInside = -1;
    let inTarget = false;
    for (let i = 0; i < lines.length; i++) {
      const t = lines[i].trim();
      if (/^##\s+/i.test(t)) {
        inTarget = normalize(t) === want;
        if (inTarget && headerIdx < 0) headerIdx = i;
        continue;
      }
      if (inTarget) lastInside = i;
    }
    if (headerIdx < 0) {
      lines.push("", `## ${section}`, keyLine);
    } else if (lastInside >= 0) {
      lines.splice(lastInside + 1, 0, keyLine);
    } else {
      lines.splice(headerIdx + 1, 0, keyLine);
    }
  }
  writeLines(path, lines);
  return { path, line: keyLine };
}

/**
 * Decay tier for an entry (embedded markers, identical to stow):
 *  - aging      → marker `<!--a:YYYY-MM-DD-->`, stale at ≥30 days → refresh/archive;
 *  - perishable → marker `<!--p:YYYY-MM-DD-->`, stale at ≥7 days, requires `expiry`;
 *  - pinned     → marker `<!--pin-->` (in learnings), never ages; default in captain files.
 */
export type LearningTier = "aging" | "perishable" | "pinned";

export interface LearningOpts {
  /** decay tier; default `aging` for learnings.md (pinned is the default for captain files). */
  tier?: LearningTier;
  /** readable and verifyable expiry condition for `tier: "perishable"`
   *  (e.g. "after the v0.4 deploy", "backlog #12", "awaiting feedback by 2026-09-15"). */
  expiry?: string;
}

function tierMarkerLine(tier: LearningTier, date?: string): string {
  const d = date ?? new Date().toISOString().slice(0, 10);
  switch (tier) {
    case "perishable":
      return `<!--p:${d}-->`;
    case "pinned":
      return `<!--pin-->`;
    default:
      return `<!--a:${d}-->`;
  }
}

/**
 * Appends a dated section to learnings.md:
 *
 *   ## YYYY-MM-DD — <title>
 *   Fact: <fact>
 *   Implication: <implication>
 *   [Expiry: <expiry>]          (only for perishable tier)
 *   <!--a:YYYY-MM-DD-->         (tier marker at the end of the entry; invisible in rendering)
 *
 * T-012: optional `opts` param for the tier (default `aging`); `perishable`
 * requires `expiry` (readable condition). Dedup by title (case-insensitive)
 * within the last 24h: if it exists, the section is replaced in place (so the
 * marker is regenerated = reinforcement) instead of duplicating. Returns path + replaced.
 */
export function addLearning(
  stateHome: string,
  title: string,
  fact: string,
  implication?: string,
  opts?: LearningOpts,
): { path: string; replaced: boolean } {
  const path = learningsPath(stateHome);
  const t = title.trim();
  if (!t) throw new Error("empty title");
  const f = fact.trim();
  if (!f) throw new Error("empty fact");
  const tier = opts?.tier ?? "aging";
  if (tier === "perishable" && !opts?.expiry?.trim()) {
    throw new Error("perishable tier requires opts.expiry (readable expiry condition)");
  }
  ensureFiles(stateHome);
  const lines = readLines(path);
  const today = new Date().toISOString().slice(0, 10);
  const headerLine = `## ${today} — ${t}`;
  const body: string[] = [`Fact: ${f}`];
  if (implication !== undefined && implication !== null && implication.trim() !== "") {
    body.push(`Implication: ${implication.trim()}`);
  }
  if (tier === "perishable" && opts?.expiry) {
    // the prose MUST name the verifyable expiry condition
    body.push(`Expiry: ${opts.expiry.trim()}`);
  }
  body.push(tierMarkerLine(tier));

  // 24h dedup: same section with title (case-insensitive) and date < 24h → replace in place
  const lower = normalize(t);
  const now = Date.now();
  const parsed = parseLearningSections(lines);
  let start = -1;
  let end = -1;
  for (const s of parsed.sections) {
    if (normalize(s.title) === lower && isRecent(s.date, now)) {
      start = s.startLine;
      end = s.endLine;
      break;
    }
  }
  if (start >= 0) {
    while (end > start && lines[end - 1].trim() === "") end--;
    const replacement = [headerLine, ...body];
    lines.splice(start, end - start, ...replacement);
    writeLines(path, lines);
    return { path, replaced: true };
  }

  // append at the end
  while (lines.length && lines[lines.length - 1].trim() === "") lines.pop();
  lines.push("", headerLine, ...body);
  writeLines(path, lines);
  return { path, replaced: false };
}

// ------------------------------------------------------------- stow (T-012) ---

/**
 * Startup budget (estimated tokens). Report-only + archive of the oldest
 * non-pinned entries when over the threshold: zero-config, optional `startup-memory-budget` file.
 */
export interface StowBudget {
  limitTokens: number;
  usedTokens: number;
  overflow: boolean;
}

/** Report of a `stowPass`. */
export interface StowReport {
  dryRun: boolean;
  /** entries whose dated marker was advanced to today (refresh/reinforcement) */
  refreshed: number;
  /** unique stale entries archived in memory-archive.md (never delete uniques) */
  archived: number;
  /** duplicates / already-owned facts removed */
  removed: number;
  /** entries archived due to budget overflow (subset of archived) */
  overflow: number;
  budget: StowBudget;
  /** pre-pass counts: captain.md / captain-shared.md → n. prefs, learnings.md → n. sections */
  fileCounts: Record<string, number>;
}

export interface StowOptions {
  /** true → report only, zero writes */
  dryRun?: boolean;
}

const AGING_STALE_DAYS = 30;
const PERISHABLE_STALE_DAYS = 7;
const DEFAULT_BUDGET_TOKENS = 7500;
const DAY_MS = 24 * 60 * 60 * 1000;

const ARCHIVE_HEADER = `# Memory archive (stow-lite)
# Dated sections with Provenance (stowed | legacy-unvalidated | overflow).
# Never delete uniques: here live the no-longer-active memories, everything stays recoverable.
`;

/** Estimate tokens from bytes: ceil(byte/3) per spec. */
function estimateTokens(text: string): number {
  return Math.ceil(Buffer.byteLength(text, "utf8") / 3);
}

function daysSince(dateStr: string, today: string): number {
  const d = new Date(`${dateStr}T00:00:00Z`).getTime();
  const t = new Date(`${today}T00:00:00Z`).getTime();
  if (Number.isNaN(d) || Number.isNaN(t)) return 0;
  return Math.round((t - d) / DAY_MS);
}

interface EntryMarker {
  tier: "aging" | "perishable" | "pinned" | "grace";
  date?: string;
}

/** Looks for the tier marker in the last part of a section body. */
function parseEntryMarker(body: string[]): EntryMarker | null {
  for (let i = body.length - 1; i >= 0; i--) {
    const l = body[i];
    let m = /<!--\s*a:(\d{4}-\d{2}-\d{2})\s*-->/.exec(l);
    if (m) return { tier: "aging", date: m[1] };
    m = /<!--\s*p:(\d{4}-\d{2}-\d{2})\s*-->/.exec(l);
    if (m) return { tier: "perishable", date: m[1] };
    if (/<!--\s*g\s*-->/.test(l)) return { tier: "grace" };
    if (/<!--\s*pin\s*-->/.test(l)) return { tier: "pinned" };
  }
  return null;
}

/** Brings the section's dated marker to today (refresh); migrates grace → aging; appends marker if absent. */
function refreshSectionMarkers(lines: string[], today: string): string[] {
  const out = lines.map((l) => {
    let v = l;
    v = v.replace(/<!--\s*a:\d{4}-\d{2}-\d{2}\s*-->/, `<!--a:${today}-->`);
    v = v.replace(/<!--\s*p:\d{4}-\d{2}-\d{2}\s*-->/, `<!--p:${today}-->`);
    return v;
  });
  const graceIdx = out.findIndex((l) => /<!--\s*g\s*-->/.test(l));
  if (graceIdx >= 0) out[graceIdx] = `<!--a:${today}-->`;
  const hasDated = out.some((l) => /<!--\s*(a|p):\d{4}-\d{2}-\d{2}\s*-->/.test(l));
  if (!hasDated) {
    while (out.length && out[out.length - 1].trim() === "") out.pop();
    out.push(`<!--a:${today}-->`);
  }
  return collapseBlanks(out);
}

/** Block to append to memory-archive.md: dated section + Provenance + original entry. */
function archiveSection(today: string, s: LearningSection, sectionLines: string[], provenance: string): string {
  const first = (sectionLines[0] ?? "").trim();
  const desc = first.replace(/^##\s+/, "").trim() || s.title;
  return [`## ${today} — ${desc}`, `Provenance: ${provenance}`, ...collapseBlanks(sectionLines)].join("\n");
}

/** Removes consecutive blank lines and trailing blanks. */
function collapseBlanks(lines: string[]): string[] {
  const out: string[] = [];
  for (const l of lines) {
    if (l.trim() === "" && out.length && out[out.length - 1].trim() === "") continue;
    out.push(l);
  }
  while (out.length && out[out.length - 1].trim() === "") out.pop();
  return out;
}

function countPrefLines(path: string): number {
  try {
    if (!existsSync(path)) return 0;
    let n = 0;
    for (const line of readFileSync(path, "utf8").split("\n")) {
      const t = line.trim();
      if (!t || t.startsWith("#")) continue;
      if (parsePrefLine(t)) n++;
    }
    return n;
  } catch {
    return 0;
  }
}

function countSections(path: string): number {
  try {
    if (!existsSync(path)) return 0;
    return parseLearningSections(readFileSync(path, "utf8").split("\n")).sections.length;
  } catch {
    return 0;
  }
}

function readText(path: string): string {
  try {
    return readFileSync(path, "utf8");
  } catch {
    return "";
  }
}

/** Appends archive blocks to memory-archive.md (header if empty, atomic write). */
function appendArchive(stateHome: string, blocks: string[]): void {
  if (blocks.length === 0) return;
  const path = archivePath(stateHome);
  const existing = readText(path);
  const header = existing.trim() === "" ? ARCHIVE_HEADER : "";
  const sep = existing.trim() === "" ? "" : "\n\n";
  atomicWrite(path, `${header}${existing}${sep}${blocks.join("\n\n")}\n`);
}

/**
 * Memory pruning pass (T-012, lite version of stow). Never blocking.
 *
 * - aging with marker ≥30 days → refresh (date=today, lite: confirmed by default);
 * - perishable with marker ≥7 days → archive in memory-archive.md (provenance `stowed`);
 * - legacy without marker → migration to today's marker (grace of 30 days before decay);
 * - `<!--g-->` entry not re-validated → archive with provenance `legacy-unvalidated`
 *   (confirmation happens by re-adding the learning: dedup regenerates the marker);
 * - duplicates by title → removal (the fact already exists); captains → duplicate keys;
 * - budget (default 7500 tok, `startup-memory-budget` file) → over the threshold archive the
 *   oldest non-pinned entries (never pinned); never delete uniques: everything goes to the archive.
 *
 * `dryRun: true` → report only, zero writes.
 */
export function stowPass(stateHome: string, opts?: StowOptions): StowReport {
  const dryRun = opts?.dryRun === true;
  // dryRun = zero writes: no ensureFiles (avoids file/header-pointer creation)
  if (!dryRun) ensureFiles(stateHome);
  const today = new Date().toISOString().slice(0, 10);

  const fileCounts: Record<string, number> = {
    "captain.md": countPrefLines(captainPath(stateHome)),
    "captain-shared.md": countPrefLines(captainSharedPath(stateHome)),
    "learnings.md": countSections(learningsPath(stateHome)),
  };

  let refreshed = 0;
  let archived = 0;
  let removed = 0;
  let overflowN = 0;

  // ---------------------------------------------------------- learnings ---
  const learnPath = learningsPath(stateHome);
  const learnLines = readLinesSafe(learnPath);
  const secs = parseLearningSections(learnLines).sections;
  const archiveBlocks: string[] = [];

  type Op =
    | { idx: number; kind: "keep"; reason: string }
    | { idx: number; kind: "refresh"; reason: string }
    | { idx: number; kind: "archive"; reason: string; provenance: string }
    | { idx: number; kind: "remove"; reason: string };
  const ops: Op[] = [];
  const seenTitles = new Map<string, number>(); // normalize(title) → idx

  for (let i = 0; i < secs.length; i++) {
    const s = secs[i];
    const norm = normalize(s.title);
    if (seenTitles.has(norm)) {
      ops.push({ idx: i, kind: "remove", reason: "duplicate-title" });
      removed++;
      continue;
    }
    seenTitles.set(norm, i);
    const marker = parseEntryMarker(s.body);
    if (marker?.tier === "pinned") {
      ops.push({ idx: i, kind: "keep", reason: "pinned" });
      continue;
    }
    if (!marker) {
      // one-time migration: legacy entry assumed confirmed → today's marker
      // (so decay only kicks in after 30 days, never treated as "broken")
      ops.push({ idx: i, kind: "refresh", reason: "migration" });
      refreshed++;
      continue;
    }
    if (marker.tier === "grace") {
      // not re-validated (no re-add with dedup) → legacy-unvalidated
      ops.push({ idx: i, kind: "archive", reason: "grace-unvalidated", provenance: "legacy-unvalidated" });
      archived++;
      continue;
    }
    const days = daysSince(marker.date ?? today, today);
    if (marker.tier === "perishable" && days >= PERISHABLE_STALE_DAYS) {
      ops.push({ idx: i, kind: "archive", reason: "stale-perishable", provenance: "stowed" });
      archived++;
      continue;
    }
    if (marker.tier === "aging" && days >= AGING_STALE_DAYS) {
      // lite: confirmed by default → refresh (date=today); never delete uniques
      ops.push({ idx: i, kind: "refresh", reason: "stale-aging-refresh" });
      refreshed++;
      continue;
    }
    ops.push({ idx: i, kind: "keep", reason: "fresh" });
  }

  // Apply the ops (from the end so indexes don't shift) → learnFinal
  let learnFinal = [...learnLines];
  for (let i = secs.length - 1; i >= 0; i--) {
    const op = ops.find((o) => o.idx === i);
    if (!op || op.kind === "keep") continue;
    const s = secs[i];
    const sectionLines = learnLines.slice(s.startLine, s.endLine);
    const len = s.endLine - s.startLine;
    if (op.kind === "archive") {
      archiveBlocks.push(archiveSection(today, s, sectionLines, op.provenance));
      learnFinal.splice(s.startLine, len);
    } else if (op.kind === "remove") {
      learnFinal.splice(s.startLine, len);
    } else if (op.kind === "refresh") {
      learnFinal.splice(s.startLine, len, ...refreshSectionMarkers(sectionLines, today));
    }
  }
  if (ops.some((o) => o.kind !== "keep")) learnFinal = collapseBlanks(learnFinal);

  // ------------------------------------------------------- captains (dedup) ---
  const capFiles: Array<{ path: string; lines: string[] }> = [];
  for (const p of [captainPath(stateHome), captainSharedPath(stateHome)]) {
    if (!existsSync(p)) continue;
    const lines = readLinesSafe(p);
    const seenKeys = new Set<string>();
    const drop = new Set<number>();
    for (let i = lines.length - 1; i >= 0; i--) {
      const hit = parsePrefLine(lines[i]);
      if (hit) {
        const k = normalize(hit.key);
        if (seenKeys.has(k)) drop.add(i);
        else seenKeys.add(k);
      }
    }
    if (drop.size) {
      removed += drop.size;
      capFiles.push({ path: p, lines: lines.filter((_, i) => !drop.has(i)) });
    } else {
      capFiles.push({ path: p, lines });
    }
  }

  // ------------------------------------------------------------- budget ---
  let limitTokens = DEFAULT_BUDGET_TOKENS;
  try {
    const bp = budgetPath(stateHome);
    if (existsSync(bp)) {
      const v = parseInt(readText(bp).trim(), 10);
      if (Number.isFinite(v) && v > 0) limitTokens = v;
    }
  } catch {
    /* default */
  }

  const capContent = (capFiles.find((f) => f.path === captainPath(stateHome))?.lines ?? []).join("\n");
  const capSharedContent = (capFiles.find((f) => f.path === captainSharedPath(stateHome))?.lines ?? []).join("\n");
  const tokenSum = () => estimateTokens(capContent) + estimateTokens(capSharedContent) + estimateTokens(learnFinal.join("\n"));
  let usedTokens = tokenSum();

  if (usedTokens > limitTokens) {
    // archive the oldest non-pinned entries (by marker date, oldest first)
    const s2 = parseLearningSections(learnFinal).sections;
    const candidates = s2
      .map((s, idx) => ({ s, idx }))
      .filter(({ s }) => {
        const m = parseEntryMarker(s.body);
        return m && (m.tier === "aging" || m.tier === "perishable") && m.date;
      })
      .sort((a, b) => {
        const da = parseEntryMarker(a.s.body)!.date!;
        const db = parseEntryMarker(b.s.body)!.date!;
        return da.localeCompare(db);
      });
    for (const { s, idx } of candidates) {
      if (usedTokens <= limitTokens) break;
      const sectionLines = learnFinal.slice(s.startLine, s.endLine);
      archiveBlocks.push(archiveSection(today, s, sectionLines, "overflow"));
      learnFinal.splice(s.startLine, s.endLine - s.startLine);
      learnFinal = collapseBlanks(learnFinal);
      overflowN++;
      usedTokens = tokenSum();
    }
  }
  // the `archived` count includes the overflow too
  archived += overflowN;

  // ------------------------------------------------------------- write ---
  if (!dryRun) {
    if (archiveBlocks.length) appendArchive(stateHome, archiveBlocks);
    writeLines(learnPath, learnFinal);
    for (const { path, lines } of capFiles) writeLines(path, lines);
  }

  return {
    dryRun,
    refreshed,
    archived,
    removed,
    overflow: overflowN,
    budget: { limitTokens, usedTokens, overflow: usedTokens > limitTokens },
    fileCounts,
  };
}

interface LearningSection {
  date: string;
  title: string;
  startLine: number;
  endLine: number;
  body: string[];
}

function parseLearningSections(lines: string[]): { sections: LearningSection[] } {
  const sections: LearningSection[] = [];
  let cur: LearningSection | null = null;
  for (let i = 0; i < lines.length; i++) {
    const m = /^##\s+(\d{4}-\d{2}-\d{2})\s*[—-]\s*(.+)$/.exec(lines[i]);
    if (m) {
      if (cur) {
        cur.endLine = i;
        sections.push(cur);
      }
      cur = { date: m[1], title: m[2].trim(), startLine: i, endLine: lines.length, body: [] };
    } else if (cur) {
      cur.body.push(lines[i]);
    }
  }
  if (cur) {
    cur.endLine = lines.length;
    sections.push(cur);
  }
  return { sections };
}

/**
 * Compact digest of the last `lastN` learnings (title + date + first truncated Fact).
 * "" if there are no entries or the file is not readable.
 */
export function learningsDigest(stateHome: string, lastN = 5): string {
  try {
    const path = learningsPath(stateHome);
    if (!existsSync(path)) return "";
    const { sections } = parseLearningSections(readFileSync(path, "utf8").split("\n"));
    const recent = sections.slice(-Math.max(1, lastN));
    if (recent.length === 0) return "";
    const parts = recent.map((s) => {
      const factLine = s.body.find((b) => /^Fact:/i.test(b.trim())) ?? "";
      const factText = factLine.trim().replace(/^Fact:/i, "").trim();
      const trunc = factText.length > 140 ? `${factText.slice(0, 140)}…` : factText;
      return `- [${s.date}] ${s.title}${trunc ? ` — ${trunc}` : ""}`;
    });
    return `last ${recent.length} learnings:\n${parts.join("\n")}`;
  } catch {
    return "";
  }
}

/**
 * Number of prefs ("key: value" lines) in captain.md + captain-shared.md.
 * Used for the count in the captain's startup log.
 */
export function countPrefs(stateHome: string): number {
  let n = 0;
  for (const p of [captainPath(stateHome), captainSharedPath(stateHome)]) {
    try {
      if (!existsSync(p)) continue;
      for (const line of readFileSync(p, "utf8").split("\n")) {
        const t = line.trim();
        if (!t || t.startsWith("#")) continue;
        if (parsePrefLine(t)) n++;
      }
    } catch { /* best-effort */ }
  }
  return n;
}

/**
 * Number of dated sections in learnings.md. 0 if absent/unreadable.
 */
export function countLearnings(stateHome: string): number {
  try {
    const path = learningsPath(stateHome);
    if (!existsSync(path)) return 0;
    return parseLearningSections(readFileSync(path, "utf8").split("\n")).sections.length;
  } catch {
    return 0;
  }
}