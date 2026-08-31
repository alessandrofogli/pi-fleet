# pi-fleet — Architecture

## Overview — 3 Levels

| Level | Name | What it does | Wake | Token cost | Status |
|---|---|---|---|---|---|
| **L1** | Baseline | pi-subagents install, 6h timeout, FleetView | in-process (pi-subagents) | 0 extra | done |
| **L2** | Herdr-pane launcher | Background children in a dedicated fleet workspace (visible only in the agents sidebar) + worktree per task + in-process watcher | in-process watcher (3s poll) | 0 extra | done (M1+M2+M3+M4) |
| **L3** | External watcher | Wake **even when Pi is closed** — zero-token, restart-proof | external bash loop + durable queue | 0 (model runs only on actionable) | this milestone |

L2 already covers laptop suspend (freeze → resume). L3 exists only for **Pi really closed** or multi-harness.

---

## L3 Flow Diagram

```
 arm (session_start)             watcher (external bash)              queue              drain              wake
 ─────────────────               ─────────────────────                ─────              ─────              ────
 extensions/fleet-watch-arm.ts
   │  fleet-watch-arm.sh --restart
   │         │  fork fleet-watch.sh (singleton lock)
   │         │         │  poll 3s: classify
   │         │         │    benign (running, beat fresh) ──► absorb, sleep
   │         │         │    actionable ──► print reason, write .wake-queue/*.json, exit
   │         │         │                                    │
   │         │         │         Pi alive? ──YES──► child-close handler: rearm + sendMessage(triggerTurn)
   │         │         │                                    │
   │         │         │         Pi closed? ─NO──► file stays in .wake-queue/
   │         │         │                                    │         │
   │         │         │                                    │    next Pi open
   │         │         │                                    │    session_start → fleet-wake-drain.sh
   │         │         │                                    │         │  list + sendMessage(triggerTurn)
   │         │         │                                    │         │  --ack removes after delivery
   │         │         │                                    └─────────┘
```

### Pi-closed end-to-end

1. Task running → Pi closed (crash, quit, other harness).
2. Child finishes → writes `{id}.done.json` (or `.needs-input.json`) + updates `{id}.json` state.
3. External watcher (`fleet-watch.sh` still alive — child of arm, survives Pi exit) classifies `done:<id>` as actionable → writes `~/.pi/fleet/.wake-queue/<ts>-done-<id>.json` + exits. **Once per event (T-025)**: the first poll creates the per-record sentinel `.wake-done-<id>`; a persisted `{id}.done.json` is absorbed on every later poll (no hot-loop), and the sentinel is pruned as soon as the marker is consumed.
4. Pi reopened → `fleet-watch-arm.ts` `session_start`: `drainQueue()` finds file → `sendMessage({triggerTurn:true})` → captain wakes with queued reason.
5. Captain runs `fleet-wake-drain.sh --ack` (or tool `fleet_wake_drain_pi --ack`) to confirm.

---

## L3 Components

### `bin/fleet-lock-lib.sh`
Sourced library, no direct execution. Provides:
- `fleet_lock_try_acquire` — atomic `noclobber` singleton on `~/.pi/fleet/.watch.lock` (PID), steals stale (kill -0 fails).
- `fleet_lock_is_owned` — checks PID ∈ self/ancestors (8 ppid levels) + alive.
- `fleet_lock_release` — only if owned.
- `fleet_beat_touch` / `fleet_beat_age` — liveness beacon `~/.pi/fleet/.last-watcher-beat` (epoch seconds). Shared `FLEET_STATE_HOME` with extension.

