# pi-fleet

Visible sub-agents for [pi](https://github.com/earendil-works/pi) (`@earendil-works/pi-coding-agent`): delegate a task and a child `pi` starts in a **dedicated herdr "fleet" workspace** (background tab, `--no-focus`), working in an **isolated treehouse worktree**. The child never steals focus and never occupies space in your tab: it appears **only in the herdr agents sidebar (left)**, whose state rolls up per workspace. The main chat stays free, and the result lands back in the chat via a **silent, non-interrupting directive** (`display:false` + `deliverAs: followUp` + `triggerTurn:true`) that the main agent synthesizes for you; failures and `needs_input` are the ones that explicitly demand the captain (in barrier groups, per-task wakes are buffered into a single group digest).

A [Firstmate](https://github.com/kunchenguid/firstmate)-like experience inside pi, without external agents.

> **Inspired by [Firstmate](https://github.com/kunchenguid/firstmate)** — the original fleet orchestrator for pi. pi-fleet brings the same background-sidebar + isolated-worktree + captain-only wake pattern natively into pi.

**Third-party notices** · [Firstmate](https://github.com/kunchenguid/firstmate) (MIT, © 2026 Kun Chen) — inspiration and behavioral parity (delivery postures, durable inbox, memory stow, delivery gate); original code only. · [no-mistakes](https://github.com/jonathanong/no-mistakes) (MIT, © 2026 Jonathan Ong) — optional deterministic check engine when configured per project. pi-fleet is licensed under [MIT](LICENSE).

---

## How it works

```
[you] ──"analyze my-project"──► pi (main, in ~)
                                  │  automatic delegation (AGENTS.md)
                                  ▼  fleet_launch
                       pi-fleet (extension)
                                  │  spawns (detached)
                                  ▼  bin/herdr-launch.sh
                       background fleet workspace (sidebar agents only) + child pi + treehouse worktree
                                  │  waits on markers in ~/.pi/fleet/<id>.json
                                  │  done → summary in state
                                  ▼
                       watcher (captain only) → report in chat:
                         · any terminal state → silent fleet_notice (display:false + deliverAs followUp
                           + triggerTurn:true) — the main synthesizes; never interrupts an active turn
                         · failed / needs_input → the captain is explicitly needed
                         · group barrier → per-task done/failed buffered, one digest at group completion;
                           needs_input breaks the barrier (immediate wake)
```

- **Not child processes**: each sub-agent is an **independent pi session** in a herdr pane. Coordination is via **shared state files in `~/.pi/fleet/`**.
- Child model = **active model of the main at launch time** (`ctx.model`), unless you pass an explicit `model`.
- Worktree **always** by default; never auto-merges; PRs only on explicit confirmation or opt-in gate config (`gate.yaml` with `autoPr: true` — see *Configuration — delivery gate*)

---

## Requirements

| Component | Version | Notes |
|---|---|---|
| [pi](https://github.com/earendil-works/pi) | ≥ 0.84 | the main agent |
| [herdr](https://github.com/ogulcancelik/herdr) | ≥ 0.8 | `default` session running; socket `~/.config/herdr/herdr.sock` |
| [treehouse](https://github.com/markevans/treehouse) | ≥ 2.3 | pool configured for the repos you work on (see below) |
| `jq` | — | `brew install jq` |
| `bash` + `python3` | — | present on macOS |


Tested on **macOS** (launcher assumes no `setsid`, POSIX `sed`, `treehouse` — macOS/POSIX).

### Prepare the treehouse pool (once per repo)

```bash
cd <repo-path> && treehouse config --root ~/.treehouse && treehouse add --target .
# verify: treehouse status → shows available worktrees
# Example: export FLEET_PROJECTS_DIR=~/projects to enable short-name lookup
#          then project: "my-app" resolves to ~/projects/my-app
```

---

## Installation

### 1. Clone

```bash
git clone https://github.com/alessandrofogli/pi-fleet.git
cd pi-fleet
```

Or via SSH if the repo is private:
```bash
git clone git@github.com:alessandrofogli/pi-fleet.git
```

### 2. Quick install (recommended)

```bash
./bin/setup-fleet.sh
```

The script checks prerequisites, runs `pi install .`, writes `~/.pi/AGENTS.md` (backing up an existing one to `.bak`), configures treehouse for all repos in `FLEET_PROJECTS_DIR`, sets the 6h subagent timeout, and prints next steps.

### 3. Manual install

```bash
pi install .                 # from inside the package directory
```

`pi install .` registers the local package in `~/.pi/agent/settings.json` automatically — no manual path editing needed. If you clone elsewhere, just run `pi install .` again from the new location.

### 4. Global instructions (automatic delegation)

Copy the delegation policy template:

```bash
cp templates/AGENTS.global.md ~/.pi/AGENTS.md
```

(If you already have `~/.pi/AGENTS.md`, merge it or keep the backup: the setup script saves `AGENTS.md.bak` automatically.)

Subagent config (6h timeout + wait tool): see `templates/subagents.config.json` → `~/.pi/agent/extensions/subagent/config.json`.

### 5. Restart pi

The extension loads only at startup. Then try:

```
look at my-project and give me a README summary
```

The task starts in the dedicated **fleet workspace** (sidebar agents only, never focused into your view); when it finishes the report lands in the chat.

---

## Configuration — projects

`fleet_launch` requires a `project`. You can pass:

* an **absolute path**: `/home/user/projects/my-app` or `~/projects/my-app`
* a **short name** if you set `FLEET_PROJECTS_DIR`:

```bash
export FLEET_PROJECTS_DIR=~/projects   # e.g. in ~/.zshrc or ~/.bashrc
# now: project: "my-app" → ~/projects/my-app
#      project: "my-app" with FLEET_PROJECTS_DIR=~/code → ~/code/my-app
```

Without `FLEET_PROJECTS_DIR`, short names are rejected with a helpful error — use an absolute path instead. This keeps the plugin generic and not tied to any directory layout.

> Example layout (pick your own):
> ```
> ~/projects/
>   my-app/
>   another-service/
> ```

Set `FLEET_PROJECTS_DIR` to the parent of your repos, or just always use absolute paths.

---

## Configuration — delivery posture (per project)

Each project declares a **delivery posture** that tells the child agent **how to hand over** the finished work (commit/push/PR policy). The posture is resolved at launch time — `deliveryPosture` param of `fleet_launch` **wins over** the per-project config in `~/.pi/fleet/postures.json`, which wins over the built-in default. It is passed to the child as `DELIVERY_POSTURE` in its prompt; it **instructs the child** — the launcher never merges automatically (merge authority is always the captain).

| Posture | Meaning |
|---|---|
| `no-mistakes` | Commit only with tests/CI green; never push; deliver only on explicit captain request. **Default.** |
| `direct-PR` | At the end, if the brief authorizes it, prepare and **open** the PR (`gh pr create`) from the branch `fleet/<id>`; never merge. |
| `local-only` | Commit locally; no push, no PR; the captain decides later. |
| `yolo` | Like `local-only`, but authorizes pushing the branch and merge+PR **only if the brief explicitly asks for it**; never autonomously without a brief. |

Manage it with `fleet_posture` (or let `fleet_launch` resolve it per task):

```
fleet_posture get project=<path>              # current posture (+ explicit default if unset)
fleet_posture set project=<path> posture=yolo # persists to ~/.pi/fleet/postures.json (atomic write)
```

In `postures.json` the map is `{ "<projectPath>": "no-mistakes"|"direct-PR"|"local-only"|"yolo" }`. If a posture is missing or invalid, the fallback is always `no-mistakes`.

---

## Configuration — delivery gate (optional)

On projects with `no-mistakes` posture, the task can pass through a **deterministic mechanical gate** before delivery: task implements → gate (`bin/gate-run.sh`, only process exit codes, no AI in the gate) → if red **child self-fix loop** (fix ONLY what the report flags, max `loop.maxRounds`) → **final anti-fraud verification in the launcher** → **automatic PR ONLY if configured**. The merge is NEVER automatic (authority = captain).

### `gate.yaml` contract (tracked at the root of the gated repo)

```yaml
posture: no-mistakes        # aligned with postures.json (default no-mistakes)
autoPr: true                # automatic PR on green gate — default false
loop:
  maxRounds: 5              # child self-fix round cap (default 5)
checks:
  - { name: typecheck, cmd: npx tsc --noEmit,            kind: hard }
  - { name: test,      cmd: npm test,                    kind: hard }
  - { name: impact,    cmd: no-mistakes impacted-checks, kind: hard }   # optional (no-mistakes engine)
  - { name: resolve,   cmd: no-mistakes resolve-check,   kind: advisory }
```

- `kind: hard` → required exit 0 for green; `advisory` → goes in the report, does not block.
- **Missing config** (or posture ≠ no-mistakes) → current behavior unchanged: no gate. If the gate is active but `gate.yaml` is missing in the fallback: default checks `typecheck` (if tsconfig), `test` (if test script), `git diff --check`, clean `git status` (all hard) — NEVER blocking on missing config (`autoPr` false).

### How it works (flow)

1. The extension (`fleet_launch`) detects `posture == no-mistakes` **AND** `gate.yaml` in the project → passes `--gate [--auto-pr true|false]` to the launcher.
2. The child receives the **GATE** section in the prompt: after the implementation it runs `bash <pi-fleet>/bin/gate-run.sh --report gate/report.json`; red → fixes only what the report flags and re-runs (max `maxRounds`); **NEVER done-marker with a red gate**; on green it puts `gate:{passed,rounds,reportPath}` in the done-marker.
3. The launcher, after the done-marker and BEFORE finalizing, **re-runs the gate itself** on the worktree at the final state (anti-fraud: the child cannot cheat):
   - red/error → task `failed` with the report, tab closed, **no PR**;
   - green + `autoPr:true` → `gh-axi pr create --head <branch> --base main --title "<title>" --body-file <report>` (light retries 2×3s on busy; gh-axi absent → fallback `npx -y gh-axi`); `prUrl` + `gate` merged into the state;
   - green + `autoPr:false` → `done` without PR.
4. `fleet_status` shows the `(gate:✓/✗)` and `(pr:#N)` suffixes when present.

`gh-axi` (0.1.34+) is installed globally (see `bin/setup-fleet.sh`, which ensures it). A **GitHub remote** is required on the repo: without a remote the PR cannot be created (the real PR case is outside the automatic smoke — see *Testing*).

---

## Usage

### Automatic delegation (just ask)

With `~/.pi/AGENTS.md` installed, pi **calls `fleet_launch` on its own** for any work on a project, without you typing `fleet_launch`:

```
do a deep check of the LLM models in my-app? and in parallel check the database setup
```

- Parallel tasks → up to 5 per turn, in separate fleet tabs (sidebar only), different worktrees
- Main **closes the turn immediately** after launching (no polling)
- Reports land on their own in the chat; `failed`/`needs_input` actually wake you

### Manual commands (extension tools)

13 `fleet_*` tools in total: 12 registered in `extensions/index.ts` (`fleet_launch`, `fleet_status`, `fleet_outcomes`, `fleet_peek`, `fleet_steer`, `fleet_posture`, `fleet_abort`, `fleet_attach`, `fleet_bootstrap`, `fleet_learn`, `fleet_captain_pref`, `fleet_stow`) plus `fleet_watch_arm_pi` in `extensions/fleet-watch-arm.ts`.

| Tool | What it does |
|---|---|
| `fleet_launch` | Launch a task (title, brief, `project` **required** — absolute path or short name if `FLEET_PROJECTS_DIR` is set; `model` optional; `timeoutMin` optional; `kind` optional: `ship` (default) or `scout` investigation-only) |
| `fleet_status` | List tasks, states, projects, summaries |
| `fleet_peek <id>` | Last output of the task's pane (only for **live** tasks) |
| `fleet_steer <id> <msg> [replay:false]` | Write into the child's prompt (answer a `needs_input`, course corrections). **Durable by default**: the message is persisted to the task inbox, delivered, and re-rung until acked (see *Durable steer & task inbox* below). `replay:false` = old fire-and-forget behavior |
| `fleet_abort <id>` | Close pane/tab, release worktree, mark `aborted` |
| `fleet_attach <id>` | Focus the herdr pane of the task |
| `fleet_posture` | Get/set the delivery posture of a project (`get`/`set` + `project`; `posture` only for `set`) |
| `fleet_outcomes` | Query/audit the `branch-outcomes.jsonl` registry (`limit`/`project`/`verdict`/`raw`) |
| `fleet_bootstrap` | Verify tools, clean stale state, print a fleet digest (optional `verbose`) |
| `fleet_learn` | Record an operational learning in `learnings.md` (`title`, `fact`, `implication?`) |
| `fleet_captain_pref` | Get/set a captain preference (`action`, `key`, `value?` per set, `shared?`) |
| `fleet_stow` | Memory pruning pass (`dryRun?`, `verbose?`); stale entries refreshed or archived, dedup, optional budget — see *Memories: pruning* |
| `fleet_watch_arm_pi` | Start the first watcher cycle or repair a cycle reported missing/failed/unhealthy (re-arming is otherwise automatic) |

#### Scout tasks (investigation-only)

With `kind: "scout"` the child produces **only** a `report.md` at the root of the cwd: **no commit, no push, no PR**. In the done-marker it adds `reportPath` (e.g. `"reportPath":"report.md"`), which the launcher also merges into the task state (`~/.pi/fleet/<id>.json`). Default `ship` = current behavior (commit on a dedicated branch + done-marker).

```
fleet_launch(
  title: "Scout: check the DB setup",
  brief: "Analyze my-app's config and report the found problems.",
  project: "my-app",
  kind: "scout"
)
```


### Persistent captain preferences and learnings

Captain preferences and operational facts live in `~/.pi/fleet/` (runtime-global, **never in git**) and
are available at every captain `session_start` (the startup log reports `captain prefs: <n> keys, <m> learnings`).

| Tool | What it does |
|---|---|
| `fleet_captain_pref` | `action: "get" \| "set"`, `key`, `value` (set only), `shared` (default `false` → `captain.md`; `true` → `captain-shared.md`). Get → value or `null`; set → confirmation with the written line. |
| `fleet_learn` | `title`, `fact`, `implication?`, `opts?` (`tier`: `"aging"` \| `"perishable"` \| `"pinned"`, default `aging`; `expiry` required for `perishable`, e.g. "after the v0.4 deploy"). Appends a dated section to `learnings.md`; dedup by title in the last 24h (replaces the section instead of duplicating). |
| `fleet_stow` | `dryRun?`, `verbose?` — memory pruning pass: stale → refresh or archive; dedup; budget. `dryRun: true` → report only, zero writes. |

**File format** (`key: value` lines, `#` comments, free `##` sections):

- `captain.md` — preferences local to this machine, e.g.:
  ```
  # Captain preferences
  default_timeout_min: 360
  prefer_report_markdown: true
  ```
- `captain-shared.md` — same, but shareable (for the future secondmate).
- `learnings.md` — dated entries:
  ```
  ## 2026-08-29 — short title
  Fact: ... (evidence-backed: from which task/observation).
  Implication: ...
  ```

The three files are created with headers if absent (`ensureFiles` at `session_start`); the updates
are curated (no infinite appends) and written atomically (tmp+rename).

### Memories: pruning

Memories never grow unbounded: a **pass** (`fleet_stow`, or automatic at the captain's `session_start`,
max 1 pass/day via `~/.pi/fleet/.stow-last-pass`) applies the **tiers** with a decay horizon and
re-validates → **refresh** or **archive** in `~/.pi/fleet/memory-archive.md`.

**Tiers** (embedded marker at the end of the entry, invisible in rendering):

| Tier | Marker | Decay | Default for |
|---|---|---|---|
| `pinned` | none (`<!--pin-->` in learnings) | never ages, exempt from decay and budget | `captain.md` / `captain-shared.md` |
| `aging` | `<!--a:YYYY-MM-DD-->` | stale at ≥30 days → refresh (date=today) if confirmed, otherwise archive | `learnings.md` |
| `perishable` | `<!--p:YYYY-MM-DD-->` | stale at ≥7 days; the prose MUST name an expiry condition (`Expiry:` line), otherwise treated as `aging` | — |

**Pass behavior** (`fleet_stow`, `dryRun: true` → report only):

- unique stale → **refreshed** (marker date renewed) or **archived** in `memory-archive.md` (section `## YYYY-MM-DD — <entry>` + `Provenance: stowed`) — **NEVER delete of a unique fact**;
- duplicates / already-owned facts → removed (captains: duplicate keys; learnings: duplicate titles);
- **one-time migration**: legacy entry without marker → confirmed = stamps today's marker (30 days of grace); `<!--g-->` entry not re-validated at the next pass → archive with `Provenance: legacy-unvalidated` (confirmation happens by re-adding the learning: the 24h dedup regenerates the marker);
- **optional budget**: `~/.pi/fleet/startup-memory-budget` (default **7500 estimated tokens**, `ceil(byte/3)` per file, sum over the 3 files) → over the threshold archives the oldest non-pinned (never pinned) and reports the overflow. Zero-config: report + archive, no stricter enforcement.

The decay fires **only at the pass** (no background timer); the automatic pass at `session_start` is
best-effort, never blocking, with the `.stow-last-pass` guard (1 pass/day).


### Task states

`spawning → running → done | failed | aborted` (or `needs_input` with pane left open).

State on disk in `~/.pi/fleet/`: `<id>.json` (state, title, project, cwd, pane/tab, summary, changedFiles), `<id>.done.json` / `<id>.needs-input.json` (child markers), `<id>.abort`, `<id>.log`, `tasks/<id>.brief.md`, `<id>.inbox/` (durable steer messages + ack markers + `handled/`).

### Durable steer & task inbox

`fleet_steer` is no longer fire-and-forget: the message is **first persisted to disk, then delivered**.

- **On disk**: `~/.pi/fleet/<taskId>.inbox/<seq>.json` =
  `{"seq": N, "message": "...", "createdAt": ms, "acked": false, "replays": 0}` — written atomically (tmp+rename), `seq` sequential (max existing + 1, counting `handled/`).
- **Delivery**: if the task has a live pane and a non-terminal state, the message is delivered immediately via `herdr agent prompt` (as before); otherwise it stays queued and the in-process watcher delivers it when the task is active.
- **Ack**: the child is instructed (CHILD_PROMPT) to create the empty marker `<taskId>.inbox/<seq>.acked` after reading/applying a message; the watcher then moves the message to `<taskId>.inbox/handled/`.
- **Re-ring**: un-acked messages are re-delivered when ≥ `intervalMs` (default 60s) have passed since the last delivery (per-task timer in the captain's watcher, guarded against duplicates). After `maxReplays` (default 5) the captain is **woken** (`fleet_notice`, triggerTurn): *"task X did not ack message #seq after N attempts"* — the message stays on disk (field `escalated:true`) and is not re-rung again.
- **`replay:false`**: restores the old fire-and-forget behavior — the message carries `fireAndForget:true`, is delivered once, never re-rung.
- **External watcher (`fleet-watch.sh`)**: best-effort only — it mentions pending inbox messages in the triage log (heartbeat). The actual re-ring/escalation is **in-process**; the bash loop stays non-blocking.

### Branch outcomes / audit trail

**Append-only** registry `~/.pi/fleet/branch-outcomes.jsonl`: one JSON line per **terminal transition** of a task (`done`/`failed`/`aborted`) and for each `needs_input` event (relevant but not terminal). Heir of Firstmate's `fm_branch_outcomes` store.

Line format (one line = one JSON, `\n` terminated):

```json
{"ts": 1724800000000, "taskId": "...", "title": "...", "project": "...", "verdict": "done|failed|aborted|needs_input", "summary": "...", "changedFiles": ["..."], "reportPath": null, "groupId": "grp-..." }
```

- **Writing**: `extensions/fleet-outcomes.ts` (`appendOutcome`), hook in `extensions/index.ts` — watcher terminal-transition branch (3s poll), `reconcileStaleTasks` (zombie → done/failed/aborted) and `fleet_abort` (aborted via tool). Best-effort and with **in-process dedup** (key `taskId+verdict+doneAt`): the same transition is never written twice and never breaks the wake.
- **Query**: tool `fleet_outcomes` (filters `limit` default 20, `project` partial match, `verdict`, `raw` for the raw JSONL; `details.count`/`details.file`), or `queryOutcomes()` in the module.
- **Notes**: append-only — never modified retroactively; corrupted lines are ignored on read.

### Task groups (L3.5)

Launch N tasks in the same message → they automatically form a group.
You will see a single verbose digest when all have finished. `needs_input` wakes right away.
`fleet_status` shows `grp:xxx 2/3`; `fleet_status(groupId: <id>)` filters by group (full groupId or 8-char prefix).

Detail: `groupId`/`groupSize`/`groupLabel`/`groupMode` in `{id}.json`; group state persisted in `~/.pi/fleet/.wake-groups/{groupId}.json` for recovery after a Pi restart. `fleet_status` groups by `groupId` and shows `Group <id> (label) — 2/3 complete:` + `Singles:`.

**`groupFailPolicy`** (optional, default `waitAll`): controls what happens when a task of a barrier group **fails**.

- `waitAll` (default): current behavior — the failed task is buffered, the group digest is awaited when the other tasks finish.
- `immediate`: the failed task **wakes the captain right away** with the group context (how many done, how many pending) instead of waiting for the digest. The other group tasks continue and the group stays pending (the final digest still arrives when the others finish).

Use `immediate` for fail-fast: when an error makes the other group tasks useless (e.g. a build that fails and invalidates the subsequent steps). The field goes to `fleet_launch` (`groupFailPolicy`) and ends up in `{id}.json`; the CLI flag is `--group-fail-policy`.

> Note: the policy concerns ONLY `failed`. The `done`/`aborted` stay `waitAll` (buffered) even with `immediate`; `needs_input` keeps breaking the barrier and waking immediately in both cases.

### Bootstrap

At captain session start (and on demand via the `fleet_bootstrap` tool) pi-fleet runs a best-effort, **zero-config** health pass — it never blocks startup and never installs anything:

- **Tool check**: `jq`, `herdr`, `treehouse`, `git`, `gh` (+ `gh auth status` reported per tool in `details`); only missing tools are flagged.
- **Stale-state cleanup** (safe, non-destructive): orphan `<id>.done.json` markers (no matching `<id>.json`) are moved to `<id>.done.json.orphan`; `<id>.json.bad` files older than 7 days are deleted; active tasks whose herdr pane is gone are **not** touched here (that's `reconcileStaleTasks`'s job) — they are only reported.
- **Fleet digest**: counts per state, active groups (group logic reused when available, simple count otherwise), most relevant `needs_input` tasks.

The digest is logged to console at every startup; only when there are clear problems (missing tools or pending `needs_input`) a short informational message is shown with `triggerTurn:false` — the session start is never interrupted.

Implementation: `extensions/fleet-bootstrap.ts` (lazy-loaded, fail-soft — same pattern as `fleet-group.ts`).


---

## Testing

End-to-end smoke test of the base chain **launcher → pi child in the herdr pane → done-marker → state on disk**:

```bash
bash tests/smoke.sh
```

Prerequisites:
- **active herdr** with the `default` session (or set `HERDR_SESSION` for another session) — if the daemon does not respond the script exits with code `2` (documented skip, never a false green);
- `jq` in PATH (`brew install jq`);
- `pi` reachable as a herdr agent (the child runs in a real pane).

What it does: creates a scratch repo in `/tmp/fleet-smoke-*` (git init + initial commit), isolates the state in `/tmp/fleet-smoke-state-*` via `FLEET_STATE_HOME` (the real fleet in `~/.pi/fleet` **is not touched**), launches `bin/herdr-launch.sh` with `--no-worktree` on a minimal child task and verifies: state json with `state == "done"` and non-empty `summary`, `esito.txt` containing `SMOKE_OK` in the scratch repo, done-marker consumed by the launcher.

Exit codes: `0` green · `1` failed · `2` missing prerequisites.

In the same run, the smoke also covers **two gate scenarios** on dedicated scratch repos (`/tmp/fleet-gate-{a,b}-*`, `gate.yaml` with `autoPr:false`, no remote):

| Case | Setup | Expected outcome |
|---|---|---|
| **A** | broken `gate-test.sh` (exit 1), brief forbidding the fix | task `failed`, `gate.passed=false`, `gate/report.json` with `overall: red`, **no PR** |
| **B** | green `gate-test.sh` (exit 0) | task `done`, `gate.passed=true`, report `overall: green`, **no PR** (`autoPr` false) |

**Real automatic PR** (real GitHub remote + `gh-axi pr create`): outside the automatic smoke — manual procedure/separate run: create a repo with a remote, `gate.yaml` with `autoPr: true`, launch a no-mistakes task and check in `fleet_status` the `(pr:#N)` suffix and the state with `prUrl`; the merge stays manual (authority = captain).

Optional environment:

| Variable | Effect |
|---|---|
| `PI_FLEET_SMOKE_MODEL` | child model override, full id `provider/id` (default: launcher env chain, e.g. `PI_PROVIDER`/`PI_MODEL`) |
| `SMOKE_TIMEOUT_S` | external launcher timeout in seconds (default `480`) |
| `SMOKE_KEEP=1` | do not remove scratch/state at the end of the run (debug) |
| `HERDR_SESSION` | herdr session to use (default `default`) |

---

## Architecture

### M1 — `bin/herdr-launch.sh` (launcher)

- Resolves/creates the dedicated **fleet workspace** (`workspace list` → label "fleet" + cwd match, else `workspace create --label fleet --cwd <project> --no-focus`; race-safe for parallel launches), takes a **worktree** with `treehouse get --lease --no-fetch`
- Creates the child **tab in the fleet workspace** (`tab create --workspace <fleet> --cwd <worktree> --label <task-id> --no-focus`) → visible **only in the herdr agents sidebar** (never in the captain's tab or tab bar), starts the **child pi** (`agent start <unique-name> --kind pi --model <provider/model>` — agent name 1–32 chars, unique per task; always full `provider/id`, never a bare id)
- Delivers the **brief** (rules: cwd, detached HEAD → create a branch `fleet/<id>-<slug>` before committing, done-marker JSON, full markdown summary)
- Waits on markers with: **retry** on `agent_pane_busy` (4×3s), **liveness-check** every 15s (child dead without marker → `failed` in ~30s), configurable timeout, abort via marker
- On finish writes state+summary, closes the pane/tab (dedicated to the task), **releases worktree** (order matters: `treehouse return` kills pane processes)

### M2 — `extensions/index.ts` (pi extension)

- 13 `fleet_*` tools (see *Usage → Manual commands* for the full list); `fleet_launch` spawns the launcher **detached** via `spawn("bash", [...], { detached: true })` + `unref` (survives chat abort; `python` is not involved — it only appears as a prerequisite check in `bin/setup-fleet.sh`)
- **Bootstrap**: at `session_start` (captain only) checks tools, cleans stale state, prints a fleet digest — `extensions/fleet-bootstrap.ts`, lazy-loaded and fail-soft
- **Watcher** (3s poll) on state transitions:
  - every terminal transition (`done`, `failed`, `needs_input`) → `fleet_notice` with `display: false` + `deliverAs: followUp` **and** `triggerTurn: true` — the raw message is hidden and the main agent synthesizes the report for you; delivery never interrupts an active turn
  - group barrier (L3.5): per-task `done`/`failed` are **buffered** (no per-task wake); a single group digest (`sendGroupDigest`) is delivered when the group completes; `needs_input` breaks the barrier and wakes immediately
- **Seeding** at startup: already-present tasks don't produce phantom wakes
- **Reconcile** at startup: active tasks without a live herdr pane → `done`/`failed`/`aborted` (with marker checks)
- **Captain gate**: extension also loads in child sessions (same settings), but watcher/reconcile/provider are active **only** where `cwd = $HOME` (or `PI_FLEET_CAPTAIN=1`) — otherwise each child would wake itself with others' `fleet_notice`
- **Active model**: `fleet_launch` composes `--model <provider/id>` from the current main model (`ctx.model.provider`/`ctx.model.id`, fallback `PI_PROVIDER`/`PI_DEFAULT_MODEL`) — never the bare id, which `pi models` resolves only when unique and collides across providers
- **Background-work** registry: built-in fallback (no external dependency); tasks appear in `fleet_status` only
- **Inbox re-ring**: `fleet_steer` persists messages to `~/.pi/fleet/<id>.inbox/` (durable, ack marker `<seq>.acked`, moved to `handled/`); un-acked messages are re-delivered every 60s (max 5 → escalation wake of the captain via `sendAttention`, helper separate from `sendWake`). `replay:false` keeps the old fire-and-forget behavior. `fleet_status` shows `(inbox: N)` for pending messages

### L3 — Watcher esterno zero-token (`bin/fleet-watch*.sh` + `extensions/fleet-watch-arm.ts`)

Wake **even when Pi is closed**. Zero-token: the model runs only on actionable events.

- **When you need it**: you close Pi (or Pi crashes) while tasks are running; without L3 the wake is lost.
- **How to enable**: automatic — `extensions/fleet-watch-arm.ts` arms at `session_start` (and drains the queue). Manual: `fleet_watch_arm_pi` / `bash bin/fleet-watch-arm.sh --restart`.
- **Durable queue**: `~/.pi/fleet/.wake-queue/*.json` survives Pi restarts; at the next open the arm layer drains it via `bin/fleet-wake-drain.sh` (default: lists pending records; `--count` prints only the pending count; `--ack-through <SEQ>` acknowledges records after delivery in chat).
- **Singleton lock**: `~/.pi/fleet/.watch.lock` + beacon `~/.pi/fleet/.last-watcher-beat` (`bin/fleet-lock-lib.sh`, `FLEET_STATE_HOME` shared with the extension).
- **What it does**: `fleet-watch.sh` polls (3s) and absorbs benign (`running` with fresh beat); on `done`/`failed`/`needs_input`/new queue file it writes the queue and exits with the reason — the arm layer re-arms before waking.
- **Fallback**: if L3 scripts are absent, L2 still works (extension catches and degrades).

See `docs/ARCHITECTURE.md` for the full L3 flow, state layout, and differences from firstmate.

---

## Troubleshooting

| Symptom | Cause / Fix |
|---|---|
| `agent start` with `invalid_agent_name` | agent name > 32 chars or not lowercase → launcher now generates `f-<slug max23>-<4digits>`, always valid |
| Two parallel tasks, second won't start (`agent_name_taken`) | old duplicate `pi` names → fixed with unique names per task |
| `agent_pane_busy` | transient race right after tab create → launcher retries 4×3s |
| Task stuck `spawning`, pane never created | premature launcher exit without state mark → every exit now calls `fail_task` (state `failed` with reason) |
| Phantom wake at startup | already-finished tasks from previous sessions → seeding + reconcile |
| `fleet_notice` inside a still-running subagent | extension also active in children → captain gate (`cwd=HOME`) |
| Child has different model than main | static `PI_*` at startup → now `ctx.model` composed as `provider/id` (never bare id) |
| Child dead and launcher waits 6h | liveness-check every 15s → `failed` in ~30s |
| Report "wall of text" | it's the **child's** summary (main doesn't rewrite); child prompt now requires structured markdown |
| Main polling after launch | `AGENTS.md`/tool guidelines: close the turn after `fleet_launch` |

---

## Portability / moving to another machine

Single package: extension + bash launcher + templates in one folder. On a new laptop:

```bash
git clone <repo>
cd pi-fleet && ./bin/setup-fleet.sh   # does the install
# then: start herdr, configure treehouse pools, restart pi
```

No machine-specific dependencies: state lives in `~/.pi/fleet/`, projects are resolved via absolute paths or `FLEET_PROJECTS_DIR`, herdr workspace is discovered via CLI.

---

## Security notes

- The repo does not and must not contain credentials; API keys live in `~/.pi/agent/auth.json` (outside the repo).
- Tasks run in isolated worktrees; the child never modifies the shared working tree.
- Never auto-merges: changed files are reported as a list; PR only on explicit confirmation or opt-in gate config (`gate.yaml` `autoPr: true`, opened by the launcher after a green gate).
