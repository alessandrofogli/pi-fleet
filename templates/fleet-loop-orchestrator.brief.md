# fleet-loop-orchestrator — brief template (T-015)

> **How to use.** This is the template for launching a NESTED orchestrator task
> that runs the review&fix loop on a project, per the `fleet-review-loop` skill.
> The captain copies it, fills the `{{PLACEHOLDERS}}`, and launches with:
>
> ```
> fleet_launch
>   title:      loop <project-slug> <spec-name>          # e.g. "loop loop-sample"
>   brief:      <this template, filled>                  # read from a file if long
>   project:    {{PROJECT}}                              # the REVIEWED project (absolute path)
>   nested:     true                                     # REQUIRED: gives the child the fleet_* tools
>   worktree:   true
>   deliveryPosture: local-only                          # the loop never pushes
> ```
>
> The orchestrator spawns its OWN reviewer/fixer waves with `fleet_launch`
> (`nested` only for the orchestrator — reviewers and fixers are plain tasks).
> Preconditions: the reviewed project is a git repo; the pipeline spec exists;
> the review skills referenced by the spec are resolvable by reviewer sessions
> (repo `skills/<name>/SKILL.md`, user skills, or project skills — same
> mechanism pi-fleet itself uses); `bin/fleet-loop-helper.sh` and the loop
> skills ship with pi-fleet at {{PI_FLEET_ROOT}}.

---

## OBJECTIVE

Act as the review&fix loop **orchestrator** for the pipeline defined in
`{{SPEC_PATH}}` (project: `{{PROJECT}}`). Run the loop to a verdict:

- **PASS** — cycle 3 fresh review reports no BLOCKING findings AND all
  pipeline `checks` pass on the verified effective branch; or
- **FAILED_TO_CONVERGE** — after 3 fixed cycles BLOCKING findings remain (or
  checks keep failing) → done-marker with `status: "failed"` and the full
  report (see `REPORT` below).

Follow the **`fleet-review-loop`** skill (orchestrator procedure) and hand the
**`review-loop-protocol`** skill to every reviewer. The skills are at
`{{PI_FLEET_ROOT}}/skills/`; the helper is `{{PI_FLEET_ROOT}}/bin/fleet-loop-helper.sh`.

## LOOP SEMANTICS (non-negotiable)

1. **Exactly 3 fixed cycles — MECHANICALLY ENFORCED (T-019).** The loop bound
   lives in `$FLEET_STATE_HOME/<loopId>.loop.json` (default `~/.pi/fleet/`), a
   `{cycle, maxCycles}` counter read/updated by `bin/fleet-loop-helper.sh` EVERY
   cycle (never trust the prompt alone). Let `H={{PI_FLEET_ROOT}}/bin/fleet-loop-helper.sh`
   and `LOOP_ID=loop-{{PIPELINE_ID}}`.
   - **Start of every cycle** run `$H loop-next $LOOP_ID 3`. It either returns
     `{"ok":true,"cycle":N,...}` (proceed) or **REFUSES** with
     `{"ok":false,"refused":"maxCycles"}` (exit 1): then STOP the loop, write the
     done-marker `FAILED_TO_CONVERGE` with the report — do NOT start another cycle.
   - **No early-exit verdicts**: before writing ANY terminal verdict (PASS or
     FAILED_TO_CONVERGE) run `$H loop-final $LOOP_ID 3`. A refusal
     (`refused:"early-exit"`) means the cycle count is below the bound: you MUST
     continue the loop, never close with a verdict.
   - Cycle 2 and cycle 3 are FRESH reviews from scratch (fresh reviewer tasks,
     never reused sessions). A cycle is: review wave → findings → fix wave → verify.
2. **Reviewer wave** = one `fleet_launch` per `review_skills` entry across the
   spec slices, `kind: "scout"`, `project: {{PROJECT}}`, shared explicit
   `groupId` (`grp-{{PIPELINE_ID}}-r<c>`), `groupMode: "barrier"`,
   `groupFailPolicy: "waitAll"` → exactly ONE group digest wakes you.
   `needs_input` breaks the barrier (an immediate wake): answer via
   `fleet_steer` or abort the wave (`fleet_abort`); never continue on a
   failed `needs_input` reviewer.
3. **Findings STRICTLY from state files** (`~/.pi/fleet/<id>.findings.json`),
   never from the prose digest (the digest is ONLY the wake signal). The
   done-marker `<id>.done.json` is transient — the launcher consumes and
   deletes it before the digest fires. Each reviewer must ALSO write its
   structured findings to `~/.pi/fleet/$FLEET_TASK_ID.findings.json`
   (`{"taskId":..., "findings":[...]}`) — put this in every reviewer brief.
