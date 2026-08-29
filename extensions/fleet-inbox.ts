/** pi-fleet · durable task inbox + re-ring — 5b.2 */

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

// ------------------------------------------------------------------ tipi ---

/**
 * Messaggio del task inbox persistito su disco (stile fleet-group.ts: funzioni
 * sync, readFileSync/writeFileSync, try/catch soft — nessuna dipendenza da
 * herdr: la consegna è iniettata come callback).
 *
 * Contratto su disco (directory `$STATE_HOME/<taskId>.inbox/`):
 * - `<seq>.json` = { "seq": N, "message": "...", "createdAt": ms,
 *                    "acked": false, "replays": 0 }  (+ campi opzionali)
 * - ack: il figlio crea il file vuoto `<seq>.acked` dopo aver letto/applicato
 *   il messaggio; il watcher sposta il json in `handled/` (markAcked).
 * - seq sequenziali: max esistente (inbox + handled) + 1.
 */
export interface InboxMsg {
  /** Numero di sequenza (max esistente + 1). */
  seq: number;
  /** Contenuto del messaggio (testo del fleet_steer). */
  message: string;
  /** Epoch ms dell'enqueue. */
  createdAt: number;
  /** Sempre false nel file: l'ack è il marker `<seq>.acked` (il json va in handled/). */
  acked: boolean;
  /** Quante volte il messaggio è stato consegnato (deliver) finora. */
  replays: number;
  /** Epoch ms dell'ultimo deliver (impostato da deliver). */
  lastReplayAt?: number;
  /** replay:false ⇒ fire-and-forget: consegna singola, MAI re-ringato. */
  fireAndForget?: boolean;
  /** true dopo l'escalation: il messaggio resta su disco ma non viene più ringato. */
  escalated?: boolean;
}

/** Callback di consegna del testo al figlio (herdr agent prompt), iniettata per mantenere il modulo puro. */
export type SendFn = (message: string) => boolean | PromiseLike<boolean>;

/** Callback di consegna per reRing: riceve il messaggio completo, ritorna esito. */
export type DeliverFn = (msg: InboxMsg) => boolean | PromiseLike<boolean>;

export interface ReRingOptions {
  stateHome: string;
  taskId: string;
  /** Consegna effettiva e REGISTRAZIONE del replay: deve aggiornare replays++/lastReplayAt su disco (di norma `deliver(stateHome, taskId, seq, send)` bindato), altrimenti l'escalation non scatta mai. */
  deliver: DeliverFn;
  /** Intervallo minimo tra un replay e il successivo (default 60_000 ms). */
  intervalMs?: number;
  /** Numero massimo di replay prima dell'escalation (default 5). */
  maxReplays?: number;
  /** Chiamato UNA volta per messaggio quando replays >= maxReplays (il messaggio resta su disco). */
  onEscalation?: (taskId: string, msg: InboxMsg) => void;
  /** Chiamato quando il loop termina da solo (niente più messaggi ringabili) o via stop(). */
  onIdle?: (taskId: string) => void;
}

// ----------------------------------------------------------- helpers base ---

/** Directory inbox di un task: `$STATE_HOME/<taskId>.inbox/`. */
export function inboxDir(stateHome: string, taskId: string): string {
  return join(stateHome, `${taskId}.inbox`);
}

function handledDir(stateHome: string, taskId: string): string {
  return join(inboxDir(stateHome, taskId), "handled");
}

function msgPath(stateHome: string, taskId: string, seq: number): string {
  return join(inboxDir(stateHome, taskId), `${seq}.json`);
}

function ackPath(stateHome: string, taskId: string, seq: number): string {
  return join(inboxDir(stateHome, taskId), `${seq}.acked`);
}

/** Legge un messaggio; file mancante/corrotto → null (fail soft). */
function readMsg(stateHome: string, taskId: string, seq: number): InboxMsg | null {
  try {
    const raw = readFileSync(msgPath(stateHome, taskId, seq), "utf8");
    const data = JSON.parse(raw) as Partial<InboxMsg>;
    if (typeof data.seq !== "number" || typeof data.message !== "string") return null;
    return {
      seq: data.seq,
      message: data.message,
      createdAt: typeof data.createdAt === "number" ? data.createdAt : Date.now(),
      acked: data.acked === true,
      replays: typeof data.replays === "number" ? data.replays : 0,
      lastReplayAt: typeof data.lastReplayAt === "number" ? data.lastReplayAt : undefined,
      fireAndForget: data.fireAndForget === true ? true : undefined,
      escalated: data.escalated === true ? true : undefined,
    };
  } catch {
    return null;
  }
}

