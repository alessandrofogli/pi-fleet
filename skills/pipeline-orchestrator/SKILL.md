---
name: pipeline-orchestrator
description: 'Orchestrator procedure for the implementation pipeline (T-017): convert a pipeline ticket markdown into a spec, spawn shipper DAG waves (independent slices in parallel, one digest per wave), integrate shipper branches with the hybrid helper (file-disjoint -> parallel, shared files -> sequential, one commit per file preserved), verify with deterministic checks (gate-run.sh semantics), then hook the review&fix loop (T-015) on the integrated tree. Delivery: PR-only by default; merge is an explicit launch-time opt-in.'
license: MIT
metadata:
  tags: "pipeline, orchestrator, waves, shipper, dag, integration, hook, pi-fleet"
  category: "workflow"
---

# pipeline-orchestrator — implementation pipeline procedure

## Purpose

Run the full implementation loop given a **pipeline spec**: convert the
tickets markdown (source of truth) into the machine spec, execute the
shipper DAG as parallel waves, integrate the shipper results with the
hybrid helper, verify with deterministic checks, and finally hand the
integrated tree to the **review&fix loop** (T-015, `fleet-review-loop`
skill + `templates/fleet-loop-orchestrator.brief.md`).

Planning (Phase 1) stays manual: the tickets markdown
(`docs/pipeline-tickets.md` format) is written by the captain.

## Relationship to other components

- `docs/pipeline-tickets.md` — input format (source of truth).
- `docs/pipeline-spec.md` + `schemas/pipeline-spec.schema.json` — spec
  schema (scope, slices[{id,title,impl_skills,review_skills,deps}],
  checks[{name,cmd}]); **unknown keys / cycles invalid**.
- `bin/fleet-pipeline-helper.sh` — deterministic helper (converter,
  DAG waves, integration plan, spec-validate delegation).
- `bin/fleet-loop-helper.sh` — review-loop helper (spec-validate,
  findings dedup/group/partition).
- `skills/fleet-review-loop` + `templates/fleet-loop-orchestrator.brief.md`
  — the review&fix loop hooked at the end.
- `bin/gate-run.sh` — verify semantics: exit 0 = pass.

## Inputs

- Tickets markdown `<tickets.md>` (manual planning output).
- Project under implementation (absolute path).
- Optional launch flag `MERGE=true` — **explicit opt-in only** (never
  the default; see *Delivery flags*).

## Core Workflow (phases)

### Phase 1 — Plan (manual, outside this skill)

Captain writes the tickets markdown with slices, their `deps` (written
in the tickets) and their skills, plus the `checks`.

### Phase 2 — Convert (deterministic)

```bash
H=<pi-fleet>/bin/fleet-pipeline-helper.sh
$H convert <tickets.md> --out pipeline.yaml --json-out pipeline.spec.json
```

- The projection is validated inside `convert` (same rules as
  `fleet-loop-helper spec-validate`: unknown keys/cycles invalid).
- A valid projection MUST exist before any slice runs; an invalid one
  aborts the pipeline (the tickets need re-planning, never a silent
  rewrite).

### Phase 3 — Execute the DAG as waves

```bash
$H waves pipeline.spec.json     # {"waves":[["a","b"],["c"]],"order":[...]}
```

**Deps are WRITTEN IN THE TICKETS** (`deps` of each slice) and read by
the converter into the spec. The orchestrator spawns slices **in order**:

1. Wave k = slices whose deps are all resolved by the end of wave k-1
   (wave 1 = slices with no deps). No deps at all -> **ONE** wave with
   every slice.
2. Each wave = ONE `fleet_launch` **per slice** of the wave, `kind:
   "ship"`, `worktree: true`, `deliveryPosture: "local-only"`, project
   = the implemented project, **shared explicit `groupId`**
   (`grp-<pipeline-id>-w<k>`), `groupMode: "barrier"`,
   `groupFailPolicy: "waitAll"` -> **exactly ONE group digest** wakes
   the orchestrator per wave. Never spawn a dependent slice before its
   blocking slice's digest arrived.
3. `needs_input` breaks the barrier (immediate wake): answer via
   `fleet_steer` or abort the wave (`fleet_abort`); never continue on a
   failed `needs_input` shipper.
4. Shipper brief (per slice): slice `id`/`title`, `impl_skills`,
   original `scope` (the loop boundary), the base commit, and the
   contract below.

**Shipper contract** (non-negotiable):

