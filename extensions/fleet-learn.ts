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
`;

const CAPTAIN_SHARED_HEADER = `# Preferenze capitano (condivise)
# Preferenze condivisibili (per il futuro secondmate).
# Formato: righe "chiave: valore", commenti #, sezioni ## libere.
`;

const LEARNINGS_HEADER = `# Learnings operativi
# Fatti operativi evidence-backed accumulati dalle sessioni.
# Formato: "## YYYY-MM-DD — titolo", poi "Fatto: ..." e "Implicazione: ...".
`;

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

function writeLines(path: string, lines: string[]): void {
  let content = lines.join("\n");
  if (!content.endsWith("\n")) content += "\n";
  atomicWrite(path, content);
}

function writeIfMissing(path: string, content: string): void {
  if (existsSync(path)) return;
  atomicWrite(path, content);
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
 * Appende una sezione datata a learnings.md:
 *
 *   ## YYYY-MM-DD — <title>
 *   Fatto: <fact>
 *   Implicazione: <implication>
 *
 * Dedup per titolo (case-insensitive) nelle ultime 24h: se esiste, la sezione
 * viene sostituita in place invece di duplicare. Ritorna path + replaced.
 */
export function addLearning(
  stateHome: string,
  title: string,
  fact: string,
  implication?: string,
): { path: string; replaced: boolean } {
  const path = learningsPath(stateHome);
  const t = title.trim();
  if (!t) throw new Error("titolo vuoto");
  const f = fact.trim();
  if (!f) throw new Error("fatto vuoto");
  ensureFiles(stateHome);
  const lines = readLines(path);
  const today = new Date().toISOString().slice(0, 10);
  const headerLine = `## ${today} — ${t}`;
  const body: string[] = [`Fatto: ${f}`];
  if (implication !== undefined && implication !== null && implication.trim() !== "") {
    body.push(`Implicazione: ${implication.trim()}`);
  }

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