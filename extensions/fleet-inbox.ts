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

// ------------------------------------------------------------------ types ---

/**
 * Task inbox message persisted on disk (fleet-group.ts style: sync
 * functions, readFileSync/writeFileSync, soft try/catch — no dependency on
 * herdr: delivery is injected as a callback).
 *
 * On-disk contract (directory `$STATE_HOME/<taskId>.inbox/`):
 * - `<seq>.json` = { "seq": N, "message": "...", "createdAt": ms,
 *                    "acked": false, "replays": 0 }  (+ optional fields)
 * - ack: the child creates the empty file `<seq>.acked` after reading/applying
 *   the message; the watcher moves the json to `handled/` (markAcked).
 * - sequential seq: max existing (inbox + handled) + 1.
 */
export interface InboxMsg {
  /** Sequence number (max existing + 1). */
  seq: number;
  /** Message content (the fleet_steer text). */
  message: string;
  /** Epoch ms of the enqueue. */
  createdAt: number;
  /** Always false in the file: the ack is the `<seq>.acked` marker (the json goes to handled/). */
  acked: boolean;
  /** How many times the message has been delivered (deliver) so far. */
  replays: number;
  /** Epoch ms of the last deliver (set by deliver). */
  lastReplayAt?: number;
  /** replay:false ⇒ fire-and-forget: single delivery, NEVER re-rung. */
  fireAndForget?: boolean;
  /** true after escalation: the message stays on disk but is no longer re-rung. */
  escalated?: boolean;
}

/** Text delivery callback to the child (herdr agent prompt), injected to keep the module pure. */
export type SendFn = (message: string) => boolean | PromiseLike<boolean>;

/** Delivery callback for reRing: receives the full message, returns the outcome. */
export type DeliverFn = (msg: InboxMsg) => boolean | PromiseLike<boolean>;

export interface ReRingOptions {
  stateHome: string;
  taskId: string;
  /** Actual delivery AND replay REGISTRATION: must update replays++/lastReplayAt on disk (normally the bound `deliver(stateHome, taskId, seq, send)`), otherwise the escalation never fires. */
  deliver: DeliverFn;
  /** Minimum interval between one replay and the next (default 60_000 ms). */
  intervalMs?: number;
  /** Max number of replays before escalation (default 5). */
  maxReplays?: number;
  /** Called ONCE per message when replays >= maxReplays (the message stays on disk). */
  onEscalation?: (taskId: string, msg: InboxMsg) => void;
  /** Called when the loop ends on its own (no more ringable messages) or via stop(). */
  onIdle?: (taskId: string) => void;
}

// ----------------------------------------------------------- base helpers ---

/** Inbox directory of a task: `$STATE_HOME/<taskId>.inbox/`. */
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

/** Reads a message; missing/corrupted file → null (fail soft). */
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

/** Atomic write (tmp + rename), creates the dir if missing. */
function writeMsg(stateHome: string, taskId: string, msg: InboxMsg): void {
  const dir = inboxDir(stateHome, taskId);
  mkdirSync(dir, { recursive: true });
  const dest = msgPath(stateHome, taskId, msg.seq);
  const tmp = `${dest}.tmp-${process.pid}-${Date.now()}`;
  writeFileSync(tmp, JSON.stringify(msg, null, 2) + "\n", "utf8");
  renameSync(tmp, dest);
}

/**
 * Next seq: max between inbox dir and handled (keeps monotonicity even after
 * the move to handled/). Corrupted/foreign files → ignored.
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
 * Queues a message on disk (ATOMIC tmp+rename write). Seq = max existing + 1.
 * `replay:false` ⇒ `fireAndForget:true` field (the message is delivered once
 * but NEVER re-rung). Error path → {ok:false}.
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
    // fail soft: no crash of the caller
    return { ok: false, seq };
  }
}

/**
 * Pending non-acked messages, sorted by ascending seq. A message with the
 * `<seq>.acked` marker present is NOT pending anymore (even if the json has
 * not yet been moved to handled/).
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
    if (existsSync(ackPath(stateHome, taskId, seq))) continue; // acked
    const msg = readMsg(stateHome, taskId, seq);
    if (msg) out.push(msg);
  }
  out.sort((a, b) => a.seq - b.seq);
  return out;
}

/**
 * Delivers a pending message: invokes the `send` callback (herdr agent
 * prompt) and, on success, updates `replays++` / `lastReplayAt` on disk.
 * Failed send or throw → false (replays unchanged, next round retries).
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
      // soft: the replay count is lost, the next round restarts it
    }
  }
  return ok;
}

/**
 * Moves an acked message to `handled/` and removes the `<seq>.acked` marker.
 * Requires the marker to exist; otherwise false.
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
 * Re-ring loop for a task (one timer per task; returns the stop() for the
 * caller's guard). Each round:
 *  - moves acked messages to handled/ (marker `<seq>.acked`);
 *  - for each pending: if >= intervalMs since last replay and replays<max →
 *    deliver; if replays>=max → onEscalation (ONCE, `escalated:true`) and
 *    stops ringing that message (it stays on disk);
 *  - fire-and-forget: never rung (only single delivery at enqueue);
 *  - when nothing ringable remains → terminates and calls onIdle.
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
      // 1. move acked messages to handled/ (marker <seq>.acked). NOTE:
      // scan of ALL *.json (listPending excludes already-acked, so the
      // directory must be read directly).
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
      // 2. escalation sweep (also covers messages already at replays>=max from
      //    previous runs: escalated only once, `escalated:true` stays on disk)
      const pending = listPending(stateHome, taskId);
      escalateIfDue(pending);
      const ringableCount = pending.filter(
        (m) => !m.fireAndForget && (m.replays ?? 0) < maxReplays,
      ).length;
      if (ringableCount === 0) {
        // nothing to ring (all acked/fire-and-forget/escalation) → done
        stop();
        return;
      }
      // 3. delivery loop: only non-acked, non-escalated, due messages
      for (const msg of pending) {
        if (msg.fireAndForget) continue;
        if ((msg.replays ?? 0) >= maxReplays) continue;
        const lastAt = msg.lastReplayAt ?? msg.createdAt;
        if (Date.now() - lastAt >= intervalMs) {
          try {
            await deliver(msg);
          } catch {
            /* soft: the next round retries */
          }
        }
      }
      // 4. if a deliver just brought replays to max, escalate NOW
      //    (otherwise the loop would stop without ever escalating the message)
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
      // fail soft: the re-ring must never crash the watcher
      if (!stopped) schedule(intervalMs);
    }
  };

  // first immediate round (normally nothing to deliver: the immediate delivery
  // already happened in fleet_steer; here the RE-ring is governed)
  schedule(0);
  return stop;
}