# fleet-loop-orchestrator — filled brief (T-018 pilot, review&fix loop)

> Filled from `templates/fleet-loop-orchestrator.brief.md` by the T-018
> pipeline orchestrator (task t-018-pilot-e2e-pipeline-compl-243) for the
> review&fix loop hook on the INTEGRATED tree of the t018 pilot pipeline.

## OBJECTIVE

Act as the review&fix loop **orchestrator** for the pipeline defined in
`pilot/t018/pipeline.spec.json` (project: `/Users/alessandro/Documents/GitHub/pi-fleet`).
Run the loop to a verdict:

- **PASS** — cycle 3 fresh review reports no BLOCKING findings AND all
  pipeline `checks` pass on the verified effective branch; or
- **FAILED_TO_CONVERGE** — after 3 fixed cycles BLOCKING findings remain (or
  checks keep failing) → done-marker `~/.pi/fleet/<your-task-id>.done.json`
  with `status: "failed"` and the full report.

## CONTEXT (what was integrated)

The implementation pipeline (T-017) already ran to a green tree on the
effective branch **`fleet/018-pilot-e2e`** (current HEAD: `1495d41`):
- `templates/pipeline-orchestrator.brief.md` slice `readme-section` → README.md
  "## Review loop / pipeline" section (commit `cf506eb`);
- slice `tickets-crosslink` → cross-link line in docs/pipeline-tickets.md
  (commit `1495d41`);
- the 3 pipeline checks are green at HEAD (verified by the parent before hooking).

**Your worktree**: `git switch fleet/018-pilot-e2e` FIRST (the parent released
the branch). The branch MUST be your working branch — commit/cherry-pick
there. Never create `fleet/pipeline-*` in this pilot (the parent already
named the effective branch); never touch another branch, never main.

## LOOP SEMANTICS (non-negotiable)

1. **Exactly 3 fixed cycles.** Never early-exit on a first PASS. Cycle 2 and
   cycle 3 are FRESH reviews from scratch (fresh reviewer tasks, never reused
   sessions). A cycle is: review wave → findings → fix wave → verify.
2. **Reviewer wave** = one `fleet_launch` per `review_skills` entry across the
   spec slices → this pilot has TWO slices (`readme-section`,
   `tickets-crosslink`), each with `review_skills: [writing-for-agents]` →
   TWO reviewers per cycle:
   - reviewer A evaluates the README "Review loop / pipeline" section (slice
     readme-section);
   - reviewer B evaluates the docs/pipeline-tickets.md cross-link (slice
     tickets-crosslink) + the tickets doc integrity.
   Each: `kind: "scout"`, `project: /Users/alessandro/Documents/GitHub/pi-fleet`,
   `worktree: true`, shared explicit `groupId` `grp-t018-pilot-r<c>` (c =
   cycle 1..3), `groupMode: "barrier"`, `groupFailPolicy: "waitAll"` → exactly
   ONE group digest wakes you. `needs_input` breaks the barrier (immediate
   wake): answer via `fleet_steer` or abort the wave; never continue on a
   failed `needs_input` reviewer.