### `bin/fleet-watch.sh`
Polling loop (default 3s). Singleton via `fleet-lock-lib.sh`. Classifies each poll:
- **Actionable** (exit with reason line): `done:<id>`, `needs_input:<id>`, `failed:<id>`, `queue:<file>` (new `.wake-queue/*.json`). On exit also appends to `~/.pi/fleet/.wake-queue/<ts>-<reason>.json` for durability + updates `.watch-last-reasons` dedup.
- **Done-wake dedup (T-025)**: `done:<id>` is queued **once per event** — mirror of the failed mechanism (`_fleet_already_queued` over `.wake-queue`) plus a per-record sentinel `.wake-done-<id>`: a persisted `{id}.done.json` never re-wakes after the first queue (the D1 hot-loop: +125 `.wake-queue` files in ~4.5 min). Every poll prunes sentinels whose `{id}.done.json` was consumed or whose audit `{id}.json` is gone, so a fresh `done` event for the same id wakes once again (delivery contract preserved). The audit record `{id}.json` is never touched.
- **Benign** (absorb): nothing new, tasks still `running`/`spawning` with fresh beat.
- **Health (T-019)** — frozen-pane watchdog (running panes only, started >30s):
  - *heartbeat = context growth*: herdr's per-agent `revision` (fallback: `agent read` transcript checksum). The "Working…" spinner is a session-state flag, never counted as alive.
  - context static for `min(bashTimeoutS, staleT)` → **auto-steer** in the durable inbox ("abort command + commit WIP", ack-path in the message) + immediate fire-and-forget prompt; exits `health: <id> bash-timeout|pane-stale` (a new actionable for the arm).
  - steer not acked within `killT` (default 5min) → **kill + relaunch**: `bin/fleet-relaunch.sh` salvages untracked files into the branch first (WIP base = last commit), writes `<id>.relaunch`, closes pane/tab (the launcher's own teardown), invokes `bin/herdr-launch.sh --resume`; exits `health: <id> relaunch`. Ack resets the timer (legit long commands get a configured tolerance). `needs_input`/`spawning`/`.abort`/`.relaunch` tasks are never killed. Thresholds: `FLEET_HEALTH_STALE_MIN/S`, `FLEET_HEALTH_KILL_MIN/S`, per-task `bashTimeoutS`, `FLEET_HEALTH_BASH_TIMEOUT_S`.
- Config: env-driven (`FLEET_POLL` seconds, default 3); tests drive bounded sequential passes with an isolated `FLEET_STATE_HOME` under /tmp (see `tests/smoke-done-wake-dedup.sh`).
- Trap cleans lock on INT/TERM.

### `bin/fleet-watch-arm.sh`
(Re-)arm wrapper. Verifies liveness before declaring success.
- If live+fresh watcher exists → `watcher: attached pid=<N> (beacon <age>s)` (no second watcher).
- Else steals stale lock, forks `fleet-watch.sh` via `nohup bash`, confirms within `FLEET_ARM_CONFIRM_TIMEOUT` (default 10s) → `watcher: started pid=<N> (beacon fresh)`.
- `--restart` kills only this `STATE_HOME`'s pid (no `pkill -f`), then relaunches.
- `--drain-check` lists `.wake-queue` or delegates to `fleet-wake-drain.sh`.
- Grace `FLEET_WATCH_GRACE` (default 300s) shared with lock lib.

### `bin/fleet-wake-drain.sh`
Durable queue consumer. Reads `~/.pi/fleet/.wake-queue/*.json` (excludes `.keep`).
- Default: list files + print first 500 chars each.
- `--count` → number.
- `--json` → `{"count":N,"files":[...]}`.
- `--ack` → remove after printing (acknowledge). `--dry-run` suppresses removal.
- Called by extension at `session_start` to surface wakes from Pi-closed interval.

### `bin/fleet-relaunch.sh` (T-019)
Standardized frozen-pane recovery, invoked detached by the watchdog at kill time (or manually):
1. **salvage** untracked/modified files onto the `fleet/<taskid>-*` branch FIRST (`chore(recovery): WIP salvage before relaunch (T-019)`) — relaunch base = last WIP commit, lossless;
2. **mark** `<id>.relaunch` BEFORE closing the pane (the original launcher, if alive, exits 0 on it without failing the task or releasing the worktree);
3. **kill** pane/tab with the launcher's own teardown (idempotent);
4. **resume** via `bin/herdr-launch.sh --resume <taskId>` (fresh pane, same brief, registry identity preserved).
`--dry-run` prints the plan JSON; `FLEET_RELAUNCH_LAUNCHER` allows tests to stub the launcher; PATH may shadow `herdr` for fixtures.

### `bin/herdr-launch.sh --resume` (T-019)
Resume mode: reuses the existing worktree (`state.cwd`, no new lease), re-aligns the branch on the WIP base from the `.relaunch` plan (named branch, `relaunches[]` appended to the state), rebuilds the same CHILD_PROMPT plus a RESUME NOTICE, and preserves `groupId`/`nested`/`depth`/gate from the existing registry state. The resumed launcher owns the final pane teardown and worktree release.

### `bin/herdr-launch.sh` — prompt delivery + consumption ACK (T-027)
Sending the brief is NOT delivery: the launcher logs `brief delivered` only after evidence the child CONSUMED it (the historical race: a prompt sent too early goes into the buffer and is lost → child sits at an empty prompt forever while the launcher waits for a done marker).
- **Readiness (stronger, fail-soft)**: after `agent wait --until idle` + `sleep 2`, a bounded wait for the pi input-layer signal `agent get → .result.agent.interactive_ready == true` (`FLEET_INPUT_READY_TRIES × FLEET_INPUT_READY_SLEEP`, default 5×3s). If never confirmed the launcher proceeds anyway — the consumption ACK below is the real delivery gate.
- **Consumption ACK**: after each send, poll every `FLEET_ACK_POLL_SECS` (default 3s) for up to `FLEET_ACK_POLLS_MAX` polls (default 8 → ~24s window) for ANY of: 1) `agent get` status left `idle` (working/thinking/blocked); 2) `agent get` revision moved; 3) the brief path visible in `agent read` (turn started); 4) the child session file(s) under `~/.pi/agent/sessions/<encoded-cwd>/` grew since the pre-prompt snapshot.
- **Retry**: not consumed within the window → re-send, up to `FLEET_PROMPT_ATTEMPTS_MAX` (default 3), bounded (2s) waits between attempts.
- **Fail-fast**: still no consumption → NO `brief delivered`; the task record is written `failed` (watcher → captain wake, durable relaunch possible), tab+pane closed, worktree released, launcher exits nonzero — never an empty pane left running.
Headless smoke: `tests/smoke-prompt-ack.sh` (mocked herdr/treehouse, isolated state): a nogrow child → retries + fail-fast + cleanup with no spurious `brief delivered`; grow children (status / session-file only) → ACKed at the first poll with exactly one send.

