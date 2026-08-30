---
name: captain-wave-controller
description: 'Manual wave orchestration pattern for the captain (the flow used to implement T-013..T-020): declare a waveplan first (tickets with deps + .scratch/waveplan.md), launch one fleet_launch per unblocked ticket sharing a barrier groupId for exactly ONE digest per wave, and on each group digest verify the reports, merge+push ONLY if authorized in the plan, update the tickets (## Stato: DONE (commit <sha>) + unblocks: T-0xx), then launch the NEXT wave before closing the turn. Complements the automated pipeline (pipeline-orchestrator, T-017) — it does NOT replace it.'
license: MIT
metadata:
  tags: "captain, waves, orchestration, groupId, barrier, digest, tickets, follow-up, waveplan, pi-fleet"
  category: "workflow"
---

# captain-wave-controller — the captain's manual wave orchestration

## Why it exists

During the T-013..T-018 flow, after the fleet_notice "group complete"
(Wave 1: T-013 + T-014), the captain summarized the results but **closed
the turn without advancing** — the merge+push, the ticket updates and
the Wave 2 launch all had to be requested explicitly by the user.

Root cause: in the manual wave flow, the contract "when a group digest
arrives AND a wave plan was already declared, execute the pre-declared
next steps automatically" was not formalized. No persistent rule forced
the captain to keep going while an explicit plan existed (ticket state +
dependency graph).

This skill is **fix 2** of the follow-up handoff
(`.scratch/handoffs/2026-08-29-wave-orchestration-followup.md`): it
centralizes the manual pattern so the captain always advances after a
digest. It complements the automated pipeline (T-017) — it does **not**
replace it.

## Relationship to the automated pipeline

- **This skill (manual)**: the captain runs the waves directly — one
  `fleet_launch` per ticket, waves computed by hand from the ticket
  deps, merge+push by the captain. Use it when the flow is orchestrated
  by hand (the T-013..T-020 style).
- **`pipeline-orchestrator` skill (automated, T-017)**: the
  deterministic path — tickets markdown -> spec converter,
  `bin/fleet-pipeline-helper.sh waves` computes the DAG waves, shippers
  run per slice, the helper computes the integration plan. Do **NOT**
  duplicate that machinery here (converter, integrate, waves command);
  reference it.
- Common ground: both use the same wave semantics (deps written in the
  tickets, independent items -> same wave, barrier groups, ONE digest
  per wave) and the same per-file commit contract (`docs/pipeline-tickets.md`).

## Core principle

**Ticket status + waveplan = the single source of progress.** When a
group digest arrives and a wave plan was declared, the captain MUST
advance automatically: verify the reports -> merge+push (only if
authorized) -> update the tickets -> **launch the next wave** -> only
then close the turn. Before stopping, always answer: "which tickets are
DONE and what do they unblocks?" — if a wave is ready, proceed. Never
stop after a digest while the plan still has pending waves.

## Workflow

### Phase 0 — Declare the waveplan FIRST (before any launch)

1. Write one ticket per task (markdown), each with:
   - `deps:` — the tickets that must be DONE (and merged) before this
     one is unblocked;
   - `## Stato:` — status field (tracked here, see Phase 2.3).
2. Create `.scratch/waveplan.md` from the template below (waves list,
   deps, authorization flags for merge+push, ticket status tracking).
3. Fill the **authorization flags** for merge+push (global and/or
   per-ticket): never implicit, always explicit.
4. Only then launch Wave 1 (all tickets with no open deps).

### Phase 1 — Launch a wave

- Compute the wave = every unblocked ticket (all its `deps` resolved
  = DONE + merged). Wave 1 = tickets with no deps.
- **One `fleet_launch` per ticket** of the wave, all sharing **one
  explicit `groupId`** (`grp-<flow>-w<k>`), `groupMode: "barrier"`,
  `groupFailPolicy: "waitAll"` -> **exactly ONE digest** wakes the
  captain per wave.
- Per launch: `kind` per ticket type, `worktree: true`,
  `deliveryPosture: "local-only"` (the captain merges — see Phase 2.2),
  brief with objective / constraints (base `origin/main`, what NOT to
  touch) / delivery (WIP commit right after recon, ONE COMMIT PER FILE)
  / `nested: true` when the task needs the fleet tools (Phase 5).
- Never launch a dependent ticket before its blocking ticket's digest
  arrived.

### Phase 2 — On the group digest: process AND advance (never stop here)

1. **Verify each task's report**: state file `~/.pi/fleet/<id>.done.json`
   (verdict `done`, summary, `changedFiles`); check the branch +
   file set actually exist (`git diff --name-only` against
   `origin/main`). A task reported done without a state file or branch
   = contract violation -> treat as failed (Phase 3).