4. **Helper (deterministic), never hand-merging:**
   ```
   H={{PI_FLEET_ROOT}}/bin/fleet-loop-helper.sh
   $H spec-validate {{SPEC_PATH}}                       # abort if invalid
   $H dedup   ~/.pi/fleet/<rev1>.findings.json ...      # dedup by id+location
   $H group   findings.json                             # domain grouping
   $H partition --severity BLOCKING findings.json       # hybrid fixer plan
   ```
   `partition` returns `batches` with a `wave`: run all batches of wave `k`
   as one fixer wave (parallel ⇔ disjoint files), wait for its digest, then
   wave `k+1` (sequential ⇔ shared files). A batch is single-domain.
5. **Fixers** = `kind: "ship"`, `deliveryPosture: "local-only"`,
   `worktree: true`, `project: {{PROJECT}}`, one per batch, one wave at a
   time via a shared `groupId`. Brief each fixer ONLY with its batch
   findings (id, domain, location, problem, requiredFix, verification) +
   the original `scope` from the spec + the review skill. Fixers commit on
   THEIR isolated branch `fleet/<taskid>-<slug>`, **ONE COMMIT PER FILE**,
   never on the effective branch and never on main.
6. **Integration — you are the ONLY committer on the effective branch**
   `fleet/pipeline-{{PIPELINE_ID}}`. Fixers run in shared-repo worktrees, so
   their branches are visible (`git branch --list 'fleet/*'`). After each
   fixer wave: for every fixer task, `git cherry-pick` each commit of its
   branch onto the effective branch (their commit-per-file rule is preserved).
   On conflict: STOP the wave, report and answer with the conflict diff in the
   report (never force-resolve blindly).
7. **Verify after each cycle** = run every `checks[].cmd` from the spec as
   `bash -c "<cmd>"` from the project root (exit 0 = pass — gate-run.sh
   semantics). Red → record the failing checks as a REGRESSION for the cycle,
   `git revert` the wave's cherry-picks (restore a green base), and continue
   to the next cycle.
8. **Verdict after cycle 3:** cycle-3 reviewers ALL PASS (no BLOCKING
   findings, empty arrays) AND the final verify green, on the effective
   branch, with `git status --porcelain` clean → **PASS**. Otherwise →
   **FAILED_TO_CONVERGE** (done-marker `status: "failed"`).

## SCOPE

`{{SCOPE}}` — the spec `scope` field is the loop boundary. Reviewers and
fixers must not expand it. Do not touch anything outside `{{PROJECT}}`.

## DELIVERY

- Effective branch `fleet/pipeline-{{PIPELINE_ID}}` in `{{PROJECT}}` (local
  only: NEVER push, NEVER open a PR — merge authority stays with the captain).
- Done-marker `~/.pi/fleet/<your-task-id>.done.json`:
  - **PASS**: `{"status":"done","summary":"STATUS: PASS\n...cycles, verification...","changedFiles":[...]}`
  - **FAILED_TO_CONVERGE**: `{"status":"failed","summary":"STATUS: FAILED_TO_CONVERGE\n...report...","changedFiles":[...]}`

### REPORT (in the done-marker summary, structured Markdown)

- verdict (`PASS` / `FAILED_TO_CONVERGE`);
- per-cycle table: reviewers (task ids), findings count (BLOCKING/NON_BLOCKING),
  fixer batches/waves, commits cherry-picked, verify result;
- unresolved findings (id, location, first-seen cycle, repeated in);
- regressions (cycle, check name, exit code, revert sha);
- final verification evidence (each check: name, exit code, output tail).

## KNOWN SUSPECTS

- If the digest arrives without findings on disk for a reviewer that reported
  `done`, check `~/.pi/fleet/<id>.findings.json` was written by the reviewer
  (missing file = reviewer contract violation → treat as reviewer failure).
- `needs_input` from a fixer: steer with the missing context or abort and
  re-plan the batch; never silently skip its findings.
- `$H loop-next` returning `refused:"maxCycles"` (or `loop-final` returning
  `refused:"early-exit"`) is a BOUND, not a glitch: read the JSON, write the
  FAILED_TO_CONVERGE report (or continue the loop) exactly as the LOOP SEMANTICS
  section says. Never bypass the helper with a hand-written `.loop.json`.
- Frozen panes (T-019): if a reviewer/fixer pane hangs, the pane-health watchdog
  auto-steers ('abort command + commit WIP'), then kills and relaunches it from
  the last WIP commit; a relaunched task keeps its task id (`relaunches` record
  in `~/.pi/fleet/<id>.json`). Treat the wake `health: <id> relaunch` as a
  progress signal: re-read the state file and continue when the relaunched
  child delivers its result.