- branch `fleet/<taskid>-<slug>` (their OWN isolated branch, never the
  effective branch, never main);
- **ONE COMMIT PER FILE** — every changed file is a separate commit,
  never one commit with all changes;
- unchanged files outside the slice's declared responsibility and
  outside `scope` are forbidden.

### Phase 4 — Integrate (hybrid) + verify (deterministic)

After each wave digest:

1. For every shipper task of the wave, derive its branch
   (`fleet/<taskid>-*` from its state) and its ACTUAL file set:
   `git -C <project> diff --name-only $(git merge-base origin/main <branch>) <branch>`
2. Build the shipper status and compute the integration plan:

```bash
$H integrate pipeline.spec.json shipper-status.json
# status: [{"slice":"<id>","branch":"fleet/<taskid>-<slug>","files":["rel/path",...]}]
# output: batches with waves — SAME-WAVE BATCHES ARE FILE-DISJOINT
#         (parallel ⇔ disjoint files, sequential ⇔ shared files)
```

3. Cherry-pick per batch in order (wave asc, then batch id asc): every
   commit of the batch's shipper branch onto the **effective branch**
   `fleet/pipeline-<pipeline-id>` (the orchestrator is the ONLY
   committer there; the per-file commits are preserved, never
   squashed). Disjoint batches may be integrated in any order — the
   wave coloring is only a deterministic order.
4. **On conflict: STOP the wave**, report the conflict diff, do NOT
   force-resolve blindly.
5. Verify = run every `checks[].cmd` from the spec as `bash -c "<cmd>"`
   from the project root on the effective branch (exit 0 = pass —
   `gate-run.sh` semantics). Red -> `git revert` the wave's
   cherry-picks (restore a green base), record the regression, and
   fail/deliver the report (a checker result is the evidence; a
   shipper's claim is not).

Then proceed to the next wave. After the LAST wave: full re-verify
(every check, on the final integrated tree).

### Phase 5 — Hook the review&fix loop (T-015)

After the integrated tree is verified, launch the review&fix loop on it:

- Fill `templates/fleet-loop-orchestrator.brief.md`:
  `{{PROJECT}}` = the project, `{{SPEC_PATH}}` = the generated
  `pipeline.spec.json`, `{{PI_FLEET_ROOT}}` = the pi-fleet root,
  `{{PIPELINE_ID}}` = the pipeline id, `{{SCOPE}}` = the spec scope;
- `fleet_launch` with `nested: true` (the loop orchestrator needs the
  fleet tools), `worktree: true`, `deliveryPosture: "local-only"`,
  project = the reviewed project.

The loop runs its 3 fixed cycles on the integrated tree; merge
authority stays with the captain (see *Delivery flags*).

## Delivery flags

- `merge` is a **launch-time flag, NOT a spec key** (the spec schema
  rejects unknown keys — `docs/pipeline-spec.md`). Default = **PR-only**
  (`autoPr`): the effective branch `fleet/pipeline-<pipeline-id>` is
  left local, verified and ready for the captain to open the PR. NEVER
  push, NEVER open a PR autonomously.
- `merge: true` = **explicit opt-in**: merge the effective branch into
  `main` **ONLY** when (a) the flag was explicitly requested in the
  brief AND (b) the review&fix loop returned PASS on the green,
  verified effective branch. Never automatic merge without opt-in.

## Report (in the done-marker summary, structured Markdown)

- branch + head sha of the effective branch; pipeline id;
- converter outcome (spec path, validation result, evidence file:line);
- waves table: per wave — shipper task ids, slice ids, digest result,
  integration plan batches/waves, commits cherry-picked, verify result;
- conflicts (wave, slices, files) and regressions (wave, check, exit);
- review&fix loop hook: task id + filled brief path;
- final verification evidence (each check: name, exit code, output
  tail).

## Known suspects

- A shipper that reports done without state: check `~/.pi/fleet/<id>`
  state files; a missing branch/file set = shipper contract violation.
- `integrate` returns `disjoint: false` (should never happen — the
  coloring guarantees it): treat as a helper bug, stop and report.
- The review-loop `sample-style-review`-like skills must be resolvable
  on the REVIEWED project (same mechanism pi-fleet itself uses).

## Core principle

Determinism first: the helper does ALL deterministic computation
(conversion, waves, integration order, validation); the orchestrator
only spawns, waits for digests, and commits on the effective branch.
Never hand-merge, never re-plan silently: the markdown is the source of
truth.