2. **Merge + push finished branches ONLY if authorized** in the
   waveplan flags. Per branch: confirm it exists and its file set is
   clean, merge into `main`, push, record the resulting `commit <sha>`.
   Not authorized -> leave the branch local, note it in the report.
3. **Update the tickets** of the merged tasks:
   `## Stato: DONE (commit <sha>)` plus an `unblocks: T-0xx` line on
   each ticket that depends on it.
4. **Update the waveplan** (wave status, ticket status, commit shas).
5. **Compute the next wave** from the ticket deps; if a wave is ready,
   **LAUNCH it now** (Phase 1).
6. Close the turn ONLY after the next wave is launched — or after the
   last wave, with the final synthesis (all wave results, merged
   branches + shas, remaining open questions).

### Phase 3 — Failed / aborted / frozen / needs_input

- **Frozen pane / aborted task**: relaunch from the **last WIP commit**
  — `git switch -c fleet/<taskid>-<slug> <last-wip-sha>` in a fresh
  worktree — and **salvage untracked files** (stash or copy them out)
  before the old worktree is discarded. This is why briefs demand
  "commit WIP right after recon".
- **`needs_input`**: breaks the barrier (immediate wake). Answer via
  `fleet_steer` (durable message with ack), then wait for the task to
  resume and the digest to arrive; never continue on a failed
  `needs_input` task as if it were done. Alternatively abort the wave
  (`fleet_abort`) and re-plan.
- **Failed task in a barrier group**: the digest reports it; relaunch
  with a fresh brief (recon again, new branch from `origin/main`).

### Phase 4 — Ticket status bookkeeping

- `## Stato: DONE (commit <sha>)` and `unblocks: T-0xx` are written by
  the captain ONLY (merge authority), never by the children.
- DONE = merged into `main`, not merely finished on a branch.
- The waveplan status column mirrors the tickets: planned -> launched
  -> done (merged sha) ; wave -> launched | done.

### Phase 5 — Nested launch (fleet tools in the child)

- Use `fleet_launch nested: true` when the child must orchestrate its
  own subtree (e.g. a review&fix loop orchestrator needs the fleet_*
  tools; see `templates/pipeline-orchestrator.brief.md`,
  `templates/fleet-loop-orchestrator.brief.md`).
- Only if the **running session's tool schema predates T-013** apply
  the in-place re-arm workaround (rare). New sessions running the
  current extension accept `nested` natively — the launcher emits it
  as a JSON boolean since fix `d57124c`.

## The `.scratch/waveplan.md` template

Copy this into `.scratch/waveplan.md` at the start of any multi-wave
flow (Phase 0). Do not commit an empty template file: create it per
flow.

````markdown
# Waveplan — <flow title> (T-0xx..T-0yy)

> Declared BEFORE any launch. On every group digest the captain MUST
> advance: verify reports -> merge+push if authorized -> update tickets
> -> launch the next wave -> then close the turn.

## Authorization (merge + push; never implicit)

merge_push: <ALLOWED | DENIED>        # global flag for the whole flow
merge_push_per_ticket:                # per-ticket override (optional)
  T-0xx: <ALLOWED | DENIED>
  T-0yy: <ALLOWED | DENIED>

## Waves (computed from ticket deps)

| wave | tickets            | unblocks  | status     |
|------|--------------------|-----------|------------|
| 1    | T-0xx, T-0yy       | T-0zz     | planned    |
| 2    | T-0zz              | T-0aa     | planned    |
| 3    | T-0aa, T-0bb       | —         | planned    |

- [ ] Wave 1 launched (one fleet_launch per ticket, shared groupId,
      barrier, waitAll -> ONE digest)
- [ ] Wave 1 digest processed: reports verified, merged+push, tickets
      updated (`## Stato: DONE (commit <sha>)` + `unblocks:`)
- [ ] Wave 1 -> next wave launched (or last wave + final synthesis)

## Ticket status tracking

| ticket | branch               | commit | wave | status   | notes |
|--------|----------------------|--------|------|----------|-------|
| T-0xx  | fleet/<taskid>-slug  | —      | 1    | planned  |       |
| T-0yy  | fleet/<taskid>-slug  | —      | 1    | planned  |       |

status: planned -> launched -> done (merged). DONE = merged into main.
````

## Known suspects

- Digest arrived + plan exists + captain summarizes and stops = the bug
  this skill exists to prevent: after the digest, ALWAYS execute the
  pre-declared steps and launch the next wave.
- Merge/push without authorization -> never; the flags in the waveplan
  are the only source of merge authority.
- A ticket reported done without a state file / branch -> check
  `~/.pi/fleet/<id>`; missing evidence = shipper contract violation
  (treat as failed, Phase 3).
- A wave whose blockers are still in flight -> re-check the deps before
  launching; a ticket is unblocked only when its blockers are DONE +
  merged, not when the digest merely arrived.