# T-018 pilot e2e — recon notes & plan (WIP)

Pilot objective: run the FULL implementation pipeline (T-017) end to end on
one small REAL ticket in the pi-fleet repo — tickets markdown → converter →
DAG waves → shipper subtasks → hybrid integration → deterministic checks →
review&fix loop hook (T-015) → converged branch — then write the README
"Review loop / pipeline" docs section. Local-only delivery (no push, no PR).

## Session facts (recon evidence)

- Task: `t-018-pilot-e2e-pipeline-compl-243`, state re-armed `nested: true`,
  `depth: 1` (`~/.pi/fleet/t-018-pilot-e2e-pipeline-compl-243.json`) — the
  gate re-reads state per call, so the fleet_* tools are enabled in this
  session (verified: `fleet_status`, `fleet_posture` worked at start).
- Depth cap: `~/.pi/fleet/postures.json` `$config.nestedMaxDepth = 3`
  (extension reads `getNestedMaxDepth()`, `extensions/fleet-posture.ts:65-80`;
  launch denial when `myDepth >= maxNestedDepth`,
  `extensions/index.ts:816-825`). My depth 1 < 3 → I can launch; my children
  inherit depth 2 (`childDepth = myDepth + 1`, `extensions/index.ts:819`).
- Base: `origin/main` = 7c67fa9 at session start (brief). NOTE (live-loop
  observation): `origin/main` later moved to f8226c0 (T-016 pilot docs merged
  during this run) — branch `fleet/018-pilot-e2e` was created from the brief's
  base 7c67fa9 and shippers are pinned to that sha, NOT to the moving
  `origin/main` ref.
- Environment: `FLEET_TASK_ID=t-018-pilot-e2e-pipeline-compl-243`,
  `FLEET_DEPTH=1` → session role `nested` (`extensions/index.ts:665-673`).
  Worktree shared-repo: `.git` → `gitdir:
  /Users/alessandro/Documents/GitHub/pi-fleet/.git/worktrees/pi-fleet5`
  (shared refs → shipper/fixer branches visible via `git branch --list`).

## Self-context read (all at the brief-mandated paths)

- `skills/pipeline-orchestrator/SKILL.md` — 4 phases + shipper contract +
  integration/verify semantics + hook.
- `templates/pipeline-orchestrator.brief.md` — filled brief for the pipeline
  (deps written in the tickets; waves; hybrid integrate; checks; hook).
- `bin/fleet-pipeline-helper.sh` — `convert` (md→spec projection, validated),
  `waves` (topological layers), `integrate` (union-find + greedy wave
  coloring, `disjoint` proof flag), `spec-validate` (delegates to
  `bin/fleet-loop-helper.sh`).
- `bin/fleet-loop-helper.sh` — `dedup` / `group` / `partition --severity
  BLOCKING` / `spec-validate`; findings data model
  (id, severity, domain, checklist, location, rule, problem, evidence,
  requiredFix, verification); durable findings file `<id>.findings.json`.
- `docs/pipeline-tickets.md` — ticket markdown format (sections `## scope`,
  `## slice <id>`, `## checks`; `deps` written in the tickets).
- `templates/fleet-loop-orchestrator.brief.md` — 3 fixed cycles, reviewer
  waves (scout, group barrier), findings strictly from state files, fixer
  waves (ship, one commit per file), verify after each cycle, verdict
  PASS / FAILED_TO_CONVERGE.
- `skills/fleet-review-loop/SKILL.md` + `skills/review-loop-protocol/SKILL.md`
  — reviewer contract + findings format (FINDING-<DOMAIN>-nn) + done-marker
  contract (`findings` array + `STATUS: PASS|FAIL`).

## Pilot design decisions

1. **Ticket** (the real deliverable, per brief "natural fit"): the README
   "Review loop / pipeline" section IS the implementation target. Two slices:
   - `readme-section` (add the section to README.md);
   - `tickets-crosslink` (add a cross-link in docs/pipeline-tickets.md).
   Both deps-free → ONE parallel wave (2 shippers, 1 group digest), file
   disjoint → hybrid integrate returns 2 parallel-safe batches.
   - Checks (all exit-0, gate-run.sh semantics): `readme-section`,
     `readme-entry-points`, `tickets-crosslink`.
   - Review skill: `writing-for-agents` (user-level,
     ~/.agents/skills/writing-for-agents/SKILL.md — resolvable in repo
     worktrees by absolute path), used as impl_skills AND review_skills;
     findings domain `DOCS`.
   - NOTE on verify semantics: T-017 runs EVERY check after EVERY wave
     (`pipeline-orchestrator` SKILL phase 4.5) — so all checks must be green
     at every intermediate wave; with deps-based waves the wave-1 state must
     already satisfy the full check set. Chosen ticket (single parallel wave)
     is compatible by construction. Recorded as an observation, not a bug.
