# pi-fleet

Visible sub-agents for [pi](https://github.com/earendil-works/pi) (`@earendil-works/pi-coding-agent`): delegate a task and a child `pi` starts in a **dedicated herdr "fleet" workspace** (background tab, `--no-focus`), working in an **isolated treehouse worktree**. The child never steals focus and never occupies space in your tab: it appears **only in the herdr agents sidebar (left)**, whose state rolls up per workspace. The main chat stays free, and the result lands back in the chat — waking you only when the captain is actually needed (failure or input required).

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
                         · done          → followUp WITHOUT interruption (Firstmate parity)
                         · failed/needs_input → wake (triggerTurn) — captain needed
```

- **Not child processes**: each sub-agent is an **independent pi session** in a herdr pane. Coordination is via **shared state files in `~/.pi/fleet/`**.
- Child model = **active model of the main at launch time** (`ctx.model`), unless you pass an explicit `model`.
- Worktree **always** by default; never auto-merges; PRs only on explicit confirmation.

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

Each project declares a **delivery posture** that tells the child agent **how to hand over** the finished work (commit/push/PR policy). The posture is resolved at launch time — `deliveryPosture` param of `fleet_launch` **wins over** the per-project config in `~/.pi/fleet/postures.json`, which wins over the built-in default. It is passed to the child as `DELIVERY_POSTURE` in its prompt; it **instructs the child**, it never enables automatic merges/teardowns in the launcher.

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

| Tool | What it does |
|---|---|
| `fleet_launch` | Launch a task (title, brief, `project` **required** — absolute path or short name if `FLEET_PROJECTS_DIR` is set; `model` optional; `timeoutMin` optional; `kind` optional: `ship` (default) o `scout` solo-indagine) |
| `fleet_status` | List tasks, states, projects, summaries |
| `fleet_peek <id>` | Last output of the task's pane (only for **live** tasks) |
| `fleet_steer <id> <msg> [replay:false]` | Write into the child's prompt (answer a `needs_input`, course corrections). **Durable by default**: the message is persisted to the task inbox, delivered, and re-rung until acked (see *Durable steer & task inbox* below). `replay:false` = old fire-and-forget behavior |
| `fleet_abort <id>` | Close pane/tab, release worktree, mark `aborted` |
| `fleet_attach <id>` | Focus the herdr pane of the task |
| `fleet_posture` | Get/set the delivery posture of a project (`get`/`set` + `project`; `posture` only for `set`) |
| `fleet_outcomes` | Query/audit del registro `branch-outcomes.jsonl` (`limit`/`project`/`verdict`/`raw`) |
| `fleet_bootstrap` | Verify tools, clean stale state, print a fleet digest (optional `verbose`) |
| `fleet_learn` | Record an operational learning in `learnings.md` (`title`, `fact`, `implication?`) |
| `fleet_captain_pref` | Get/set a captain preference (`action`, `key`, `value?` per set, `shared?`) |
| `fleet_watch_arm_pi` | Start the first watcher cycle or repair a cycle reported missing/failed/unhealthy (re-arming is otherwise automatic) |

#### Task scout (solo-indagine)

Con `kind: "scout"` il figlio produce **solo** un `report.md` nella root del cwd: **non committa, non fa push, non apre PR**. Nel done-marker aggiunge `reportPath` (es. `"reportPath":"report.md"`), che il launcher mergia anche nello stato del task (`~/.pi/fleet/<id>.json`). Default `ship` = comportamento attuale (commit su branch dedicato + done-marker).

```
fleet_launch(
  title: "Scout: controlla il setup DB",
  brief: "Analizza la config di my-app e riporta i problemi trovati.",
  project: "my-app",
  kind: "scout"
)
```


### Preferenze capitano e learnings persistenti

Preferenze del capitano e fatti operativi vivono in `~/.pi/fleet/` (runtime-globale, **mai in git**) e
sono disponibili a ogni `session_start` del capitano (il log di avvio riporta `captain prefs: <n> chiavi, <m> learnings`).

| Tool | Cosa fa |
|---|---|
| `fleet_captain_pref` | `action: "get" \| "set"`, `key`, `value` (solo set), `shared` (default `false` → `captain.md`; `true` → `captain-shared.md`). Get → valore o `null`; set → conferma con la riga scritta. |
| `fleet_learn` | `title`, `fact`, `implication?`. Appende una sezione datata a `learnings.md`; dedup per titolo nelle ultime 24h (sostituisce la sezione invece di duplicare). |

**Formato dei file** (righe `chiave: valore`, commenti `#`, sezioni `##` libere):

- `captain.md` — preferenze locali a questa macchina, es.:
  ```
  # Preferenze capitano
  default_timeout_min: 360
  prefer_report_markdown: true
  ```
- `captain-shared.md` — idem, ma condivisibile (per il futuro secondmate).
- `learnings.md` — entry datate:
  ```
  ## 2026-08-29 — titolo breve
  Fatto: ... (evidence-backed: da quale task/osservazione).
  Implicazione: ...
  ```

I tre file vengono creati con header se assenti (`ensureFiles` alla `session_start`); gli aggiornamenti
sono curati (niente append infinito) e scritti atomicamente (tmp+rename).


### Task states

`spawning → running → done | failed | aborted` (or `needs_input` with pane left open).

State on disk in `~/.pi/fleet/`: `<id>.json` (state, title, project, cwd, pane/tab, summary, changedFiles), `<id>.done.json` / `<id>.needs-input.json` (child markers), `<id>.abort`, `<id>.log`, `tasks/<id>.brief.md`, `<id>.inbox/` (durable steer messages + ack markers + `handled/`).

### Durable steer & task inbox

`fleet_steer` is no longer fire-and-forget: the message is **first persisted to disk, then delivered**.

- **On disk**: `~/.pi/fleet/<taskId>.inbox/<seq>.json` =
  `{"seq": N, "message": "...", "createdAt": ms, "acked": false, "replays": 0}` — written atomically (tmp+rename), `seq` sequential (max existing + 1, counting `handled/`).
- **Delivery**: if the task has a live pane and a non-terminal state, the message is delivered immediately via `herdr agent prompt` (as before); otherwise it stays queued and the in-process watcher delivers it when the task is active.
- **Ack**: the child is instructed (CHILD_PROMPT) to create the empty marker `<taskId>.inbox/<seq>.acked` after reading/applying a message; the watcher then moves the message to `<taskId>.inbox/handled/`.
- **Re-ring**: un-acked messages are re-delivered when ≥ `intervalMs` (default 60s) have passed since the last delivery (per-task timer in the captain's watcher, guarded against duplicates). After `maxReplays` (default 5) the captain is **woken** (`fleet_notice`, triggerTurn): *"task X non ha ackato il messaggio #seq dopo N tentativi"* — the message stays on disk (field `escalated:true`) and is not re-rung again.
- **`replay:false`**: restores the old fire-and-forget behavior — the message carries `fireAndForget:true`, is delivered once, never re-rung.
- **External watcher (`fleet-watch.sh`)**: best-effort only — it mentions pending inbox messages in the triage log (heartbeat). The actual re-ring/escalation is **in-process**; the bash loop stays non-blocking.

### Branch outcomes / audit trail

Registro **append-only** `~/.pi/fleet/branch-outcomes.jsonl`: una riga JSON per ogni **transizione terminale** di un task (`done`/`failed`/`aborted`) e per ogni evento `needs_input` (rilevante ma non terminale). Erede dello store `fm_branch_outcomes` di Firstmate.

Formato riga (una riga = un JSON, `\n` terminato):

```json
{"ts": 1724800000000, "taskId": "...", "title": "...", "project": "...", "verdict": "done|failed|aborted|needs_input", "summary": "...", "changedFiles": ["..."], "reportPath": null, "groupId": "grp-..." }
```

- **Scrittura**: `extensions/fleet-outcomes.ts` (`appendOutcome`), hook in `extensions/index.ts` — ramo transizione terminale del watcher (3s poll), `reconcileStaleTasks` (zombie → done/failed/aborted) e `fleet_abort` (aborted via tool). Best-effort e con **dedup in-process** (chiave `taskId+verdict+doneAt`): la stessa transizione non viene mai scritta due volte e non rompe mai il wake.
- **Query**: tool `fleet_outcomes` (filtri `limit` default 20, `project` match parziale, `verdict`, `raw` per il JSONL grezzo; `details.count`/`details.file`), oppure `queryOutcomes()` nel modulo.
- **Note**: append-only — non si modifica mai retroattivamente; righe corrotte vengono ignorate in lettura.

### Gruppi di task (L3.5)

Lancia N task nello stesso messaggio → formano automaticamente un gruppo.
Vedrai un unico digest verboso quando tutti hanno finito. `needs_input` sveglia subito.
`fleet_status` mostra `grp:xxx 2/3`, `fleet_status --group <id>` filtra.

Dettaglio: `groupId`/`groupSize`/`groupLabel`/`groupMode` in `{id}.json`; stato gruppo persistito in `~/.pi/fleet/.wake-groups/{groupId}.json` per recovery dopo restart Pi. `fleet_status` raggruppa per `groupId` e mostra `Gruppo <id> (label) — 2/3 completi:` + `Singoli:`.

**`groupFailPolicy`** (opzionale, default `waitAll`): controlla cosa succede quando un task di un gruppo barrier **fallisce**.

- `waitAll` (default): comportamento attuale — il failed viene bufferizzato, si attende il digest di gruppo quando gli altri task finiscono.
- `immediate`: il task fallito **sveglia subito** il capitano con il contesto del gruppo (quanti done, quanti pending) invece di aspettare il digest. Gli altri task del gruppo continuano e il gruppo resta pending (il digest finale arriva comunque quando gli altri finiscono).

Usa `immediate` per fail-fast: quando un errore rende inutili gli altri task del gruppo (es. una build che fallisce e invalida gli step successivi). Il campo va passato a `fleet_launch` (`groupFailPolicy`) e finisce in `{id}.json`; il flag CLI è `--group-fail-policy`.

> Nota: la policy riguarda SOLO i `failed`. I `done`/`aborted` restano `waitAll` (bufferizzati) anche con `immediate`; `needs_input` continua a rompere il barrier e svegliare subito in entrambi i casi.

### Bootstrap

At captain session start (and on demand via the `fleet_bootstrap` tool) pi-fleet runs a best-effort, **zero-config** health pass — it never blocks startup and never installs anything:

- **Tool check**: `jq`, `herdr`, `treehouse`, `git`, `gh` (+ `gh auth status` reported per tool in `details`); only missing tools are flagged.
- **Stale-state cleanup** (safe, non-destructive): orphan `<id>.done.json` markers (no matching `<id>.json`) are moved to `<id>.done.json.orphan`; `<id>.json.bad` files older than 7 days are deleted; active tasks whose herdr pane is gone are **not** touched here (that's `reconcileStaleTasks`'s job) — they are only reported.
- **Fleet digest**: counts per state, active groups (group logic reused when available, simple count otherwise), most relevant `needs_input` tasks.

The digest is logged to console at every startup; only when there are clear problems (missing tools or pending `needs_input`) a short informational message is shown with `triggerTurn:false` — the session start is never interrupted.

Implementation: `extensions/fleet-bootstrap.ts` (lazy-loaded, fail-soft — same pattern as `fleet-group.ts`).


---

## Testing

Smoke test end-to-end della catena base **launcher → pi figlio nel pane herdr → done-marker → stato su disco**:

```bash
bash tests/smoke.sh
```

Prerequisiti:
- **herdr attivo** con la sessione `default` (o imposta `HERDR_SESSION` per un'altra sessione) — se il daemon non risponde lo script esce con codice `2` (skipped documentato, mai falso verde);
- `jq` in PATH (`brew install jq`);
- `pi` raggiungibile come agente herdr (il figlio gira in un pane reale).

Cosa fa: crea un repo scratch in `/tmp/fleet-smoke-*` (git init + commit iniziale), isola lo stato in `/tmp/fleet-smoke-state-*` via `FLEET_STATE_HOME` (la flotta reale in `~/.pi/fleet` **non viene toccata**), lancia `bin/herdr-launch.sh` con `--no-worktree` su un task figlio minimo e verifica: state json con `state == "done"` e `summary` non vuota, `esito.txt` contenente `SMOKE_OK` nel repo scratch, done-marker consumato dal launcher.

Exit codes: `0` verde · `1` fallito · `2` prerequisiti mancanti.

Environment opzionali:

| Variabile | Effetto |
|---|---|
| `PI_FLEET_SMOKE_MODEL` | override del modello del figlio, full id `provider/id` (default: catena env del launcher, es. `PI_PROVIDER`/`PI_MODEL`) |
| `SMOKE_TIMEOUT_S` | timeout esterno del launcher in secondi (default `480`) |
| `SMOKE_KEEP=1` | non rimuovere scratch/state a fine run (debug) |
| `HERDR_SESSION` | sessione herdr da usare (default `default`) |

---

## Architecture

### M1 — `bin/herdr-launch.sh` (launcher)

- Resolves/creates the dedicated **fleet workspace** (`workspace list` → label "fleet" + cwd match, else `workspace create --label fleet --cwd <project> --no-focus`; race-safe for parallel launches), takes a **worktree** with `treehouse get --lease --no-fetch`
- Creates the child **tab in the fleet workspace** (`tab create --workspace <fleet> --cwd <worktree> --label <task-id> --no-focus`) → visible **only in the herdr agents sidebar** (never in the captain's tab or tab bar), starts the **child pi** (`agent start <unique-name> --kind pi --model <provider/model>` — agent name 1–32 chars, unique per task; always full `provider/id`, never a bare id)
- Delivers the **brief** (rules: cwd, detached HEAD → create a branch `fleet/<id>-<slug>` before committing, done-marker JSON, full markdown summary)
- Waits on markers with: **retry** on `agent_pane_busy` (4×3s), **liveness-check** every 15s (child dead without marker → `failed` in ~30s), configurable timeout, abort via marker
- On finish writes state+summary, closes the pane/tab (dedicated to the task), **releases worktree** (order matters: `treehouse return` kills pane processes)

### M2 — `extensions/index.ts` (pi extension)

- 12 `fleet_*` tools; `fleet_launch` spawns the launcher **detached** (double-fork python, survives chat abort)
- **Bootstrap**: at `session_start` (captain only) checks tools, cleans stale state, prints a fleet digest — `extensions/fleet-bootstrap.ts`, lazy-loaded and fail-soft
- **Watcher** (3s poll) on state transitions:
  - `done` → chat note `deliverAs: followUp` **without** `triggerTurn` (Firstmate parity: visible, never interrupts)
  - `failed` / `needs_input` → `triggerTurn: true` (wakes you)
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
- **Durable queue**: `~/.pi/fleet/.wake-queue/*.json` survives Pi restarts; drained at next open via `fleet_wake_drain_pi` / `bash bin/fleet-wake-drain.sh --count` and acknowledged with `--ack`.
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
- Never auto-merges: changed files are reported as a list, PR only on explicit confirmation.