### Loop bound (T-019)
`bin/fleet-loop-helper.sh` gains `loop-init/loop-next/loop-final/loop-state`: the mechanical cycle counter `~/.pi/fleet/<loop>.loop.json` (`{cycle, maxCycles}`) is read/updated by the helper every cycle; `loop-next` REFUSES (exit 1, `refused:"maxCycles"`) beyond the bound and `loop-final` refuses any terminal verdict before `cycle == maxCycles` (`refused:"early-exit"`). The orchestrator template (`templates/fleet-loop-orchestrator.brief.md`) requires both calls, so the 3-cycle contract is machine-enforced, not prompt-only.

### `extensions/fleet-watch-arm.ts`
Lifecycle bridge. Captain-only (`cwd==HOME` or `PI_FLEET_CAPTAIN=1`).
- `session_start`: `drainQueue()` → if queue non-empty, `sendMessage({triggerTurn:true}, deliverAs:followUp)` with file list; then `armWatcher()` via `fleet-watch-arm.sh` (fire-and-verify, not held as ChildProcess — external process survives Pi).
- `session_shutdown`: marks generation stopping, clears retry timer.
- Retry backoff on arm failure: `350ms * 2^n` capped 5s, max 5 attempts → `fleet_watch_failed` wake if exhausted.
- Registers tools:
  - `fleet_watch_arm_pi` (`--restart`, `--drainCheck`) — manual rearm.
  - `fleet_wake_drain_pi` (`--ack`, `--json`) — manual drain.
