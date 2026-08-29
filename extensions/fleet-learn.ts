/** pi-fleet · preferenze capitano e learnings persistenti (5b.5) */

import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";

// ------------------------------------------------------------------ file ---

/**
 * Layout runtime-globale in STATE_HOME (~/.pi/fleet), MAI in git:
 *  - captain.md         → preferenze locali a questa macchina (righe "chiave: valore")
 *  - captain-shared.md  → preferenze condivisibili (per il futuro secondmate)
 *  - learnings.md       → entry datate "## YYYY-MM-DD — titolo" + Fatto/Implicazione
 */

const CAPTAIN_HEADER = `# Preferenze capitano
# Preferenze locali a questa macchina (runtime-globale, mai in git).
# Formato: righe "chiave: valore", commenti #, sezioni ## libere.
<!-- memory tiers: see fleet-stow-lite (T-012) -->
`;

const CAPTAIN_SHARED_HEADER = `# Preferenze capitano (condivise)
# Preferenze condivisibili (per il futuro secondmate).
# Formato: righe "chiave: valore", commenti #, sezioni ## libere.
<!-- memory tiers: see fleet-stow-lite (T-012) -->
`;

const LEARNINGS_HEADER = `# Learnings operativi
# Fatti operativi evidence-backed accumulati dalle sessioni.
# Formato: "## YYYY-MM-DD — titolo", poi "Fatto: ..." e "Implicazione: ...".
<!-- memory tiers: see fleet-stow-lite (T-012) -->
`;

// T-012 — header-pointer per i tier di pruning (una riga, idempotente).
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

/** Scrittura atomica tmp+rename (stesso pattern di persistGroup). */
function atomicWrite(path: string, content: string): void {
  const tmp = `${path}.tmp-${process.pid}-${Date.now()}`;
  writeFileSync(tmp, content, "utf8");
  renameSync(tmp, path);
}

function readLines(path: string): string[] {
  try {
    return readFileSync(path, "utf8").split("\n");
  } catch (e) {
    throw new Error(`impossibile leggere ${path}: ${e instanceof Error ? e.message : String(e)}`);
  }
}

/** Variante best-effort: file assente → lista vuota (mai lancia). */
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
 * Header-pointer T-012: aggiunge la riga `<!-- memory tiers: ... -->` se assente,
 * subito dopo il blocco di header contiguo (commenti `#` / marker). Idempotente.
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

/** Parsa una riga "chiave: valore" (commenti/header ignorati). Ritorna null se non è una riga di pref. */
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
  /** true → file captain-shared.md; false (default) → captain.md */
  shared?: boolean;
  /** sezione "## ..." sotto cui apporre la chiave se nuova (opzionale) */
  section?: string;
}

function prefsFile(stateHome: string, opts?: PrefOpts): string {
  return opts?.shared ? captainSharedPath(stateHome) : captainPath(stateHome);
}

/**
 * Crea i tre file con header se assenti. Best-effort: non lancia mai verso l'alto.
 */
export function ensureFiles(stateHome: string): void {
  try {
    mkdirSync(stateHome, { recursive: true });
    writeIfMissing(captainPath(stateHome), CAPTAIN_HEADER);
    writeIfMissing(captainSharedPath(stateHome), CAPTAIN_SHARED_HEADER);
    writeIfMissing(learningsPath(stateHome), LEARNINGS_HEADER);
    // T-012 — header-pointer sui file esistenti (al primo pass/session_start)
    ensureTierPointer(stateHome, captainPath(stateHome));
    ensureTierPointer(stateHome, captainSharedPath(stateHome));
    ensureTierPointer(stateHome, learningsPath(stateHome));
  } catch (e) {
    console.warn(`[pi-fleet] captain prefs ensureFiles failed: ${e instanceof Error ? e.message : String(e)}`);
  }
}

/**
 * Contenuto di captain.md (per digest/bootstrap). "" se assente o illeggibile.
 */
export function readCaptain(stateHome: string): string {
  try {
    return readFileSync(captainPath(stateHome), "utf8");
  } catch {
    return "";
  }
}

/**
 * Valore della chiave in captain.md (o captain-shared.md con opts.shared).
 * Ritorna null se la chiave non esiste o il file non è leggibile.
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
 * Aggiorna o aggiunge "chiave: valore" in captain.md (o captain-shared.md).
 * - chiave esistente (case-insensitive) → sostituisce SOLO la riga, ordine e commenti intatti;
 * - chiave nuova → appende in coda (o sotto la sezione `## <opts.section>` se richiesta).
 * Scrittura atomica tmp+rename. Ritorna path e riga scritta.
 */
