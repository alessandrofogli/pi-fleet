# T-016 Pilot — live review&fix loop on loop-sample (nested orchestrator)

Status: WIP — recon + plan (updated through the run by the orchestrator task).

## Objective (from the ticket)

Validate the T-015 review&fix loop END-TO-END on a real existing change, live:
reviewer scout waves (fleet_launch, group barrier) -> findings (durable state
files) -> fixer ship waves (one commit per file) -> orchestrator cherry-pick
integration -> verification -> convergence with zero worktree conflicts. This
run IS the first live (in-env) validation of the nested path that T-013 smoke
S6 could only mock in-process.

## Baseline (recon)

- Base: `origin/main` = `e52afce6cef3f85eb8440c7a46643fdd13a82c46` (T-015 merge).
  `git fetch origin` + branch `fleet/016-pilot-loop` created from it. HEAD verified.
- Loop input (the "real existing change"): the planted-defect loop-sample
  fixture, subsystem `fixtures/loop-sample/` of this repo — 5 BLOCKING
  findings in `fixtures/loop-sample/src/shapes.sh` (v1 baseline:
  `bash fixtures/loop-sample/bin/audit.sh` -> 5 findings, ids SAMPLE-01..04;
  SAMPLE-04 appears twice at distinct locations).
- Pipeline spec: `fixtures/loop-sample/pipeline.spec.json` (validated
  `{"valid":true}` by `bin/fleet-loop-helper.sh spec-validate`).
  scope: "The loop may touch src/ only" (fixture-relative). checks: syntax,
  behavior (exit-0, gate-run.sh semantics) — both green at baseline.
- Review skill: `sample-style-review` (checklist SAMPLE-1..4; deterministic
  companion `fixtures/loop-sample/bin/audit.sh`). Single review_skills entry
  in the spec slice `sample-core` -> one reviewer per wave (1 skill is within
  the pilot's allowance; a second skill is not present in the spec).
- Self-context read: `templates/fleet-loop-orchestrator.brief.md` (filled in
  below with the real values), `fixtures/loop-sample/README.md`,
  `bin/fleet-loop-helper.sh`, `skills/fleet-review-loop/SKILL.md`,
  `skills/review-loop-protocol/SKILL.md`. Descriptions match the code
  (verified file:line, e.g. helper's `cmd_partition` hybrid algorithm at
  bin/fleet-loop-helper.sh:246-330).

## Loop plan (template filled)

- Pillars: **3 fixed cycles** (no early-exit), reviewer wave = group barrier
  waitAll -> ONE digest, findings STRICTLY from `~/.pi/fleet/<id>.findings.json`
  via the helper (dedup/group/partition), fixers ship local-only ONE COMMIT PER
  FILE on their own branch `fleet/<taskid>-<slug>`, orchestrator-only commits on
  the effective branch `fleet/016-pilot-loop` (cherry-pick), verify per cycle
  with revert-on-red, verdict PASS / FAILED_TO_CONVERGE after cycle 3.
- Effective branch: `fleet/016-pilot-loop` (this branch; I am the ONLY
  committer — the WIP recon commit below plus cherry-picked fixer commits).
- Checkout contract for every spawned child (their worktrees land detached at a
  pool commit; `fleet/016-pilot-loop` is checked out in MY worktree so children
  must not `git switch` to it directly):
  - reviewers (scout): `git switch --detach fleet/016-pilot-loop` first,
    review that state read-only;
  - fixers (ship): `git switch --detach fleet/016-pilot-loop` then
    `git switch -c fleet/<taskid>-<slug>`; fix and commit ONLY on their branch.
- Location mapping: findings are fixture-relative (`src/shapes.sh:N`); the real
  repo path is `fixtures/loop-sample/src/shapes.sh:N`. Fixers receive the mapped
  path; the helper's partition file-sets keep fixture-relative names.

## Expected convergence path

Cycle 1: reviewer reports the 5 planted BLOCKING findings -> partition -> 1
batch (single domain SAMPLE, one file) -> 1 fixer -> 1 commit (one file) ->
cherry-pick -> checks green. Cycles 2-3: fresh reviewers report 0 findings
(fixed tree, no regression expected: fixes are style-only, behavior preserved)
-> no fixers -> checks green -> PASS.

## KNOWN SUSPECTS to report

1. Digest delivery to THIS nested session (in-env vs T-013 S6 in-process) —
   timing, whether findings files exist on disk by digest time.
2. Worktree conflicts across reviewer/fixer waves — target: zero.