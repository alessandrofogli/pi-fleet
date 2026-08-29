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