3. **Findings STRICTLY from state files** (`~/.pi/fleet/<id>.findings.json`),
   never from the prose digest (the digest is ONLY the wake signal). The
   done-marker `<id>.done.json` is transient — the launcher consumes and
   deletes it before the digest fires. Put in EVERY reviewer brief: "ALSO
   write your structured findings to `~/.pi/fleet/$FLEET_TASK_ID.findings.json`
   ({ \"taskId\": \"<your-task-id>\", \"findings\": [...] }, findings array may
   be empty on PASS)." Reviewers review the branch state: in their worktree
   `git switch --detach fleet/018-pilot-e2e`; they never commit.
4. **Helper (deterministic), never hand-merging** (run from your worktree root):
   ```
   H=bin/fleet-loop-helper.sh
   $H spec-validate pilot/t018/pipeline.spec.json        # abort if invalid
   $H dedup   ~/.pi/fleet/<revA>.findings.json ~/.pi/fleet/<revB>.findings.json
   $H group   <deduped>.json
   $H partition --severity BLOCKING <deduped>.json       # hybrid fixer plan
   ```
   `partition` returns `batches` with a `wave`: run all batches of wave `k`
   as one fixer wave (parallel ⇔ disjoint files), wait for its digest, then
   wave `k+1` (sequential ⇔ shared files). A batch is single-domain.
5. **Fixers** = `kind: "ship"`, `deliveryPosture: "local-only"`,
   `worktree: true`, `project: /Users/alessandro/Documents/GitHub/pi-fleet`,
   one per batch, one wave at a time via a shared `groupId`
   (`grp-t018-pilot-f<c>-w<k>`). Brief each fixer ONLY with its batch
   findings (id, domain, location, problem, requiredFix, verification), the
   review skill (`writing-for-agents`, /Users/alessandro/.agents/skills/writing-for-agents/SKILL.md),
   and the original `scope` from the spec. Fixers commit on THEIR isolated
   branch `fleet/<taskid>-<slug>`, **ONE COMMIT PER FILE**, never on the
   effective branch and never on main. In their worktree:
   `git switch -c fleet/<taskid>-<slug> fleet/018-pilot-e2e`.
6. **Integration — you are the ONLY committer on the effective branch**
   `fleet/018-pilot-e2e`. Fixers run in shared-repo worktrees, so their
   branches are visible (`git branch --list 'fleet/*'`). After each fixer
   wave: for every fixer task, `git cherry-pick` each commit of its branch
   onto the effective branch (their commit-per-file rule is preserved). On
   conflict: STOP the wave, report and include the conflict diff in the
   report (never force-resolve blindly).
7. **Verify after each cycle** = run every `checks[].cmd` from the spec as
   `bash -c "<cmd>"` from the worktree root (exit 0 = pass — gate-run.sh
   semantics). Red → record the failing checks as a REGRESSION for the cycle,
   `git revert` the wave's cherry-picks (restore a green base), and continue
   to the next cycle.
8. **Verdict after cycle 3:** cycle-3 reviewers ALL PASS (no BLOCKING
   findings, empty arrays) AND the final verify green, on the effective
   branch, with `git status --porcelain` clean → **PASS**. Otherwise →
   **FAILED_TO_CONVERGE** (done-marker `status: "failed"`).

## REVIEW CHECKLIST (derived from writing-for-agents; each reviewer evaluates ALL items)

Domain for finding ids: **DOCS** (FINDING-DOCS-nn). Checklist items:

- `DOCS-1` — entry-point pointers correct: the README section names the two
  brief templates, the implementing skills and the helpers with paths that
  EXIST in the repo (no invented/stale paths, single source of truth).
- `DOCS-2` — prerequisites accurate: nested launch flag, depth cap
  (postures.json `$config.nestedMaxDepth`, full pipeline needs >= 3), review
  skills resolvable, jq — no no-op or stale statements.
- `DOCS-3` — no duplication: the section does not re-state content already
  present elsewhere in README.md (check the "How it works" / "Architecture"
  / "Testing" sections) — a meaning lives in ONE authoritative place.
- `DOCS-4` — steps + completion criteria: the How-to-run steps end on
  checkable criteria (exit 0 checks, PASS / FAILED_TO_CONVERGE) — no vague
  bounds inviting premature completion.
- `DOCS-5` — relevance / no filler: every sentence either carries a pointer,
  a prerequisite, or a workflow step — no exposition that never bears on the
  task (a future agent must be able to RUN the workflows from the section).
- `DOCS-6` (reviewer B only) — cross-link: the docs/pipeline-tickets.md
  cross-link contains the literal "Review loop / pipeline", sits near the
  intro paragraph, and the tickets doc structure/fences are intact.

## SCOPE

The spec `scope` (pilot/t018/pipeline.spec.json) is the loop boundary: the
pipeline may touch README.md and docs/pipeline-tickets.md only. Reviewers
evaluate exactly those two files (plus the surrounding repo context needed
for path verification). Do not expand scope; do not touch anything outside
`/Users/alessandro/Documents/GitHub/pi-fleet`.

## DELIVERY

- Effective branch `fleet/018-pilot-e2e` in the project (local only: NEVER
  push, NEVER open a PR — merge authority stays with the captain).
- Done-marker `~/.pi/fleet/<your-task-id>.done.json`:
  - **PASS**: `{"status":"done","summary":"STATUS: PASS\n<report>","changedFiles":[...]}`
  - **FAILED_TO_CONVERGE**: `{"status":"failed","summary":"STATUS: FAILED_TO_CONVERGE\n<report>","changedFiles":[...]}`

### REPORT (in the done-marker summary, structured Markdown)

- verdict (`PASS` / `FAILED_TO_CONVERGE`);
- per-cycle table: reviewer task ids, findings count (BLOCKING/NON_BLOCKING),
  fixer batches/waves, commits cherry-picked, verify result (each check:
  name, exit code);
- unresolved findings (id, location, first-seen cycle, repeated in);
- regressions (cycle, check name, exit code, revert sha);
- final verification evidence (each check: name, exit code, output tail).

## KNOWN SUSPECTS

- If the digest arrives without findings on disk for a reviewer that reported
  `done`, check `~/.pi/fleet/<id>.findings.json` was written (missing =
  reviewer contract violation → treat as reviewer failure).
- `needs_input` from a fixer: steer with the missing context or abort and
  re-plan the batch; never silently skip its findings.
- do NOT call the captain-only fleet tools (fleet_learn, fleet_captain_pref,
  fleet_bootstrap, fleet_stow) — they are denied for nested children anyway.