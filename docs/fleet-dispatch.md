# fleet_dispatch — remote command entry point (Hermes NL bridge)

> T-022. **Additive**: the tool only *adds* a captain-side entry point for remote
> commands. It does not change `fleet_launch`, `fleet_status`, `fleet_outcomes`,
> the watcher, the launcher, the loop or the review/tickets flows.

## Why it exists

`dispatch-cmd.sh` (a dotfiles script on the personal Mac mini) injects commands
into the captain through the **durable needs-input channel**: it writes

- `$STATE_HOME/<id>.json` — a minimal record (`state` + `kind: "dispatch"`, id
  pattern `cmd-*`), and
- `$STATE_HOME/<id>.needs-input.json` — `{"question":"<command>","taskState":"needs_input"}`.

Within `FLEET_POLL` (default 3s) the watcher classifies the pair as
`signal: <id>.needs-input` (see `bin/fleet-watch.sh:231-245`) and wakes the
captain.

**Proven problem (ticket #7 testing)**: the captain woke, but treated the
minimal `cmd-*` records as stray tasks and aborted them on sight (it even
learned "abort on sight"). Config-level fixes were exhausted: the needs-input
channel is designed for *children asking questions mid-task*, not for injecting
new commands.

**The fix**: a real captain-side tool `fleet_dispatch` that the captain invokes
when it sees a dispatch wake — executing the command with **existing**
capabilities and writing `<id>.done.json` so `dispatch-cmd.sh` completes.

## Tool contract

```
fleet_dispatch(taskId: string, command: string)
```

| Step | Behavior |
|---|---|
| 1. Validate `taskId` | Must match `^[A-Za-z0-9_-]+$` (defense: only act on records under `STATE_HOME`; never interpret the id as a path / follow symlinks). Invalid → **rejected**, nothing written. |
| 2. Parse `command` | **Fixed allowlist**: `fleet_status` · `fleet_outcomes` · `fleet_launch <project> <brief...>` (project = absolute path, `~/path` or short name if `FLEET_PROJECTS_DIR` is set; brief = rest of the line; title derived `Remote: <brief first 60 chars>`). Unknown/malformed → **refused**. |
| 3. Execute | `fleet_status` / `fleet_outcomes` → same result text as the existing tools (same helpers: `formatTaskLine`, `scopedTasks`, outcomes module). `fleet_launch …` → spawns `bin/herdr-launch.sh` exactly like the `fleet_launch` tool (see [Reuse points](#reuse-points)). |
| 4. Write the done-marker | Atomic tmp+rename `$STATE_HOME/<id>.done.json` `{"status":"done","summary":"<result text>"}`; refused → `{"status":"failed","summary":"refused: command not allowed"}`. `<id>.json` + `<id>.needs-input.json` are **kept for audit** (never deleted by the tool; `dispatch-cmd.sh --cleanup` removes them later). |
| 5. Return | The summary text (also returned as the tool result to the captain). |

**Single-writer**: the tool only *writes* `<taskId>.done.json` (plus the brief
file + task record of a launched task via the launcher pattern). It never
touches other task state.

Launch summary format: `launched task <newTaskId> (project <path>);
follow-up via fleet_status/fleet_outcomes` — the launched task has its own
lifecycle and wake, like any normal `fleet_launch`.

## Allowlist (exact parse)

- `fleet_status` — exact match. `fleet_status extra` → refused.
- `fleet_outcomes` — exact match. Extra args → refused.
- `fleet_launch <project> <brief...>` — the first token after the verb is the
  project, the rest of the line is the brief (lowercase verb only; paths with
  spaces are not supported — same as the CLI contract).
- Everything else (e.g. `rm -rf /`, `fleet_peek`, `fleet_steer x y`,
  `FLEET_STATUS`) → `refused: command not allowed`.

## Integration path (end to end)

```
phone / Hermes (Mac mini)                laptop (pi-fleet captain)
──────────────────────────               ────────────────────────────
Hermes tool-calling runs dispatch-cmd.sh
  ├─ writes $STATE/<id>.json            watcher (fleet-watch.sh)
  │    (state running, kind dispatch)     └─ signal: <id>.needs-input
  └─ writes <id>.needs-input.json         └─ wake → captain wakes
        {"question":"<command>",...}            │
                                             captain calls fleet_dispatch
                                             (taskId=<id>, command=<question>)
                                                ├─ fleet_status / fleet_outcomes
                                                │    → answered directly
                                                ├─ fleet_launch <p> <brief…>
                                                │    → REAL task (herdr tab +
                                                │      worktree, own lifecycle/wake)
                                                └─ writes <id>.done.json (atomic)
                                                     │
dispatch-cmd.sh polls <id>.done.json ◄───────────┘
  ├─ reads {"status","summary"} → Hermes reports ("come va T-015?" → status text)
  └─ --cleanup removes <id>.json + <id>.needs-input.json (+ the done.json)
```

**Watcher contract reused** (no changes): pair detection at
`bin/fleet-watch.sh:231-245` (`signal: <id>.needs-input`), wake enqueue at
`bin/fleet-watch.sh:409`, delivery via `extensions/fleet-watch-arm.ts` →
`pi.sendMessage` (`fleet_notice`, triggerTurn). The dispatch record has no
paneId, so the T-019 pane-health watchdog never touches it; a record without
`startedAt` also skips the timeout scan.

**Completion echo**: while `<id>.done.json` stays on disk (until `--cleanup`),
the watcher classifies `signal: <id>.done` — the captain may receive one
completion echo for the dispatch record. That is *expected*: acknowledge the
summary, do **not** re-execute the command (the tool promptGuidelines say so).

## Behavior for executed commands

| Command | Result |
|---|---|
| `fleet_status` | same text as `fleet_status` (default 30 rows, group layout when present) — `done.json` `status=done` |
| `fleet_outcomes` | same readable list as `fleet_outcomes` (default 20 rows) — `done.json` `status=done` |
| `fleet_launch <p> <brief…>` | real task: `tasks/<newId>.brief.md` + `<newId>.json` (`spawning`) + launcher spawn; `done.json` `status=done` summary `launched task <newId> …` |
| `fleet_launch` with an **unresolvable project** | `done.json` `status=failed`, summary = the resolve reason (`fleet_launch refused: …`) — **no spawn** (same as `fleet_launch` requiring a valid project) |
| unknown / malformed | `done.json` `status=failed`, summary `refused: command not allowed` |
| invalid `taskId` (path-like) | rejected, **nothing written** |

## Reuse points

The launch path reuses the exact `fleet_launch` semantics (verified against
`extensions/index.ts` at the commit of this doc):

- **Project required** — `resolveProject()` (`extensions/index.ts:216`);
  unresolvable → rejected, no spawn.
- **Launcher spawn** — `spawnLauncher()` (`extensions/index.ts:302`):
  same brief-file handling (`tasks/<id>.brief.md`, `@<path>`), same flags from
  the same argument set; **no invented flags**.
- **Worktree default ON** — `spawnLauncher` pushes `--no-worktree` only when
  `worktree === false`; the dispatch launch never sets `worktree` → default ON,
  identical to a normal `fleet_launch`.
- **Delivery posture** — `getFleetPosture()` config > default `no-mistakes`
  (same chain as `extensions/index.ts:1012-1016`).
- **T-011 gate** — gate active only when posture `no-mistakes` AND the project
  has `gate.yaml`; `autoPr` from `gate.yaml` (same as `extensions/index.ts:1073-1085`).
- **Model inheritance** — `ctx.model` composed as `provider/id` (never the bare
  id), then `PI_DEFAULT_MODEL`, else no `--model` (same as
  `extensions/index.ts:1091-1103`).
- **Defaults** — timeout 360 min, `kind: ship`, nested off, depth 1.

**One deliberate difference**: a dispatched launch gets a **fresh groupId**
(`grp-…`) and does not join the `fleet_launch` batch window (`lastGroupId`):
a remote command is an isolated launch and must not be barrier-coupled to an
in-progress captain-side batch. All other semantics identical.

## Deployment (the macOS mini side — steps only the user can do)

The tool ships with the extension; deploying = updating the repo + restarting
the captain session so the new tool is registered:

1. On the pi host, `cd <pi-fleet clone> && git pull` (the captain merges the
   `fleet/022-fleet-dispatch` branch first), then restart the captain / the
   pi-fleet extension (new pi session or extension reload) so `fleet_dispatch`
   is registered.
2. `dispatch-cmd.sh` (dotfiles, on the mini) stays unchanged: its injection
   contract (`<id>.json` with `kind: "dispatch"`, `<id>.needs-input.json`,
   poll `<id>.done.json`, `--cleanup`) is what `fleet_dispatch` completes.
3. Smoke before first use: `bash tests/smoke-dispatch.sh` (isolated state,
   never touches `~/.pi/fleet`).
4. Optional: Hermes prompt guidance — when a dispatch wake arrives
   (`signal: cmd-*.needs-input`), the captain must call `fleet_dispatch`
   instead of aborting the record (covered by the tool's `promptGuidelines`,
   which pi injects automatically).

## Tests

`tests/smoke-dispatch.sh` (headless, isolated `FLEET_STATE_HOME` under /tmp):
tsc compile check, real-watcher detection of the injection pair
(`signal: <id>.needs-input`), and the **real compiled extension** driven with a
mock pi + spawn recorder — allowed/refused commands, atomic `done.json`,
single-writer marker invariance, launch arg contract (worktree default ON,
project required, model inheritance). `bash -n` + run green; exit 0.