- Exported `registerFleetWatchArm(pi)` called from `extensions/index.ts` (try/catch, L2 stays up if L3 missing).

### `extensions/index.ts` (integration point)
- `STATE_HOME = FLEET_STATE_HOME ?? ~/.pi/fleet` (same as bin scripts).
- At bottom of default export, after L2 watcher lifecycle: `try { registerFleetWatchArm(pi); } catch {}`.
- No circular import: `fleet-watch-arm.ts` is leaf.

---

## L3.5 Group Wake Barrier

A batch of N tasks launched in the same message → shared `groupId`, a single barriered digest.

### Behavior

| Case | Behavior | Wake |
|---|---|---|
| Group of 3, all `done` | No intermediate wake. When 3/3 → **single** verbose `fleet_notice` with 3 sections | `triggerTurn:false` (followUp) |
| Group of 3, one `needs_input` | **Immediate wake** (does not wait for the others): `group X: task Y requires input (2 running)` | `triggerTurn:true` |
| Group of 3, one `failed` | Barrier (waits for all, like `done`) → final digest `2 done + 1 failed` | `triggerTurn:true` if failed included |
| Mixed-duration group (1′ / 10′ / 25′) | The barrier delays early feedback — intentional. `fleet_status` stays consultable | — |
| Single task (no `groupId`) | Backward compatible: `groupId = task.id`, `groupSize = 1` → immediate wake as before | as L2/L3 |

`groupMode`: `"barrier"` (default) vs `"streaming"` per-group (future); `groupFailPolicy` implemented: `"waitAll"` (default) — failed buffered in the group digest — or `"immediate"` — failed wakes the captain right away with the group context (`group_failed_immediate`).

### Barrier flow diagram

```
 batch (1 LLM message)           launcher                watcher / coordinator         chat
 ─────────────────────            ────────                ─────────────────────         ────
 3× fleet_launch ──► groupId=grp-a1b2c3, groupSize=3 ──► 3 herdr side panes + worktrees
                      write {id}.json with groupId/size
                                                            │
 Task A done ──► writes {id}.done.json, closes the pane ────►│ buffers {id, summary}
 Task B done ──► idem ──────────────────────────────────────►│ buffers (2/3)
 Task C done ──► idem ──────────────────────────────────────►│ 3/3 → builds the verbose digest
                                                            │   "⚑ group grp-a1b2c3 complete (3/3)"
                                                            │   + per-task section (title, state, summary, changedFiles)
                                                            ├──────────────────────────────► sendMessage(fleet_notice, followUp)
                                                            │
 Task B needs_input ──► writes .needs-input.json ───────────►│ IMMEDIATE flush
                                                            │   "⚑ group grp-a1b2c3: task B needs input (A done, C running)"
                                                            ├──────────────────────────────► sendMessage(triggerTurn:true)
```

- Tabs/worktrees of finished tasks close immediately (state on disk, buffered wake).
- Only `needs_input` keeps the pane alive, as in L2.
- The main LLM at wake time produces a condensed synthesis (“in short: …”) — LLM's job, not the extension's.

### State format

```jsonc
// ~/.pi/fleet/{taskid}.json — L3.5 fields added (optional, backward compatible)
{
  "id": "refactor-auth-042",
  "groupId": "grp-20260828-a1b2c3",   // LLM-turn batch, or task.id when single
  "groupSize": 3,                      // expected in the group
  "groupLabel": "docs review",         // optional, from the batch title
  "groupMode": "barrier",             // "barrier" | "streaming" (future, default barrier)
  // ... rest unchanged (title, project, state, paneId, summary, changedFiles, ...)
}
// Group persistence for Pi-restart recovery:
// ~/.pi/fleet/.wake-groups/{groupId}.json
// { groupId, expected, label, mode, pending:[ids], results:{id:{state, summary}} }
```