/** Scrittura atomica (tmp + rename), crea la dir se mancante. */
function writeMsg(stateHome: string, taskId: string, msg: InboxMsg): void {
  const dir = inboxDir(stateHome, taskId);
  mkdirSync(dir, { recursive: true });
  const dest = msgPath(stateHome, taskId, msg.seq);
  const tmp = `${dest}.tmp-${process.pid}-${Date.now()}`;
  writeFileSync(tmp, JSON.stringify(msg, null, 2) + "\n", "utf8");
  renameSync(tmp, dest);
}

/**
 * Prossimo seq: max tra inbox dir e handled (mantiene la monotonia anche dopo
 * lo spostamento in handled/). File corrotti/estranei → ignorati.
 */
function nextSeq(stateHome: string, taskId: string): number {
  let max = 0;
  const scan = (dir: string): void => {
    let names: string[] = [];
    try {
      names = readdirSync(dir);
    } catch {
      return;
    }
    for (const name of names) {
      if (!name.endsWith(".json")) continue;
      const n = Number.parseInt(name.slice(0, -5), 10);
      if (Number.isFinite(n) && n > max) max = n;
    }
  };
  scan(inboxDir(stateHome, taskId));
  scan(handledDir(stateHome, taskId));
  return max + 1;
}

// -------------------------------------------------------------- API ---

/**
 * Accoda un messaggio sul disco (scrittura ATOMICA tmp+rename). Seq = max
 * esistente + 1. `replay:false` ⇒ campo `fireAndForget:true` (il messaggio
 * viene consegnato una volta ma MAI re-ringato). Sentiero d'errore → {ok:false}.
 */
export function enqueue(
  stateHome: string,
  taskId: string,
  message: string,
  opts?: { replay?: boolean },
): { ok: boolean; seq: number } {
  const seq = nextSeq(stateHome, taskId);
  const msg: InboxMsg = {
    seq,
    message,
    createdAt: Date.now(),
    acked: false,
    replays: 0,
    ...(opts?.replay === false ? { fireAndForget: true } : {}),
  };
  try {
    writeMsg(stateHome, taskId, msg);
    return { ok: true, seq };
  } catch {
    // fail soft: niente crash del chiamante
    return { ok: false, seq };
  }
}

/**
 * Messaggi pendenti non ackati, ordinati per seq crescente. Un messaggio con
 * il marker `<seq>.acked` presente NON è più pendente (anche se il json non è
 * ancora stato spostato in handled/).
 */
export function listPending(stateHome: string, taskId: string): InboxMsg[] {
  let names: string[] = [];
  try {
    names = readdirSync(inboxDir(stateHome, taskId));
  } catch {
    return [];
  }
  const out: InboxMsg[] = [];
  for (const name of names) {
    if (!name.endsWith(".json")) continue;
    const seq = Number.parseInt(name.slice(0, -5), 10);
    if (!Number.isFinite(seq)) continue;
    if (existsSync(ackPath(stateHome, taskId, seq))) continue; // ackato
    const msg = readMsg(stateHome, taskId, seq);
    if (msg) out.push(msg);
  }
  out.sort((a, b) => a.seq - b.seq);
  return out;
}

/**
 * Consegna un messaggio pendente: invoca la callback `send` (herdr agent
 * prompt) e, a successo, aggiorna `replays++` / `lastReplayAt` su disco.
 * Send fallito o throw → false (replays invariati, il prossimo giro ritenta).
 */
export async function deliver(
  stateHome: string,
  taskId: string,
  seq: number,
  send: SendFn,
): Promise<boolean> {
  const msg = readMsg(stateHome, taskId, seq);
  if (!msg) return false;
  let ok: boolean;
  try {
    ok = await send(msg.message);
  } catch {
    ok = false;
  }
  if (ok) {
    msg.replays = (msg.replays ?? 0) + 1;
    msg.lastReplayAt = Date.now();
    try {
      writeMsg(stateHome, taskId, msg);
    } catch {
      // soft: il conteggio replica si perde, il prossimo giro ricomincia
    }
  }
  return ok;
}

/**
 * Sposta un messaggio ackato in `handled/` e rimuove il marker `<seq>.acked`.
 * Richiede che il marker esista; altrimenti false.
 */
export function markAcked(stateHome: string, taskId: string, seq: number): boolean {
  const ack = ackPath(stateHome, taskId, seq);
  if (!existsSync(ack)) return false;
  const src = msgPath(stateHome, taskId, seq);
  try {
    if (existsSync(src)) {
      const dir = handledDir(stateHome, taskId);
      mkdirSync(dir, { recursive: true });
      renameSync(src, join(dir, `${seq}.json`));
    }
    rmSync(ack, { force: true });
    return true;
  } catch {
    return false;
  }
}

