# pipeline-orchestrator — brief template (T-017)

> **How to use.** This is the template for launching a NESTED orchestrator
> task that runs the implementation pipeline on a project, per the
> `pipeline-orchestrator` skill. The captain copies it, fills the
> `{{PLACEHOLDERS}}`, and launches with:
>
> ```
> fleet_launch
>   title:      pipeline <project-slug> <pipeline-id>
>   brief:      <this template, filled>                  # read from a file if long
>   project:    {{PROJECT}}                              # the IMPLEMENTED project (absolute path)
>   nested:     true                                     # REQUIRED: gives the child the fleet_* tools
>   worktree:   true
>   deliveryPosture: local-only                          # the pipeline never pushes
> ```
>
> The orchestrator spawns its OWN shipper waves with `fleet_launch`
> (`nested` only for the orchestrator — shippers are plain `ship` tasks).
> Preconditions: the project is a git repo; the tickets markdown exists
> (`{{TICKETS_MD}}`); the `impl_skills` referenced by the slices are
> resolvable by shipper sessions; `bin/fleet-pipeline-helper.sh` and the
> pipeline skills ship with pi-fleet at {{PI_FLEET_ROOT}}.

---

## OBJECTIVE

Act as the **pipeline orchestrator** for `{{TICKETS_MD}}` (project:
`{{PROJECT}}`). Run the 4 phases to an integrated, verified tree:

1. **Converter** — project the tickets markdown into the spec
   (`{{SPEC_PATH}}`) with `{{PI_FLEET_ROOT}}/bin/fleet-pipeline-helper.sh
   convert` (see `docs/pipeline-tickets.md` — markdown is the source of
   truth; the projection is validated: unknown keys/cycles invalid).
2. **DAG waves** — spawn one shipper per slice per wave (`waves` from
   the helper; deps are written in the tickets), barrier groups, ONE
   digest per wave.
3. **Integration** — hybrid helper plan (file-disjoint batches in
   parallel, shared files sequential), cherry-pick onto the effective
   branch, deterministic checks (`gate-run.sh` semantics, exit-0).
4. **Hook** — launch the review&fix loop (T-015, filled
   `fleet-loop-orchestrator.brief.md`) on the integrated tree.

Follow the **`pipeline-orchestrator`** skill. The skills are at
`{{PI_FLEET_ROOT}}/skills/`; the helper is
`{{PI_FLEET_ROOT}}/bin/fleet-pipeline-helper.sh`.

## PIPELINE SEMANTICS (non-negotiable)

1. **Deps are written in the tickets** (`deps` per slice). The
   orchestrator spawns IN ORDER: independent slices -> same parallel
   wave; a slice that blocks another -> next wave. No deps -> all in
   ONE wave. Each wave = one `fleet_launch` per slice (`kind: "ship"`,
   `worktree: true`, `deliveryPosture: "local-only"`), shared explicit
   `groupId` (`grp-{{PIPELINE_ID}}-w<k>`), `groupMode: "barrier"`,
   `groupFailPolicy: "waitAll"` -> exactly ONE group digest wakes you.
   `needs_input` breaks the barrier: answer via `fleet_steer` or abort
   the wave; never continue on a failed `needs_input` shipper.
2. **Shipper contract**: branch `fleet/<taskid>-<slug>` (isolated,
   NEVER the effective branch or main); **ONE COMMIT PER FILE**; only
   the slice's files, only inside the `scope`. Brief each shipper ONLY
   with its slice id/title, `impl_skills`, the original `scope` and the
   base commit.
3. **Integration — you are the ONLY committer on the effective branch**
   `fleet/pipeline-{{PIPELINE_ID}}`. Shippers run in shared-repo
   worktrees, so their branches are visible (`git branch --list
   'fleet/*'`). After each wave digest:
   ```
   H={{PI_FLEET_ROOT}}/bin/fleet-pipeline-helper.sh
   $H spec-validate {{SPEC_PATH}}                     # abort if invalid
   $H waves {{SPEC_PATH}}                             # ordering evidence
   # per shipper: files = git diff --name-only $(git merge-base origin/main <branch>) <branch>
   $H integrate {{SPEC_PATH}} shipper-status.json     # batches + waves
   ```
   `integrate` guarantees same-wave batches are file-disjoint (parallel
   ⇔ disjoint files, sequential ⇔ shared). Cherry-pick each batch in
   wave/batch order (preserving the per-file commits — no squash). On
   conflict: STOP the wave, report with the conflict diff (never
   force-resolve blindly).
4. **Verify after each wave** = run every `checks[].cmd` from the spec
   as `bash -c "<cmd>"` from the project root (exit 0 = pass —
   `gate-run.sh` semantics). Red -> `git revert` the wave's
   cherry-picks and record the regression; then fail/deliver the
   report. After the last wave: full re-verify on the final tree.
5. **Hook** — after the verified integrated tree:
   fill `{{PI_FLEET_ROOT}}/templates/fleet-loop-orchestrator.brief.md`
   (`{{PROJECT}}`, `SPEC_PATH` = `{{SPEC_PATH}}`, `PI_FLEET_ROOT`,
   `PIPELINE_ID` = `{{PIPELINE_ID}}`, `SCOPE` = the spec `scope`) and
   launch it `nested: true`, `worktree: true`,
   `deliveryPosture: "local-only"` — the review&fix loop (T-015) runs
   its 3 fixed cycles on the integrated tree. The loop's verdict and
   report are part of your final report.

## SCOPE

`{{SCOPE}}` — the spec `scope` field is the boundary. Shippers must not
expand it. Do not touch anything outside `{{PROJECT}}`.

## DELIVERY

- Effective branch `fleet/pipeline-{{PIPELINE_ID}}` in `{{PROJECT}}`
  (local only: NEVER push, NEVER open a PR — merge authority stays with
  the captain).
- Merge flag: `{{MERGE_FLAG}}` (launch-time opt-in, default
  `false` = PR-only). `true` -> merge the effective branch into `main`
  ONLY after the review&fix loop PASS on the green verified branch; it
  is NEVER automatic.
- Done-marker `~/.pi/fleet/<your-task-id>.done.json`:
  `{"status":"done","summary":"...REPORT...","changedFiles":[...]}`

### REPORT (in the done-marker summary, structured Markdown)

- converter: spec path, validation result (evidence: helper file:line);
- waves table: per DAG wave — shipper task ids, slice ids, digest
  result, integration plan (batches, waves, `disjoint`), commits
  cherry-picked, verify result (each check: name, exit code);
- conflicts / regressions (wave, check, exit, revert sha);
- review&fix loop hook: launch info, loop verdict;
- final state: effective branch head sha, `git status --porcelain`
  clean check.

## KNOWN SUSPECTS

- Shipper reported done without a branch/file set -> state file check
  (`~/.pi/fleet/<id>.*`); missing = contract violation -> treat as
  shipper failure.
- `integrate` output with `disjoint: false` should be impossible (the
  coloring guarantees it): treat as a helper bug, stop and report.
- The `review_skills` of the spec must be resolvable on the REVIEWED
  project by the loop's reviewer sessions.