- `groupId` auto-generated by the extension when not passed: all `fleet_launch` calls of the same LLM turn (or within a 2–3s window) share `grp-<date>-<rand6>`. An explicit `groupId` passed to `fleet_launch` wins (cross-turn groups).
- `groupSize` = how many tasks the extension launched in the batch (in-memory coordinator, persisted for recovery).
- Also persisted `~/.pi/fleet/.wake-groups/{groupId}.json` for recovery after a Pi restart: the coordinator rebuilds `pending` from the tasks on disk.

### How `fleet_status` shows groups

- **Single row**: if `task.groupSize > 1` → `- **Title** [done] (grp:grp-abc 2/3) — 5s ago — summary — /project` with `(grp:<shortId 8> done/total)` where `total = groupSize`, `done = count of terminal states in the group`.
- **Grouping**: group the output by `groupId` when tasks have groups:
  ```
  Group a1b2c3d4 (docs review) — 2/3 complete:
    - Task A [done] (grp:a1b2c3d4 2/3)
    - Task B [running] (grp:a1b2c3d4 2/3)
    - Task C [done] (grp:a1b2c3d4 2/3)
  Singles:
    - Task D [done]
  ```
  Uses `Map<groupId, Task[]>` and `GroupRecord` when available, otherwise groups by the `groupId` field.
- **Filter**: `fleet_status --group <id>` (or `fleet_status({groupId:"grp-..."})`) filters `tasks.filter(t => (t.groupId ?? t.id) === groupId)`.
- **Details**: `details: { tasks: clean, groups: groupSummaries }` where `groupSummaries = [{groupId, label, expected, done, pendingIds}]` (from `loadGroups()`/`rebuildGroupsFromDisk()` or direct count if the module is absent).
- Compatibility: does not break `tcs`, does not break single tasks (`groupSize=1` does not show `grp:`).

### Components touched

| File | L3.5 role |
|---|---|
| `extensions/index.ts` | Generates a `groupId` per batch, writes `groupId/size` into the task json; grouped `fleet_status` + filter + `grp:` |
| `extensions/fleet-group.ts` | `loadGroups`/`rebuildGroupsFromDisk`/`formatGroupDigest`/`recordTaskDone` + `.wake-groups/` persistence |
| `extensions/fleet-watch-arm.ts` | Barrier coordinator: `Map<groupId, {expected, pending, results}>`, buffers wakes, emits a digest when `pending==0` (exception `needs_input` → immediate flush) |
| `bin/fleet-watch.sh` | Classifies as before; for a task with `groupId` + `barrier` it does not write `.wake-queue` right away — it lets the extension decide (or writes it and the extension filters before `sendMessage`) |
| `bin/fleet-wake-drain.sh` | Group-aware drain (optional `holdUntilGroupComplete`) |

---

## State on Disk — `~/.pi/fleet/` layout

```
~/.pi/fleet/
├── tasks/                          # task briefs (mkdir -p at launch)
│   └── <id>.brief.md
├── .wake-queue/                    # L3 durable queue (mkdir -p at arm/watcher)
│   ├── .keep                       # gitkeep / placeholder
│   └── <epoch>-<reason>.json      # one per actionable exit, e.g. 1724800000-done-task-123.json
│                                   #   {"reason":"done:task-123","at":1724800000}
├── .watch.lock                     # singleton PID (fleet-lock-lib.sh)
├── .last-watcher-beat              # epoch seconds, touched each poll
├── .watch-last-reasons             # dedup: already-surfaced task basenames
├── .watch-seen-queue               # dedup: already-surfaced queue files
├── .watch-arm.log                  # arm/watcher stdout/stderr (nohup)
├── .watch-cycle-exits.log          # (firstmate parity, optional — not yet in MVP)
├── .health/                        # T-019 pane-health watchdog state
│   └── <id>.last                   # {rev, staticSince, p1Seq, p1At, p1Reason, relaunchCount}
├── <id>.json                       # task state file (see below)
├── <id>.done.json                  # child done marker (transient, consumed)
├── <id>.needs-input.json           # child needs_input marker
├── <id>.abort                      # abort signal (timestamp)
├── <id>.relaunch                   # T-019 relaunch plan {at, reason, base, branch} (transient)
├── <loop>.loop.json                # T-019 review-loop bound {cycle, maxCycles} (read/updated by the helper)
├── <id>.log                        # launcher log
├── <id>.bad                        # parse-failed state file (quarantined)
├── <id>.inbox/                     # durable steer: messages <seq>.json + ack markers + handled/
└── branch-outcomes.jsonl           # audit trail append-only: terminal transitions + needs_input
```

