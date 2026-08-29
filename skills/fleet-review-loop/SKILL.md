---
name: fleet-review-loop
description: 'Orchestrator procedure for the review loops in pi-fleet: run review → findings → fix → verify → fresh review cycles using fleet_launch (scout review tasks, ship fix tasks), collect structured findings from done-markers, group/split fixers, verify with pipeline checks, converge to PASS within 3 cycles. Pairs with review-loop-protocol.'
license: MIT
metadata:
  tags: "review, loop, orchestrator, findings, pipeline, pi-fleet"
  category: "workflow"
---

# fleet-review-loop — orchestrator procedure

## Purpose

Run a complete review → findings → fix → verification → fresh review
cycle on an existing implementation, orchestrated with pi-fleet tasks.

This skill is domain-agnostic.

It does not contain language-, framework-, or technology-specific
review rules. Those come from the review skills configured for the
pipeline.

## Relationship to other components

- `review-loop-protocol` skill — the reviewer contract each review task
  follows (evaluates, reports PASS/FAIL checklist, emits structured
  findings).
- Pipeline spec (`docs/pipeline-spec.md`) — declares `scope`, `slices`
  (each with `impl_skills`, `review_skills`, `deps`) and `checks`.
- The loop machinery that automates this procedure is a separate ticket
  (T-015); THIS skill documents the procedure an orchestrator
  (captain or automation) must follow.

## Inputs

The workflow receives:

- Original task / Jira ticket.
- Current implementation.
- Pipeline spec (`scope`, `slices[].review_skills`, `checks`).
- `review-loop-protocol` (the reviewer contract).
- The review skills listed in the pipeline slices.
- Optional project-specific verification commands (pipeline `checks`
  and project-level checks).

The Jira ticket / `scope` defines the boundary of the loop.

## Core Workflow

For each review cycle:

1. Spawn fresh review sub-agents (pi-fleet tasks, `kind: scout`).
2. Assign each reviewer one review skill or one logically coherent
   review responsibility (from `slices[].review_skills`).
3. Give every reviewer `review-loop-protocol`.
4. Give every reviewer the original task / pipeline `scope`.
5. Run reviewers independently and in parallel (one `fleet_launch` per
   reviewer, same `groupId` so the group digest arrives as one wake
   signal).
6. Require complete checklist evaluation.
7. Collect all results: the group digest is ONLY the wake signal — read
   the structured findings from each task's state file
   (`~/.pi/fleet/<id>.done.json` `findings` array).
8. Deduplicate and organize findings.
9. Create fix tasks from BLOCKING findings.
10. Dynamically allocate fix agents (pi-fleet `ship` tasks).
11. Verify the fixes (run pipeline `checks` + project checks).
12. Spawn fresh reviewers.
13. Repeat until PASS or the maximum cycle count is reached.

## Launching review tasks

Each reviewer is a pi-fleet task:

- `kind: "scout"` — reviewers never modify code, so a scout (report
  only, no commit) is the right kind.
- `project`: the project under review (absolute path or short name via
  `FLEET_PROJECTS_DIR`).
- `groupId` / `groupLabel`: shared by all reviewers of one cycle, so
  `fleet_status` shows one digest (`grp:xxx n/m`) as the wake signal.
- `groupFailPolicy`: `immediate` when a review failure invalidates the
  other reviewers' input (rare); default `waitAll`.
- The brief must include: the original task scope, the assigned review
  skill, `review-loop-protocol`, the implementation location, and the
  done-marker contract (structured `findings` in `<id>.done.json`).

## Reviewer Allocation

Create specialized reviewers based on the review skills declared in the
pipeline `slices`.

Do not require one reviewer to evaluate unrelated domains.

For example:

Reviewer 1:
- review-loop-protocol
- python-style-review

Reviewer 2:
- review-loop-protocol
- python-design-review

Reviewer 3:
- review-loop-protocol
- mcp-guidelines-review

Every review skill configured in the pipeline must be evaluated.

Do not silently skip a configured review skill.

## Reviewer Independence

Reviewers must operate independently.

During the initial review:

- do not give Reviewer A Reviewer B's findings;
- do not give Reviewer B Reviewer A's findings.

Reviewers should independently inspect the implementation.

## Fresh Reviewers

Every new review cycle MUST use fresh reviewer sub-agents.

Do not reuse previous reviewer sessions.

Do not ask the previous reviewer to review its own fixes.

Each new reviewer receives:

- the current implementation;
- the original task / scope;
- the same assigned review skill;
- `review-loop-protocol`.

The new reviewer evaluates the current state from scratch.

## Findings Synthesis

After all reviewers finish, the orchestrator:

1. Collects all findings from the done-marker `findings` arrays.
2. Removes duplicates.
3. Identifies findings describing the same underlying issue.
4. Preserves the relevant review domain.
5. Identifies dependencies between findings.
6. Separates BLOCKING and NON_BLOCKING findings.