2. **Effective branch**: the brief's DELIVERY names branch
   `fleet/018-pilot-e2e`; the pipeline/loop templates name
   `fleet/pipeline-<pipeline-id>`. Pilot unification choice: ONE effective
   branch `fleet/018-pilot-e2e` (orchestrator commits + integrated shipper
   commits + loop fixes). Loop hook brief overrides the template's branch
   name accordingly. Before launching the loop hook the parent worktree
   detaches from the branch so the nested loop orchestrator can check it out
   in ITS worktree (git one-branch-one-worktree rule).
3. **Shipper base**: pinned to 7c67fa9 (brief base), NOT the moving
   `origin/main`.
4. **Loop hook**: launched `nested: true` (depth 2 < cap 3); it spawns
   reviewers (scout) / fixers (ship) at depth 3. If the gate denies
   anything: report as finding, NEVER bypass.

## Suspect checklist (from the SKILLs' "Known suspects")

- shipper done without branch/file set → check `~/.pi/fleet/<id>.*`;
- `integrate` with `disjoint: false` → helper bug, stop + report;
- review skill resolvability on the reviewed project;
- digest without findings on disk → reviewer contract violation;
- `needs_input` breaks the barrier → steer or abort, never continue blindly;
- conflicts on cherry-pick → STOP the wave, report, no force-resolve.

## Pipeline artifacts (committed on fleet/018-pilot-e2e)

- `pilot/t018/tickets.md` — the ticket markdown (source of truth).
- `pilot/t018/pipeline.yaml` + `pilot/t018/pipeline.spec.json` — lossless
  projection from `bin/fleet-pipeline-helper.sh convert`.
- `docs/pilot-t018-e2e.md` — this file (recon / plan / divergences).

WIP — committed before any pipeline phase.

## Live-run divergences found (turned into report findings)

1. **Finder 1 — launcher JSON-boolean bug breaks the native nested path**
   (found by the nested loop-orchestrator child, needs-input
   `~/.pi/fleet/t-018-pilot-review-fix-loop-in-228.needs-input.json`):
   - `bin/herdr-launch.sh:69` `--nested) NESTED=1` + `:263`
     `"nested": ${NESTED}` → the state JSON carries `"nested": 1`
     (NUMBER), while the T-013 gate `extensions/index.ts:720`
     `if (t?.nested !== true)` is STRICT-boolean → the child is classed
     `mute` and every fleet_* call is EXPLICITLY denied
     (extensions/index.ts:720-724). The gate behaved per design; the
     launcher serialization is the bug. Only the captain's MANUAL
     in-place re-arm (T-016/T-018 precedent) made the nested path work
     at all. Evidence: state files `t-016-...-140.json` `"nested": true`
     (re-armed) vs `t-018-pilot-review-fix-loop-in-228.json` `"nested": 1`
     (launcher-written).
   - Remedy used in this pilot: NOT patching the child state (outside
     cwd, captain's call) — the parent (re-armed) runs the review&fix
     loop itself; reviewer/fixer waves are plain scout/ship tasks
     (mute is correct for them, no nested tools needed). Depth-3
     nested spawning was NOT exercised live.
2. **Finder 2 — transient TDZ on two parallel fleet_launch in one tick**
   (wave-1 shipper launch): second of two parallel `fleet_launch` calls
   crashed `Cannot access 'DEFAULT_NESTED_MAX_DEPTH' before
   initialization` — root cause hypothesis: `getFleetPosture()`
   single-flight bug (`extensions/index.ts:47-51`: `_fleetPosture` is
   assigned only AFTER `await import(...)` → two concurrent callers
   both see null → duplicate module instantiation of fleet-posture.ts
   → TDZ on the second copy). Retry sequential = fine (observed).
3. **Observation — verify-after-every-wave means all checks must be green
   at every intermediate wave** (pipeline-orchestrator phase 4.5). With
   deps-based multi-wave pipelines the wave-1 state must already satisfy
   the FULL check set; the chosen ticket (single parallel wave) is
   compatible by construction. Design note, not a bug.
4. **Observation — origin/main moved** from 7c67fa9 (brief base) to
   f8226c0 (T-016 docs merged) during the run; shippers were pinned to
   the exact base sha 7c67fa9, so the drift was inert.