### `<id>.json` (TaskStateFile)

```json
{
  "id": "task-123",
  "title": "Refactor auth",
  "project": "~/projects/my-app",
  "cwd": "~/.treehouse/pi-fleet-xxx/1/my-app",
  "briefFile": "~/.pi/fleet/tasks/task-123.brief.md",
  "state": "spawning | running | done | failed | aborted | needs_input",
  "startedAt": 1724800000000,
  "lastBeatAt": 1724800005000,
  "doneAt": null,
  "timeoutMs": 21600000,
  "bashTimeoutS": 300,        // T-019 per-command bash tolerance (120..300), watchdog trigger
  "relaunches": [],           // T-019 append-only recovery records {at, reason, base, branch}
  "paneId": "pane-uuid",
  "tabId": "tab-uuid",     // dedicated tab in the fleet workspace (never empty; never the captain's tab)
  "workspaceId": "ws-uuid",
  "summary": "…",
  "changedFiles": ["src/auth.ts"]
}
```

---

## Acceptance Criteria — L3

- [ ] Pi closed during a run: at completion the wake is queued; on reopen it arrives in chat.
- [ ] No wake for benign events (steady heartbeat, `running` state).
- [ ] Unexpected watcher close → typed message + automatic retry (backoff).
- [ ] Kill mid-session → successor resumes without duplicates (lock + beacon).
- [ ] Killing the whole Pi leaves the external watcher alive (tracked child, not shell `&`).

---

## Differences from Firstmate (simplifications)

| Firstmate | pi-fleet L3 |
|---|---|
| `state/` + `config/` + `FM_HOME` per home, secondmate homes | Single `~/.pi/fleet/` (global), no secondmate |
| `bin/fm-watch.sh` 1000+ lines: no-verb/provably-working, wedge timer, escalation `demand-deep-inspection`, afk mode, authenticated external checks, inbox ladder, secondmate stall | `fleet-watch.sh`: done/failed/needs_input/queue + **T-019 pane-health watchdog** (context-growth heartbeat, bash-timeout trigger, steer → kill → relaunch ladder); no wedge/afk/external checks |
| `bin/fm-watch-arm.sh` with cycle ledger `.watch-cycle-exits.log`, identity-bound delivery, `fm-wake-lib.sh` etc. | `fleet-watch-arm.sh` ~170 lines: lock+beat verify, nohup fork, race-win attach, no ledger |
| `bin/fm-wake-drain.sh` with per-actor consume, `ELIGIBLE_ROWS_FILE` branch dispatch, `fm-lease-lib.sh` | `fleet-wake-drain.sh` ~95 lines: flat file list, no per-actor scoping |
| `.pi/extensions/fm-primary-pi-watch.ts` with generation, child handle, retry, calm visibility, branch dispatch | `fleet-watch-arm.ts` ~200 lines: generation, fire-and-verify arm, queue drain, retry backoff, captain gate |
| `state/.afk`, `FM_GUARD_GRACE` + `FM_ARM_CONFIRM_TIMEOUT` + `FM_PI_ARM_READY_TIMEOUT_MS` etc. | `FLEET_WATCH_GRACE` + `FLEET_ARM_CONFIRM_TIMEOUT` only |
| `AGENTS.md` pretool hook `fm-arm-pretool-check.sh` | No pretool hook |
| Secondmate distributed fleet | Not in scope |

Simplifications are intentional: pi-fleet L3 is the **zero-token wake for Pi-closed** only; the heavy supervision taxonomy (wedge, escalation, afk triage) stays out of MVP and can be layered later if needed.

