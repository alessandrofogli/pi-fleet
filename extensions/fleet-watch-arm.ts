/** pi-fleet · watcher esterno L3 — port semplificato di fm-primary-pi-watch.ts
 *
 * Gestisce il ciclo di vita del watcher esterno zero-token:
 * generation ownership, lock ownership, arm child, classifica close,
 * riarmo del successore PRIMA del wake (ordering critico), retry backoff,
 * confirm handling-delivered, drain queue, tool fleet_watch_arm_pi.
 *
 * Semplificazioni vs firstmate (MVP):
 * - niente branch dispatch / secondmate
 * - niente calm presentation
 * - niente encodeFirstmateOperationalInput — usa pi.sendMessage diretto
 * - beat generation semplice Date.now()-pid
 */

import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import type { GroupRecord, GroupTaskInfo } from "./fleet-group.js";

// ---------------------------------------------------------------- tipi ----
type ArmResult = { ok: boolean; message: string };
type LockOwnership = "owned" | "missing" | "other";
type CloseClassification = { kind: "actionable" | "failure"; message: string };
type SessionGeneration = {
  id: number;
  stopping: boolean;
  child: ChildProcess | null;
  retryTimer: ReturnType<typeof setTimeout> | null;
  retryFailures: number;
  restoring: boolean;
  seq: number;
};

// --------------------------------------------------------------- costanti ----
const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);

const retryBaseMs = positiveInteger("FLEET_WATCH_REARM_RETRY_BASE_MS", 250);
const retryMaxMs = positiveInteger("FLEET_WATCH_REARM_RETRY_MAX_MS", 4000);
const retryLimit = positiveInteger("FLEET_WATCH_REARM_RETRY_LIMIT", 5);
const armReadyTimeoutMs = positiveInteger("FLEET_PI_ARM_READY_TIMEOUT_MS", 12000);
const armRetireTimeoutMs = positiveInteger("FLEET_WATCH_ARM_RETIRE_TIMEOUT_MS", 1000);

const repairOnlyHint =
  "call fleet_watch_arm_pi again only after a later notification says the cycle is missing, failed, or unhealthy";
const shuttingDownMessage = "watcher: not armed - Pi session is shutting down";

let extensionVersion = "unknown";
try {
  extensionVersion = `sha256:${createHash("sha256").update(readFileSync(extensionFile)).digest("hex")}`;
} catch { /* ignore */ }

// ---------------------------------------------------------- generation ----
let nextGenerationId = 0;
let activeGeneration: SessionGeneration | null = null;
const armReadiness = new WeakMap<ChildProcess, Promise<boolean>>();
const armClose = new WeakMap<ChildProcess, Promise<void>>();
const armRecovery = new WeakMap<ChildProcess, { generation: string; watcherPid: string }>();

function positiveInteger(name: string, fallback: number): number {
  const v = Number(process.env[name]);
  if (!Number.isFinite(v) || v <= 0) return fallback;
  return Math.floor(v);
}

function parentPid(pid: string): string {
  const r = spawnSync("ps", ["-o", "ppid=", "-p", pid], { encoding: "utf8" });
  if (r.status !== 0) return "";
  return r.stdout.trim();
}

function pidAlive(pid: string): boolean {
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}

function lockOwnership(stateHome: string): LockOwnership {
  // pi-fleet usa .watch.lock (spec L3); fallback su .lock per compatibilità
  let lockPid = "";
  for (const name of [".watch.lock", ".lock"]) {
    try {
      lockPid = readFileSync(join(stateHome, name), "utf8").trim();
      if (lockPid) break;
    } catch { /* prova prossimo */ }
  }
  if (!lockPid) return "missing";
  if (!/^[0-9]+$/.test(lockPid) || lockPid === "1") return "other";
  let pid = String(process.pid);
  for (let i = 0; i < 8; i += 1) {
    if (pid === lockPid) return "owned";
    pid = parentPid(pid);
    if (!pid || pid === "1") break;
  }
  return pidAlive(lockPid) ? "other" : "missing";
}

