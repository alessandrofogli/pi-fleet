---
name: fleet-brief
description: 'fleet_launch brief template that delegates self-recon to the sub-agent. The captain writes ONLY objective + constraints + delivery and launches immediately, without preparing context (git recon, doc reading, claim inventory): the child does self-alignment, self-context, self-verification and self-delivery on its own. Use for EVERY fleet_launch.'
license: MIT
metadata:
  tags: "fleet, brief, delegation, template, pi-fleet"
  category: "workflow"
---

# fleet-brief — immediate launch with delegated self-recon

## Why it exists

Before launching a task the captain tends to do work the child can do on its own: git recon of the repo, reading documentation/reference, inventory of claims to verify, pre-push checks. This delays the launch and, worse, the context prepared by the captain can be **stale or wrong** (e.g. reference to past tasks ≠ current state). The rule: **the captain never prepares context on the child's behalf**.

## How to write a brief (4 phases, all delegated)

The brief instructs THE CHILD to run the 4 phases; the captain only writes:

1. **Objective** — what must be true at the end (1-3 lines).
2. **Constraints** — what NOT to touch, base/HEAD, scope, network/credentials.
3. **Delivery** — where the result goes (report in chat, commit+push, marker), with explicit authorization if push/merge is needed.
4. **Known suspects** (optional) — 2-3 doubtful claims to verify, NEVER a full inventory.

### Phase 1 — Self-alignment (inside the brief)
```bash
git fetch origin
git checkout -b fleet/<taskid>-<slug> origin/main
git rev-parse HEAD   # == origin/main
git status -sb       # flags if something is dirty outside the worktree
```
The child reports: unmerged pending branches, base different from origin/main, dirty files in the main checkout. Does NOT resolve on its own: reports.

### Phase 2 — Self-context (inside the brief)
"Build the context yourself: read README/docs/past reports yourself and compare them with the code. If a description I gave you does not match the code, flag it and start from the truth (evidence `file:line`)." Never copy summaries taken from stale context into the brief.

### Phase 3 — Self-verification (inside the brief)
For every claim of the result: grep/execution command that proves it (e.g. `grep -n triggerTurn extensions/index.ts`, `grep -c registerTool extensions/index.ts`, `npx tsc --noEmit`). The report cites `file:line` or "NOT FOUND".

### Phase 4 — Self-delivery (inside the brief, if with merge/push)
Before pushing: clean status, list of what is about to be pushed, no foreign files (e.g. `.treehouse/`, `node_modules/`), no `--force`. In case of rejected push or conflicts: STOP, do not force, report.

## Real example (happened today, pi-fleet README cleanup)

Before the pattern: 2 bash git recon + reference analysis before writing the brief (4-5 pre-launch tool calls).
With the pattern: the brief contained the 4 phases + objective/constraints/delivery; the child did base alignment on its own, README-vs-code reading, claim verification (12 tools, triggerTurn, double-fork) and delivery with merge+push. The captain: 1 fleet_launch, zero pre-work.

## Minimal brief checklist

- [ ] Objective in 1-3 lines (what must be TRUE at the end)
- [ ] Explicit base/HEAD: "align to origin/main, verify HEAD"
- [ ] Constraints: what NOT to touch, limited scope
- [ ] Delivery + explicit push/merge authorization IF needed (never implicit)
- [ ] "Self-context: read the files yourself, if my description doesn't match start from the truth"
- [ ] Max 1-2 known suspects, never full inventories

## Child runtime conventions (T-019 — the harness enforces these)

The pane-health watchdog (`bin/fleet-watch.sh`, external watcher) treats the
child as frozen when its context stops growing, and the machine does not wait
forever on a single command. The brief MUST therefore tell the child (the
launcher injects the same rules in the child prompt, but the brief repeats them
so the contract is explicit):

1. **Long commands always carry an explicit `timeout`.** A single bash command
   may not run unbounded: the per-task tolerance is `bashTimeoutS` (default
   300s, launcher `--bash-timeout-s`, range 120..300). Wrap commands that may
   exceed ~10s in `timeout <seconds> bash -c '...'` (or `timeout <N> <cmd>` for
   a single command). If a command legitimately needs more time, state the
   configured tolerance in the brief — and if the watchdog steer fires, ACK it
   (create the `<seq>.acked` file it names) to reset the timer.
2. **Never leave untracked files behind.** Commit work as you go (ONE COMMIT
   PER FILE) and commit (or stash) everything untracked before finishing or
   stopping: a kill+relaunch from the last WIP commit is only lossless when the
   WIP is already in git.
3. **Commit a WIP commit right after recon** (base for any relaunch).
4. **Recursive commands need a depth bound** (tests, searches, `jq` pipes): no
   silent infinite loops.

## Recovery semantics (what the child must expect)

- The watchdog's first intervention is a **steer** in the durable inbox:
  "abort command + commit WIP". ACK it (create the ack file it names) even if
  you were just thinking — the ack resets the kill timer.
- If there is no ack within the kill window, the pane is **killed and
  relaunched** from the last WIP commit (salvaging untracked files first): the
  task keeps its task id and its branch; a `relaunches` record appears in
  `~/.pi/fleet/<id>.json` and the relaunched child gets a RESUME NOTICE with
  the base commit. Treat that as a checkpoint, not a failure.