---

## M1 + M2 Architecture (for completeness)

See `README.md` Architecture section for M1 (launcher) + M2 (extension watcher/reconcile/captain gate/active model). This document focuses on L3, but the full picture is:

- **M1**: `bin/herdr-launch.sh` — dedicated fleet workspace (`workspace list` label "fleet"+cwd, else `workspace create --label fleet --cwd <project> --no-focus`, race-safe), `tab create --workspace <fleet> --cwd <worktree> --no-focus` (visible ONLY in the agents sidebar; never in the captain's tab), `treehouse get --lease --no-fetch`, `agent start --model <provider/id>` (always full id, never bare; unique `f-<slug>-<rand>` name), brief delivery, marker wait with liveness-check (15s) + abort marker.
- **M2**: `extensions/index.ts` — 13 tools: 12 in the extension (`fleet_launch/status/outcomes/peek/steer/posture/abort/attach/bootstrap/learn/captain_pref/stow`) + `fleet_watch_arm_pi` in `extensions/fleet-watch-arm.ts`; detached launcher via `spawn("bash", ..., {detached:true})` + `unref` (no python), 3s poll watcher (any terminal state → `fleet_notice` with `display:false` + `deliverAs:followUp` + `triggerTurn:true`; silent only inside barrier groups), seeding, reconcile (pane dead → done/failed/aborted), captain gate, active model `ctx.model` composed as `provider/id` (never bare id, fallback `PI_PROVIDER`/`PI_DEFAULT_MODEL`).

---

## Additional features

Added on top of M1/M2/L3.5 without changing the defaults (`ship`, `barrier`, `waitAll`, `no-mistakes`). All new modules are lazy-imported and fail-soft (same pattern as `fleet-group.ts`).

| Feature | Where | Behavior |
|---|---|---|
| **Scout tasks** (`kind: "scout"`) | `fleet_launch`, `bin/herdr-launch.sh`, `extensions/fleet-group.ts` | The child produces only `report.md` (no commit/PR); done-marker with `reportPath`, merged from the state (`{id}.json`) |
| **Durable inbox** | `fleet_steer`, `extensions/fleet-inbox.ts`, `bin/fleet-watch.sh` | Message persisted in `<id>.inbox/<seq>.json`, delivered via `runHerdr`, re-rings until acked (`reRingInFlight` guard, then escalation to `fleet_notice` after maxReplays); `replay:false` = legacy fire-and-forget |
| **Delivery posture** | `fleet_launch`, `extensions/fleet-posture.ts`, CHILD_PROMPT | `--delivery-posture` (no-mistakes/direct-PR/local-only/yolo); rules injected into the child prompt, default from `postures.json` |
| **Branch outcomes** | `extensions/fleet-outcomes.ts`, `fleet_status`, `reconcileStaleTasks`, `fleet_abort` | Audit trail append-only `branch-outcomes.jsonl` (terminal transitions + `needs_input`), best-effort |
| **groupFailPolicy** | `fleet_launch`, `extensions/fleet-group.ts`, watcher | `waitAll` (default) vs `immediate` → `group_failed_immediate` event wakes the captain immediately with group context |
| **Bootstrap** | hook `session_start`, `extensions/fleet-bootstrap.ts`, tool `fleet_bootstrap` | Tool check, safe stale-state cleanup, fleet digest; never blocking (`triggerTurn:false`) |
| **Captain learnings/prefs** | hook `session_start`, `extensions/fleet-learn.ts`, tool `fleet_learn`/`fleet_captain_pref` | `captain.md`/`captain-shared.md`/`learnings.md` in `~/.pi/fleet/` (never in git), 24h dedup, written atomically |

`extensions/index.ts` structure at the seams: `sendWake` (third param `overrides?: {detail?}` for the immediate-fail path) + separate `sendAttention` helper; `startWatcher` → best-effort `appendOutcome` first, then group/wake logic, then event handling (`group_failed_immediate`, inbox reRing).