Only BLOCKING findings normally trigger fixes.

Do not invent findings during synthesis.

Do not upgrade subjective suggestions into BLOCKING findings.

## Fix Allocation

Do NOT create one fixer per reviewer.

Do NOT create one fixer per finding by default.

Determine the number of fix agents dynamically based on:

- number of findings;
- complexity;
- dependencies;
- affected files;
- affected components;
- review domain;
- potential conflicts.

### Group findings

Multiple findings may be assigned to the same fixer when:

- they belong to the same review domain;
- they affect compatible code;
- they are logically related;
- they can be safely fixed together.

### Separate findings

Use separate fixers when:

- findings belong to unrelated review domains;
- fixes affect independent components;
- fixes have different technical contexts;
- parallelization is safe and useful.

A fixer MUST NOT be assigned findings from unrelated review domains.

For example:

- Python standards + MCP guidelines → separate fixers.
- Python typing + Python style → may share a fixer when appropriate.

Each fixer is a pi-fleet task (`kind: "ship"`, `worktree: true` so fix
agents never collide) with a brief listing its assigned findings (id,
domain, location, problem, required fix, verification).

## Fix Agent Instructions

Each fix agent receives:

- assigned findings;
- original task / pipeline scope;
- relevant code context;
- relevant review skill(s);
- required fix;
- verification criteria.

Fix agents may modify files.

Fix agents must:

1. Fix the assigned findings.
2. Preserve the original task scope.
3. Avoid unrelated refactoring.
4. Add or update tests when appropriate.
5. Run relevant verification.
6. Report changes and verification results.

A fix agent must not decide that unrelated review findings are part of
its task.

## Dependencies

When findings are dependent, fix them sequentially or assign them to
one fixer.

When findings are independent and non-conflicting, fix them in
parallel.

Do not parallelize changes that may modify the same code in conflicting
ways.

## Deterministic Verification

After fixes are applied, run applicable deterministic checks:

- the pipeline `checks` (`name` + `cmd`, exit 0 = pass);
- project-level checks (tests, lint, formatting, type checking, build,
  static analysis, project-specific validation).

A fix agent claiming that a finding is resolved is not sufficient by
itself: the orchestrator must see the check output.

## Re-Review

After verification, start a NEW review cycle.

Spawn fresh reviewers using:

- the same review skills;
- the same `review-loop-protocol`;
- the original task / scope.

Do not reuse the previous reviewer sessions.

The fresh reviewers must evaluate:

- whether previous findings are resolved;
- whether fixes introduced regressions;
- whether new BLOCKING findings exist;
- whether every checklist item still passes.

## Maximum Cycles

Default maximum: 3 review cycles.

### Cycle 1

Review → Findings → Fix → Verify.

### Cycle 2

Fresh Review → Findings → Fix → Verify.

### Cycle 3

Fresh Review → Findings → Fix → Verify.

After Cycle 3:

If all reviewers return PASS:

STATUS: PASS

Otherwise:

STATUS: FAILED_TO_CONVERGE

Do not automatically start a fourth cycle.

## PASS

The workflow succeeds only when every configured reviewer returns:

STATUS: PASS

This means:

- every configured review skill was evaluated;
- every checklist item passed;
- no BLOCKING finding remains;
- relevant deterministic verification passes.

Do not declare success because fix agents claim success.

Do not declare success because tests alone pass.

## FAILED_TO_CONVERGE

If the maximum number of cycles is reached while BLOCKING findings
remain:

STATUS: FAILED_TO_CONVERGE

Report:

- cycles completed;
- unresolved findings;
- repeated findings;
- verification failures;
- relevant regressions;
- concise reason for non-convergence.

Stop the automated loop.

## Scope Control

The pipeline `scope` / Jira ticket defines the boundary of the loop.

Do not expand the task because reviewers identify:

- unrelated technical debt;
- optional refactoring;
- unrelated architecture improvements;
- subjective style preferences;
- improvements outside the ticket.

Only issues relevant to the task or mandatory configured review
criteria should drive the fix loop.

## Git

This loop procedure does not push and does not merge.

Fix agents commit in their own fleet worktrees on their own
`fleet/<id>-<slug>` branches, honoring the project's delivery posture
(`local-only`, `direct-PR`, ...). Merge authority stays with the
captain; the loop ends with a verified working tree and reviewers
reporting PASS.

## Core Principle

The workflow is findings-driven.

Reviewers identify concrete problems.

Fix agents resolve those problems.

Deterministic checks provide objective verification.

Fresh reviewers independently verify the result.

The loop stops when all configured review criteria PASS.

Optimize for:

- correctness;
- complete review coverage;
- scope control;
- reviewer independence;
- efficient fix allocation;
- convergence.