/**
 * Loop di re-ring per un task (un timer per task; ritorna la stop() per il
 * guard del chiamante). Ogni giro:
 *  - sposta in handled/ i messaggi ackati (marker `<seq>.acked`);
 *  - per ogni pendente: se da >= intervalMs dall'ultimo replay e replays<max →
 *    deliver; se replays>=max → onEscalation (UNA volta, `escalated:true`) e
 *    smette di ringare quel messaggio (resta su disco);
 *  - fire-and-forget: mai ringato (solo consegna singola all'enqueue);
 *  - quando non resta più nulla di ringabile → termina e chiama onIdle.
 */
export function reRing(opts: ReRingOptions): () => void {
  const { stateHome, taskId, deliver, onEscalation, onIdle } = opts;
  const intervalMs = opts.intervalMs ?? 60_000;
  const maxReplays = opts.maxReplays ?? 5;
  let timer: ReturnType<typeof setTimeout> | null = null;
  let stopped = false;

  const stop = (): void => {
    if (stopped) return;
    stopped = true;
    if (timer) {
      clearTimeout(timer);
      timer = null;
    }
    try {
      onIdle?.(taskId);
    } catch {
      /* ignore */
    }
  };

  const schedule = (delayMs: number): void => {
    if (stopped) return;
    timer = setTimeout(() => void tick(), Math.max(delayMs, 1));
  };

  const escalateIfDue = (list: InboxMsg[]): void => {
    for (const msg of list) {
      if (msg.fireAndForget) continue;
      if ((msg.replays ?? 0) >= maxReplays && !msg.escalated) {
        msg.escalated = true;
        try {
          writeMsg(stateHome, taskId, msg);
        } catch {
          /* soft */
        }
        try {
          onEscalation?.(taskId, msg);
        } catch {
          /* soft */
        }
      }
    }
  };

  const tick = async (): Promise<void> => {
    if (stopped) return;
    try {
      // 1. sposta in handled/ i messaggi ackati (marker <seq>.acked). NOTA:
      // scan su TUTTI i *.json (listPending esclude i già ackati, quindi va
      // letta la directory direttamente).
      let names: string[] = [];
      try {
        names = readdirSync(inboxDir(stateHome, taskId));
      } catch {
        names = [];
      }
      for (const name of names) {
        if (!name.endsWith(".json")) continue;
        const seq = Number.parseInt(name.slice(0, -5), 10);
        if (!Number.isFinite(seq)) continue;
        if (existsSync(ackPath(stateHome, taskId, seq))) {
          try {
            markAcked(stateHome, taskId, seq);
          } catch {
            /* soft */
          }
        }
      }
      // 2. escalation sweep (copre anche messaggi già a replays>=max da run
      //    precedenti: esculati una sola volta, `escalated:true` resta su disco)
      const pending = listPending(stateHome, taskId);
      escalateIfDue(pending);
      const ringableCount = pending.filter(
        (m) => !m.fireAndForget && (m.replays ?? 0) < maxReplays,
      ).length;
      if (ringableCount === 0) {
        // niente da ringare (tutto ackato/fire-and-forget/escalation) → fine
        stop();
        return;
      }
      // 3. delivery loop: solo messaggi non ackati, non escalation, dovuti
      for (const msg of pending) {
        if (msg.fireAndForget) continue;
        if ((msg.replays ?? 0) >= maxReplays) continue;
        const lastAt = msg.lastReplayAt ?? msg.createdAt;
        if (Date.now() - lastAt >= intervalMs) {
          try {
            await deliver(msg);
          } catch {
            /* soft: il giro dopo ritenta */
          }
        }
      }
      // 4. se un deliver ha appena portato replays a max, escalation SUBITO
      //    (altrimenti il loop si fermerebbe senza mai esculare il messaggio)
      if (stopped) return;
      escalateIfDue(listPending(stateHome, taskId));
      const stillRingable = listPending(stateHome, taskId).some(
        (m) => !m.fireAndForget && (m.replays ?? 0) < maxReplays,
      );
      if (stopped) return;
      if (stillRingable) {
        schedule(intervalMs);
      } else {
        stop();
      }
    } catch {
      // fail soft: il re-ring non deve mai far crashare il watcher
      if (!stopped) schedule(intervalMs);
    }
  };

  // primo giro immediato (di norma niente da consegnare: la consegna immediata
  // è già avvenuta in fleet_steer; qui si governa il RE-ring)
  schedule(0);
  return stop;
}