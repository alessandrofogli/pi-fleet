# pi-fleet — Architecture

## Overview — 3 Levels

| Level | Name | What it does | Wake | Token cost | Status |
|---|---|---|---|---|---|
| **L1** | Baseline | pi-subagents install, 6h timeout, FleetView | in-process (pi-subagents) | 0 extra | done |
| **L2** | Herdr-pane launcher | Visible herdr tabs + worktree per task + in-process watcher | in-process watcher (3s poll) | 0 extra | done (M1+M2+M3+M4) |
| **L3** | Watcher esterno | Wake **even when Pi is closed** — zero-token, restart-proof | external bash loop + durable queue | 0 (model runs only on actionable) | this milestone |

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
   │         │         │         Pi vivo? ──YES──► child-close handler: rearm + sendMessage(triggerTurn)
   │         │         │                                    │
   │         │         │         Pi chiuso? ─NO──► file stays in .wake-queue/
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
3. External watcher (`fleet-watch.sh` still alive — child of arm, survives Pi exit) classifies `done:<id>` as actionable → writes `~/.pi/fleet/.wake-queue/<ts>-done-<id>.json` + exits.
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
- **Benign** (absorb): nothing new, tasks still `running`/`spawning` with fresh beat.
- Flags: `--interval N`, `--once` (single classify, for tests).
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

## State on Disk — `~/.pi/fleet/` layout

```
~/.pi/fleet/
├── tasks/                          # brief per task (mkdir -p at launch)
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
├── <id>.json                       # task state file (see below)
├── <id>.done.json                  # child done marker (transient, consumed)
├── <id>.needs-input.json           # child needs_input marker
├── <id>.abort                      # abort signal (timestamp)
├── <id>.log                        # launcher log
└── <id>.bad                        # parse-failed state file (quarantined)
```

### `<id>.json` (TaskStateFile)

```json
{
  "id": "task-123",
  "title": "Refactor auth",
  "project": "/Users/you/projects/my-app",
  "cwd": "/Users/you/.treehouse/pi-fleet-xxx/1/my-app",
  "briefFile": "~/.pi/fleet/tasks/task-123.brief.md",
  "state": "spawning | running | done | failed | aborted | needs_input",
  "startedAt": 1724800000000,
  "lastBeatAt": 1724800005000,
  "doneAt": null,
  "timeoutMs": 21600000,
  "paneId": "pane-uuid",
  "tabId": "tab-uuid",
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
| `bin/fm-watch.sh` 1000+ lines: no-verb/provably-working, wedge timer, escalation `demand-deep-inspection`, afk mode, authenticated external checks, inbox ladder, secondmate stall | `fleet-watch.sh` ~130 lines: done/failed/needs_input/queue only; no wedge, no afk, no inbox ladder, no external checks |
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

- **M1**: `bin/herdr-launch.sh` — workspace resolve, `treehouse get --lease --no-fetch`, `tab create --no-focus`, `agent start --model <ctx.model>` (unique `f-<slug>-<rand>` name), brief delivery, marker wait with liveness-check (15s) + abort marker.
- **M2**: `extensions/index.ts` — 6 tools (`fleet_launch/status/peek/steer/abort/attach`), detached double-fork launcher, 3s poll watcher (`done` followUp no triggerTurn, `failed/needs_input` triggerTurn), seeding, reconcile (pane dead → done/failed/aborted), captain gate, active model `ctx.model.id`.