function markLoaded(stateHome: string): void {
  if (lockOwnership(stateHome) === "other") return;
  try {
    mkdirSync(stateHome, { recursive: true });
    writeFileSync(join(stateHome, ".pi-watch-extension-loaded"), `${extensionVersion}\n${process.pid}\n`);
  } catch { /* ignore */ }
}

function actionableLine(output: string): string {
  const lines = output.split(/\r?\n/);
  return lines.find((line) => /^(signal:|stale:|check:|heartbeat($|:))/.test(line)) || "";
}

function classifyClose(
  stdout: string,
  stderr: string,
  code: number | null,
  signal: NodeJS.Signals | null,
): CloseClassification {
  const combined = `${stdout}\n${stderr}`.trim();
  const reason = actionableLine(combined);
  if (reason) return { kind: "actionable", message: reason };
  const healthy = combined.split(/\r?\n/).find((line) => /^watcher: healthy\b/.test(line));
  if (healthy) {
    return {
      kind: "failure",
      message: `watcher: FAILED - Pi extension arm child found an external healthy watcher instead of owning wake delivery\n${healthy}`,
    };
  }
  const failed = combined.split(/\r?\n/).find((line) => /^watcher: FAILED/.test(line));
  if (failed) return { kind: "failure", message: failed };
  if (signal) {
    return {
      kind: "failure",
      message: `watcher: FAILED - Pi extension arm child ended from ${signal}${combined ? `\n${combined}` : ""}`,
    };
  }
  if (code && code !== 0) {
    return {
      kind: "failure",
      message: `watcher: FAILED - fleet-watch-arm.sh exited ${code}${combined ? `\n${combined}` : ""}`,
    };
  }
  return {
    kind: "failure",
    message: "watcher: FAILED - Pi extension arm cycle ended without an actionable reason",
  };
}

function createGeneration(): SessionGeneration {
  return { id: ++nextGenerationId, stopping: false, child: null, retryTimer: null, retryFailures: 0, restoring: false, seq: 0 };
}
function activateGeneration(g: SessionGeneration): void {
  activeGeneration = g;
}
function generationIsLive(g: SessionGeneration): boolean {
  return activeGeneration === g && !g.stopping;
}
function stopGeneration(g: SessionGeneration): void {
  g.stopping = true;
  if (g.retryTimer) clearTimeout(g.retryTimer);
  g.retryTimer = null;
  if (g.child) g.child.kill("SIGTERM");
  g.child = null;
}

const cleanupOnProcessExit = (): void => {
  if (activeGeneration) stopGeneration(activeGeneration);
};
process.once("exit", cleanupOnProcessExit);

// ------------------------------------------------------- mount principale ----
export interface FleetWatchArmOpts {
  stateHome: string;
  extDir: string;
  root: string;
}