export function setPref(
  stateHome: string,
  key: string,
  value: string,
  opts?: PrefOpts,
): { path: string; line: string } {
  const path = prefsFile(stateHome, opts);
  const k = key.trim();
  if (!k) throw new Error("chiave vuota");
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
  // chiave nuova: appendi (sotto la sezione richiesta, se c'è)
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
 * Tier di decay per una entry (markers embedded, identici a stow):
 *  - aging      → marker `<!--a:YYYY-MM-DD-->`, stale a ≥30 giorni → refresh/archivio;
 *  - perishable → marker `<!--p:YYYY-MM-DD-->`, stale a ≥7 giorni, richiede `expiry`;
 *  - pinned     → marker `<!--pin-->` (in learnings), mai invecchia; default nei file captain.
 */
export type LearningTier = "aging" | "perishable" | "pinned";

export interface LearningOpts {
  /** tier di decay; default `aging` per learnings.md (pinned è il default dei file captain). */
  tier?: LearningTier;
  /** condizione di scadenza leggibile e verificabile per `tier: "perishable"`
   *  (es. "dopo il deploy di v0.4", "backlog #12", "attesa feedback entro 2026-09-15"). */
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
 * Appende una sezione datata a learnings.md:
 *
 *   ## YYYY-MM-DD — <title>
 *   Fatto: <fact>
 *   Implicazione: <implication>
 *   [Scadenza: <expiry>]        (solo tier perishable)
 *   <!--a:YYYY-MM-DD-->         (marker di tier, in coda all'entry; invisibile nel rendering)
 *
 * T-012: parametro opzionale `opts` per il tier (default `aging`); `perishable`
 * richiede `expiry` (condizione leggibile). Dedup per titolo (case-insensitive)
 * nelle ultime 24h: se esiste, la sezione viene sostituita in place (quindi anche
 * il marker viene rigenerato = rinforzo) invece di duplicare. Ritorna path + replaced.
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
  if (!t) throw new Error("titolo vuoto");
  const f = fact.trim();
  if (!f) throw new Error("fatto vuoto");
  const tier = opts?.tier ?? "aging";
  if (tier === "perishable" && !opts?.expiry?.trim()) {
    throw new Error("tier perishable richiede opts.expiry (condizione di scadenza leggibile)");
  }
  ensureFiles(stateHome);
  const lines = readLines(path);
  const today = new Date().toISOString().slice(0, 10);
  const headerLine = `## ${today} — ${t}`;
  const body: string[] = [`Fatto: ${f}`];
  if (implication !== undefined && implication !== null && implication.trim() !== "") {
    body.push(`Implicazione: ${implication.trim()}`);
  }
  if (tier === "perishable" && opts?.expiry) {
    // la prosa DEVE nominare la condizione di scadenza verificabile
    body.push(`Scadenza: ${opts.expiry.trim()}`);
  }
  body.push(tierMarkerLine(tier));

  // dedup 24h: stessa sezione con titolo (case-insensitive) e data < 24h → sostituisci in place
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

  // append in coda
  while (lines.length && lines[lines.length - 1].trim() === "") lines.pop();
  lines.push("", headerLine, ...body);
  writeLines(path, lines);
  return { path, replaced: false };
}

// ------------------------------------------------------------- stow (T-012) ---

/**
 * Budget di avvio (tokens stimati). Report-only + archivio dei non-pinned più
 * vecchi quando sopra soglia: zero-config, file `startup-memory-budget` opzionale.
 */
export interface StowBudget {
  limitTokens: number;
  usedTokens: number;
  overflow: boolean;
}

/** Report di un `stowPass`. */
export interface StowReport {
  dryRun: boolean;
  /** entry il cui marker datato è stato avanzato a oggi (refresh/rinforzo) */
  refreshed: number;
  /** entry uniche stale archiviate in memory-archive.md (mai delete di unici) */
  archived: number;
  /** duplicati / fatti già posseduti rimossi */
  removed: number;
  /** entry archiviate per overflow di budget (sottoinsieme di archived) */
  overflow: number;
  budget: StowBudget;
  /** conteggi pre-pass: captain.md / captain-shared.md → n. prefs, learnings.md → n. sezioni */
  fileCounts: Record<string, number>;
}

export interface StowOptions {
  /** true → solo report, zero scritture */
  dryRun?: boolean;
}

const AGING_STALE_DAYS = 30;
const PERISHABLE_STALE_DAYS = 7;
const DEFAULT_BUDGET_TOKENS = 7500;
const DAY_MS = 24 * 60 * 60 * 1000;

const ARCHIVE_HEADER = `# Archivio memorie (stow-lite)
# Sezioni datate con Provenance (stowed | legacy-unvalidated | overflow).
# Mai delete di unici: qui vivono le memorie non più attive, resta tutto recuperabile.
`;

/** Stima tokens da bytes: ceil(byte/3) come da spec. */
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

/** Cerca il marker di tier nell'ultima parte del body di una sezione. */
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

/** Porta il marker datato della sezione a oggi (refresh); migra grace → aging; appende marker se assente. */
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

/** Blocco da appendere a memory-archive.md: sezione datata + Provenance + entry originale. */
function archiveSection(today: string, s: LearningSection, sectionLines: string[], provenance: string): string {
  const first = (sectionLines[0] ?? "").trim();
  const desc = first.replace(/^##\s+/, "").trim() || s.title;
  return [`## ${today} — ${desc}`, `Provenance: ${provenance}`, ...collapseBlanks(sectionLines)].join("\n");
}

/** Rimuove doppie righe vuote consecutive e blank finali. */
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

/** Appende i blocchi archivio a memory-archive.md (header se vuoto, scrittura atomica). */
function appendArchive(stateHome: string, blocks: string[]): void {
  if (blocks.length === 0) return;
  const path = archivePath(stateHome);
  const existing = readText(path);
  const header = existing.trim() === "" ? ARCHIVE_HEADER : "";
  const sep = existing.trim() === "" ? "" : "\n\n";
  atomicWrite(path, `${header}${existing}${sep}${blocks.join("\n\n")}\n`);
}

/**
 * Pass di pruning delle memorie (T-012, lite version di stow). Mai bloccante.
 *
 * - aging con marker ≥30gg → refresh (data=oggi, lite: di default confermata);
 * - perishable con marker ≥7gg → archivio in memory-archive.md (provenance `stowed`);
 * - legacy senza marker → migrazione a marker di oggi (grace di 30gg prima del decay);
 * - entry `<!--g-->` non ri-validata → archivio con provenance `legacy-unvalidated`
 *   (la conferma avviene ri-aggiungendo la learning: dedup rigenera il marker);
 * - duplicati per titolo → rimozione (il fatto esiste già); capitans → chiavi duplicate;
 * - budget (default 7500 tok, file `startup-memory-budget`) → sopra soglia archivia i
 *   non-pinned più vecchi (mai pinned); mai delete di unici: tutto finisce nell'archivio.
 *
 * `dryRun: true` → solo report, zero scritture.
 */
export function stowPass(stateHome: string, opts?: StowOptions): StowReport {
  const dryRun = opts?.dryRun === true;
  // dryRun = zero scritture: niente ensureFiles (evita create file/header-pointer)
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
      // migrazione one-time: entry legacy assume confermata → marker di oggi
      // (così il decay scatta solo dopo 30gg, mai trattamento da "rotta")
      ops.push({ idx: i, kind: "refresh", reason: "migration" });
      refreshed++;
      continue;
    }
    if (marker.tier === "grace") {
      // non ri-validata (nessun re-add con dedup) → legacy-unvalidated
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
      // lite: di default confermata → refresh (data=oggi); mai delete di unici
      ops.push({ idx: i, kind: "refresh", reason: "stale-aging-refresh" });
      refreshed++;
      continue;
    }
    ops.push({ idx: i, kind: "keep", reason: "fresh" });
  }

  // Applica le op (dalla fine per non spostare gli indici) → learnFinal
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
    // archivia i non-pinned più vecchi (per data marker, dal più vecchio)
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
  // il conteggio `archived` include anche l'overflow
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
 * Digest compatto degli ultimi `lastN` learnings (titolo + data + primo Fatto troncato).
 * "" se non ci sono entry o il file non è leggibile.
 */
export function learningsDigest(stateHome: string, lastN = 5): string {
  try {
    const path = learningsPath(stateHome);
    if (!existsSync(path)) return "";
    const { sections } = parseLearningSections(readFileSync(path, "utf8").split("\n"));
    const recent = sections.slice(-Math.max(1, lastN));
    if (recent.length === 0) return "";
    const parts = recent.map((s) => {
      const factLine = s.body.find((b) => /^Fatto:/i.test(b.trim())) ?? "";
      const factText = factLine.trim().replace(/^Fatto:/i, "").trim();
      const trunc = factText.length > 140 ? `${factText.slice(0, 140)}…` : factText;
      return `- [${s.date}] ${s.title}${trunc ? ` — ${trunc}` : ""}`;
    });
    return `ultimi ${recent.length} learnings:\n${parts.join("\n")}`;
  } catch {
    return "";
  }
}

/**
 * Numero di prefs (righe "chiave: valore") in captain.md + captain-shared.md.
 * Usato per il conteggio nel log di avvio del capitano.
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
 * Numero di sezioni datate in learnings.md. 0 se assente/illeggibile.
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