export function mountFleetWatchArm(pi: ExtensionAPI, opts: FleetWatchArmOpts): { ok: boolean; message: string } {
  const stateHome = opts.stateHome;
  const root = opts.root;
  const armScript = join(root, "bin", "fleet-watch-arm.sh");
  const drainScript = join(root, "bin", "fleet-wake-drain.sh");

  // Fail soft se lo script non esiste ancora (altri task paralleli non finiti)
  if (!existsSync(armScript)) {
    const msg = `fleet-watch-arm: skip — ${armScript} non trovato (fallback in-process)`;
    try { (pi as unknown as { logger?: { warn: (m: string) => void } }).logger?.warn(msg); } catch { /* ignore */ }
    console.warn(`[pi-fleet] ${msg}`);
    return { ok: false, message: msg };
  }

  let generation = createGeneration();
  activateGeneration(generation);

  // L3.5 barrier: mappa gruppi + lazy loader fail-soft
  const groupMap: Map<string, GroupRecord> = new Map();
  let _fleetGroup: typeof import("./fleet-group.js") | null = null;
  async function getFleetGroup(): Promise<typeof import("./fleet-group.js") | null> {
    if (_fleetGroup) return _fleetGroup;
    try { _fleetGroup = await import("./fleet-group.js"); return _fleetGroup; } catch { return null; }
  }
  function getFleetGroupSync(): typeof import("./fleet-group.js") | null { return _fleetGroup; }
  void getFleetGroup().catch(() => {});
  // rebuild iniziale best-effort (sync se già caricato, altrimenti async)
  void (async () => {
    try {
      const mod = await getFleetGroup();
      if (!mod) return;
      // scansiona task json per rebuild
      const { readdirSync, readFileSync } = await import("node:fs");
      let names: string[] = [];
      try { names = readdirSync(stateHome); } catch { return; }
      const tasks: unknown[] = [];
      for (const n of names) {
        if (!n.endsWith(".json") || n.endsWith(".done.json") || n.endsWith(".needs-input.json") || n.startsWith(".")) continue;
        try { tasks.push(JSON.parse(readFileSync(join(stateHome, n), "utf8"))); } catch { /* skip */ }
      }
      const rebuilt = mod.rebuildGroupsFromDisk(stateHome, tasks as Parameters<typeof mod.rebuildGroupsFromDisk>[1]);
      for (const [k, v] of rebuilt) groupMap.set(k, v);
    } catch { /* ignore */ }
  })();

  // ------------------------- helpers chiusi su opts/stateHome/armScript ----

  function encodeWake(message: string): string {
    // Semplificato vs firstmate: string diretta con drain hint
    const drainHint = existsSync(drainScript) ? "\n\nRun bin/fleet-wake-drain.sh first and handle the queued wake." : "";
    return `FLEET WATCHER WAKE: ${message}${drainHint}`;
  }

  async function sendWake(owner: SessionGeneration, message: string): Promise<void> {
    if (!generationIsLive(owner)) return;
    const content = encodeWake(message);
    // pi-fleet usa customType fleet_notice come il watcher in-process
    await (pi as unknown as { sendMessage: (msg: unknown, opts: unknown) => Promise<void> }).sendMessage(
      { customType: "fleet_notice", content, display: true, details: { source: "fleet-watch-arm" } },
      { triggerTurn: true, deliverAs: "followUp" },
    );
  }

  function confirmHandlingDelivery(recovery: { generation: string; watcherPid: string }): { ok: boolean; detail: string } {
    try {
      const result = spawnSync("bash", [armScript, "--handling-delivered", recovery.generation, "--watcher-pid", recovery.watcherPid], {
        cwd: root,
        encoding: "utf8",
        env: { ...process.env, FLEET_STATE_HOME: stateHome, FLEET_ROOT_OVERRIDE: root },
      });
      if (result.status === 0) return { ok: true, detail: "" };
      const stderr = (result.stderr || "").trim();
      return {
        ok: false,
        detail: `watcher: FAILED - handling delivery confirmation was rejected (status=${result.status ?? "none"} generation=${recovery.generation} watcherPid=${recovery.watcherPid})${stderr ? `\n${stderr}` : ""}`,
      };
    } catch (error) {
      const msg = error instanceof Error ? error.message : String(error);
      return {
        ok: false,
        detail: `watcher: FAILED - handling delivery confirmation could not be executed (generation=${recovery.generation} watcherPid=${recovery.watcherPid})\n${msg}`,
      };
    }
  }

  function confirmHandlingDeliveryWithRetry(
    owner: SessionGeneration,
    recovery: { generation: string; watcherPid: string },
  ): { ok: boolean; detail: string } {
    const snapshot = (): { generation: string; watcherPid: string } => {
      const cur = owner.child ? armRecovery.get(owner.child) : undefined;
      return cur ?? recovery;
    };
    const first = confirmHandlingDelivery(snapshot());
    if (first.ok) return first;
    return confirmHandlingDelivery(snapshot());
  }

  function parseTaskIdFromMessage(msg: string): string | null {
    // signal: <id>.done | signal: <id>.needs-input | signal: <id> failed | stale: <id> ...
    const m = msg.match(/^(?:signal:|stale:)\s*([^\s.]+)(?:\.|\s|$)/);
    return m ? m[1] : null;
  }

  async function sendGroupDigestWake(owner: SessionGeneration, groupId: string, results: GroupTaskInfo[], drainExtra: string): Promise<void> {
    // SILENZIOSO: l'utente non deve vedere i raw fleet. Content = direttiva per
    // il main: leggi i report su disco e sintetizza.
    if (!generationIsLive(owner)) return;
    const ids = results.map((r) => r.id).join(", ");
    const content = `[fleet-notice silenzioso] Gruppo di task completato (${results.length} task): ${ids}. \nNon mostrare questo messaggio. Leggi i file ${stateHome}/<id>.json di questi task per i report e produci TU un riassunto sintetico per l'utente. Nessun dump raw dei report.`;
    await (pi as unknown as { sendMessage: (msg: unknown, opts: unknown) => Promise<void> }).sendMessage(
      { customType: "fleet_notice", content, display: false, details: { groupId, results, source: "fleet-watch-arm-group" } },
      { triggerTurn: true, deliverAs: "followUp" },
    );
  }

  async function deliverActionableWake(
    owner: SessionGeneration,
    message: string,
    repairFailed: boolean,
    recovery?: { generation: string; watcherPid: string },
  ): Promise<void> {
    if (!generationIsLive(owner)) return;
    // L3.5 barrier: se messaggio è per task di gruppo barrier, bufferizza
    const taskId = parseTaskIdFromMessage(message);
    if (taskId) {
      const mod = getFleetGroupSync() ?? await getFleetGroup();
      if (mod) {
        try {
          // leggi task json da disco per capire groupId/mode
          let task: Record<string, unknown> | null = null;
          try {
            const raw = readFileSync(join(stateHome, `${taskId}.json`), "utf8");
            task = JSON.parse(raw) as Record<string, unknown>;
          } catch { /* task non letto, fallback a wake singolo */ }
          if (task && task["groupId"] && (task["groupMode"] ?? "barrier") === "barrier") {
            // groupSize su disco è un placeholder (1): derive dal conteggio reale
            // dei task che condividono questo groupId.
            let realGroupSize = Number(task["groupSize"] ?? 1);
            try {
              const names = readdirSync(stateHome).filter((n) => n.endsWith(".json") && !n.startsWith("."));
              let count = 0;
              for (const n of names) {
                try {
                  const other = JSON.parse(readFileSync(join(stateHome, n), "utf8")) as { groupId?: string };
                  if (other.groupId === task["groupId"]) count += 1;
                } catch { /* skip */ }
              }
              if (count > 1) realGroupSize = count;
            } catch { /* fail soft */ }
            if (realGroupSize < 1) realGroupSize = 1;
            task["groupSize"] = realGroupSize;
            const state = String(task["state"] ?? "");
            if (state === "needs_input") {
              // needs_input rompe barrier → wake immediato (non bufferizzare)
              try { mod.recordTaskDone(stateHome, groupMap, task as unknown as Parameters<typeof mod.recordTaskDone>[2]); } catch { /* ignore */ }
              // continua al flusso normale (consegna wake)
            } else if (state === "done" || state === "failed") {
              const ev = mod.recordTaskDone(stateHome, groupMap, task as unknown as Parameters<typeof mod.recordTaskDone>[2]);
              if (ev.kind === "buffered") {
                // barrier: non consegnare wake singolo, successore già riarmato da restoreAfterActionableClose
                // Conferma handling se presente, poi esci senza sendMessage
                if (recovery) {
                  const confirmed = confirmHandlingDeliveryWithRetry(owner, recovery);
                  if (!confirmed.ok && !pidAlive(recovery.watcherPid)) await retireArm(owner.child);
                }
                return;
              }
              if (ev.kind === "group_complete") {
                // Drain opzionale
                let drainExtra = "";
                if (existsSync(drainScript)) {
                  try {
                    const d = spawnSync("bash", [drainScript], { cwd: root, encoding: "utf8", env: { ...process.env, FLEET_STATE_HOME: stateHome, FLEET_ROOT_OVERRIDE: root }, timeout: 5000 });
                    const out = (d.stdout || "").trim();
                    if (out) drainExtra = `\n\n[drain] ${out.slice(0, 2000)}`;
                  } catch { /* ignore */ }
                }
                if (recovery) {
                  const confirmed = confirmHandlingDeliveryWithRetry(owner, recovery);
                  if (!confirmed.ok) {
                    if (!pidAlive(recovery.watcherPid)) await retireArm(owner.child);
                    await sendWake(owner, `${message}${drainExtra}\n\n${confirmed.detail}`);
                    return;
                  }
                }
                await sendGroupDigestWake(owner, ev.groupId, ev.results, drainExtra);
                void repairFailed;
                return;
              }
            }
          }
        } catch { /* fail soft → wake singolo */ }
      }
    }
    // Fallback: wake singolo (retrocompatibile)
    let drainExtra = "";
    if (existsSync(drainScript)) {
      try {
        const d = spawnSync("bash", [drainScript], {
          cwd: root,
          encoding: "utf8",
          env: { ...process.env, FLEET_STATE_HOME: stateHome, FLEET_ROOT_OVERRIDE: root },
          timeout: 5000,
        });
        const out = (d.stdout || "").trim();
        if (out) drainExtra = `\n\n[drain] ${out.slice(0, 2000)}`;
      } catch { /* drain best-effort */ }
    }
    if (recovery) {
      const confirmed = confirmHandlingDeliveryWithRetry(owner, recovery);
      if (!confirmed.ok) {
        const watcherPid = recovery.watcherPid;
        if (!pidAlive(watcherPid)) {
          await retireArm(owner.child);
        }
        await sendWake(owner, `${message}${drainExtra}\n\n${confirmed.detail}`);
        return;
      }
    }
    await sendWake(owner, `${message}${drainExtra}`);
    void repairFailed;
  }

  function surfaceFailure(owner: SessionGeneration, message: string): void {
    void sendWake(owner, message).catch(() => { /* Pi owns delivery errors */ });
  }

  function retryDelay(attempt: number): number {
    return Math.min(retryMaxMs, retryBaseMs * 2 ** Math.max(0, attempt - 1));
  }
  function waitForRetry(attempt: number): Promise<void> {
    return new Promise((resolveRetry) => {
      const t = setTimeout(resolveRetry, retryDelay(attempt));
      // @ts-ignore — unref may not exist in some env
      if (typeof (t as unknown as { unref?: () => void }).unref === "function") (t as unknown as { unref: () => void }).unref!();
    });
  }
  function waitForReadiness(armChild: ChildProcess): Promise<boolean> {
    const readiness = armReadiness.get(armChild);
    if (!readiness) return Promise.resolve(false);
    return new Promise((resolveReady) => {
      const timer = setTimeout(() => resolveReady(false), armReadyTimeoutMs);
      if (typeof (timer as unknown as { unref?: () => void }).unref === "function") (timer as unknown as { unref: () => void }).unref!();
      void readiness.then((ready) => {
        clearTimeout(timer);
        resolveReady(ready);
      });
    });
  }
  async function retireArm(armChild: ChildProcess | null): Promise<boolean> {
    if (!armChild) return true;
    armChild.kill("SIGTERM");
    const closed = armClose.get(armChild);
    if (!closed) return false;
    return new Promise((resolveRetired) => {
      const timer = setTimeout(() => resolveRetired(false), armRetireTimeoutMs);
      if (typeof (timer as unknown as { unref?: () => void }).unref === "function") (timer as unknown as { unref: () => void }).unref!();
      void closed.then(() => {
        clearTimeout(timer);
        resolveRetired(true);
      });
    });
  }

  async function restoreAfterActionableClose(
    owner: SessionGeneration,
    predecessorArmPid: string,
  ): Promise<{ failure: string; recovery?: { generation: string; watcherPid: string } }> {
    let failure = "";
    for (let attempt = 0; attempt <= retryLimit; attempt += 1) {
      if (!generationIsLive(owner)) return { failure: "" };
      const replacement = startArm(owner, predecessorArmPid);
      const successorChild = owner.child;
      if (replacement.ok && successorChild && (await waitForReadiness(successorChild))) {
        return { failure: "", recovery: armRecovery.get(successorChild) };
      }
      if (replacement.ok) {
        failure = "watcher: FAILED - Pi extension could not verify a ready successor watcher";
        if (!(await retireArm(successorChild))) {
          return {
            failure: `${failure}\nwatcher: FAILED - Pi extension could not restore watcher continuity because the unready successor arm did not exit within ${armRetireTimeoutMs}ms`,
          };
        }
      } else {
        failure = /(?:read-only|no live session)/.test(replacement.message)
          ? `watcher: FAILED - Pi extension cannot restore continuity because this session no longer owns the lock\n${replacement.message}`
          : `watcher: FAILED - Pi extension could not start the successor watcher cycle\n${replacement.message}`;
        if (/(?:read-only|no live session)/.test(replacement.message)) break;
      }
      if (attempt === retryLimit) break;
      await waitForRetry(attempt + 1);
    }
    return { failure: `${failure}\nwatcher: FAILED - Pi extension could not restore watcher continuity after ${retryLimit} retries` };
  }

  function scheduleRetry(owner: SessionGeneration, message: string, predecessorArmPid: string): void {
    if (!generationIsLive(owner) || owner.child || owner.retryTimer) return;
    const ownership = lockOwnership(stateHome);
    if (ownership !== "owned") {
      surfaceFailure(owner, `watcher: FAILED - Pi extension cannot restore continuity because this session no longer owns the lock\n${message}`);
      return;
    }
    owner.retryFailures += 1;
    if (owner.retryFailures > retryLimit) {
      surfaceFailure(owner, `watcher: FAILED - Pi extension could not restore watcher continuity after ${retryLimit} retries\n${message}`);
      return;
    }
    const timer = setTimeout(() => {
      if (owner.retryTimer === timer) owner.retryTimer = null;
      if (!generationIsLive(owner)) return;
      const result = startArm(owner, predecessorArmPid);
      if (!result.ok) {
        surfaceFailure(owner, `watcher: FAILED - Pi extension could not launch a continuity retry\n${result.message}`);
      }
    }, retryDelay(owner.retryFailures));
    if (typeof (timer as unknown as { unref?: () => void }).unref === "function") (timer as unknown as { unref: () => void }).unref!();
    owner.retryTimer = timer;
  }

  function startArm(owner: SessionGeneration, predecessorArmPid = ""): ArmResult {
    if (!generationIsLive(owner)) return { ok: false, message: shuttingDownMessage };
    const ownership = lockOwnership(stateHome);
    if (ownership === "other") return { ok: false, message: "watcher: read-only - session lock is held by another fleet session" };
    if (ownership === "missing") {
      return {
        ok: false,
        message: "watcher: not armed - no live session holds the lock; call fleet_watch_arm_pi to re-arm",
      };
    }
    markLoaded(stateHome);
    if (owner.child) {
      return {
        ok: true,
        message: `watcher: unchanged - Pi extension already owns an arm child; no manual re-arm needed; ${repairOnlyHint}`,
      };
    }
    if (owner.retryTimer) {
      return {
        ok: true,
        message: `watcher: unchanged - Pi extension already owns a scheduled continuity retry; no manual re-arm needed; ${repairOnlyHint}`,
      };
    }
    const id = ++owner.seq;
    const env = {
      ...process.env,
      FLEET_STATE_HOME: stateHome,
      FLEET_ROOT_OVERRIDE: root,
      FLEET_WATCH_PREDECESSOR_ARM_PID: predecessorArmPid,
    };
    let armChild: ChildProcess;
    try {
      armChild = spawn("bash", [armScript, "--restart"], { cwd: root, env, stdio: ["ignore", "pipe", "pipe"] });
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      return { ok: false, message: `watcher: FAILED - spawn failed: ${msg}` };
    }
    owner.child = armChild;
    let stdout = "";
    let stderr = "";
    let settled = false;
    let readinessSettled = false;
    let resolveReadiness: (ready: boolean) => void = () => {};
    let resolveClosed: () => void = () => {};
    const readiness = new Promise<boolean>((resolveReady) => {
      resolveReadiness = resolveReady;
    });
    armReadiness.set(armChild, readiness);
    const closed = new Promise<void>((resolveClosedChild) => {
      resolveClosed = resolveClosedChild;
    });
    armClose.set(armChild, closed);
    const settleReadiness = (ready: boolean): void => {
      if (readinessSettled) return;
      readinessSettled = true;
      resolveReadiness(ready);
    };
    const observeEstablishedArm = (): void => {
      const combined = `${stdout}\n${stderr}`;
      const recovery = combined.match(/^watcher: started pid=([0-9]+).* recovery-generation=([A-Za-z0-9._-]+)$/m);
      if (recovery) armRecovery.set(armChild, { watcherPid: recovery[1], generation: recovery[2] });
      if (/^watcher: (?:started|attached)\b/m.test(combined)) settleReadiness(true);
    };
    const releaseChild = (): void => {
      if (owner.child === armChild) owner.child = null;
    };
    armChild.stdout?.on("data", (chunk: Buffer) => {
      stdout += chunk.toString();
      observeEstablishedArm();
    });
    armChild.stderr?.on("data", (chunk: Buffer) => {
      stderr += chunk.toString();
      observeEstablishedArm();
    });
    armChild.on("close", (code: number | null, signal: NodeJS.Signals | null) => {
      if (settled) return;
      settled = true;
      resolveClosed();
      settleReadiness(false);
      releaseChild();
      if (!generationIsLive(owner)) return;
      const classification = classifyClose(stdout, stderr, code, signal);
      const predecessor = String(armChild.pid ?? "");
      if (classification.kind === "actionable") {
        if (owner.restoring) return;
        owner.retryFailures = 0;
        owner.restoring = true;
        void (async () => {
          try {
            const restoration = await restoreAfterActionableClose(owner, predecessor);
            if (!generationIsLive(owner)) return;
            const msg = restoration.failure ? `${classification.message}\n\n${restoration.failure}` : classification.message;
            await deliverActionableWake(owner, msg, Boolean(restoration.failure), restoration.recovery);
          } catch (error) {
            const detail = error instanceof Error ? error.message : String(error);
            surfaceFailure(owner, `watcher: FAILED - Pi extension could not deliver an actionable wake\n${detail}`);
          } finally {
            if (generationIsLive(owner)) owner.restoring = false;
          }
        })();
        return;
      }
      if (owner.restoring) return;
      scheduleRetry(owner, classification.message, predecessor);
    });
    armChild.on("error", (error: Error) => {
      if (settled) return;
      settled = true;
      resolveClosed();
      settleReadiness(false);
      releaseChild();
      if (!generationIsLive(owner)) return;
      if (owner.restoring) return;
      scheduleRetry(owner, `watcher: FAILED - Pi extension arm child ${id} failed: ${error.message}`, String(armChild.pid ?? ""));
    });
    return {
      ok: true,
      message: `watcher: started Pi extension arm child ${id}; future ordinary re-arms are automatic; ${repairOnlyHint}`,
    };
  }

  // Drain iniziale di eventuali wake pendenti (Pi era chiuso)
  function drainPendingAtStartup(): void {
    if (!existsSync(drainScript)) return;
    try {
      const r = spawnSync("bash", [drainScript, "--count"], {
        cwd: root,
        encoding: "utf8",
        env: { ...process.env, FLEET_STATE_HOME: stateHome, FLEET_ROOT_OVERRIDE: root },
        timeout: 5000,
      });
      const count = Number((r.stdout || "").trim());
      if (count > 0) {
        // c'è roba vera: drena con dettaglio per il wake
        const detail = spawnSync("bash", [drainScript], {
          cwd: root,
          encoding: "utf8",
          env: { ...process.env, FLEET_STATE_HOME: stateHome, FLEET_ROOT_OVERRIDE: root },
          timeout: 5000,
        });
        const out = (detail.stdout || "").trim();
        void sendWake(generation, `drain: pending wakes on startup\n${out.slice(0, 3000)}`).catch(() => {});
      }
    } catch { /* best-effort */ }
  }

  // Lifecycle binding
  const onSessionStart = (): void => {
    if (generation.stopping) {
      generation = createGeneration();
      activateGeneration(generation);
    } else if (activeGeneration !== generation) {
      activateGeneration(generation);
    }
    markLoaded(stateHome);
    drainPendingAtStartup();
    // Se non c'è già un child/retry, prova ad armare (fail soft se lock missing)
    if (!generation.child && !generation.retryTimer) {
      const res = startArm(generation);
      if (!res.ok && !/read-only|not armed/.test(res.message)) {
        console.warn(`[pi-fleet] watch-arm session_start: ${res.message}`);
      }
    }
  };
  const onSessionShutdown = (): void => {
    stopGeneration(generation);
  };

  // Pi events: supporto sia pi.on che pi.events.on
  try {
    const on = (pi as unknown as { on?: (e: string, h: () => void) => void }).on;
    if (typeof on === "function") {
      on.call(pi, "session_start", onSessionStart);
      on.call(pi, "session_shutdown", onSessionShutdown);
    }
  } catch { /* ignore */ }
  try {
    const evOn = (pi as unknown as { events?: { on?: (e: string, h: () => void) => void } }).events?.on;
    if (typeof evOn === "function") {
      // already handled via pi.on; evita doppia registrazione se stesso emitter
    }
  } catch { /* ignore */ }

  // Tool per primo arm / repair esplicito
  pi.registerTool({
    name: "fleet_watch_arm_pi",
    label: "Arm fleet watcher (external)",
    description:
      "Start the first required Pi watcher cycle, or repair one only after a notification says the cycle is missing, failed, or unhealthy. Do not call after ordinary work or ordinary notifications; the Pi extension re-arms automatically. Never run bin/fleet-watch-arm.sh through bash.",
    promptSnippet: "Start the first required Pi watcher cycle or repair a cycle reported missing, failed, or unhealthy; ordinary re-arming is automatic.",
    promptGuidelines: ["Call only for first cycle or after notification says cycle missing/failed/unhealthy"],
    parameters: Type.Object({}),
    async execute() {
      const result = startArm(generation);
      return { content: [{ type: "text", text: result.message }], details: result };
    },
  });

  // Registra anche command se disponibile
  try {
    const rc = (pi as unknown as { registerCommand?: (name: string, def: unknown) => void }).registerCommand;
    if (typeof rc === "function") {
      rc.call(pi, "fleet-watch-arm-pi", {
        description: "Arm fleet watcher supervision through the Pi extension instead of foreground bash.",
        handler: async (_args: unknown, ctx: { ui: { notify: (m: string, l: string) => void } }) => {
          const result = startArm(generation);
          ctx.ui.notify(result.message, result.ok ? "info" : "warning");
        },
      });
    }
  } catch { /* ignore */ }

  markLoaded(stateHome);
  drainPendingAtStartup();
  // Arm iniziale: best-effort, fail soft se lock non owned
  const initial = startArm(generation);
  if (!initial.ok && !/read-only|not armed/.test(initial.message)) {
    console.warn(`[pi-fleet] watch-arm initial: ${initial.message}`);
  }

  return initial;
}

// Alias per compatibilità con spec alternativa
export const createFleetWatchArm = mountFleetWatchArm;
