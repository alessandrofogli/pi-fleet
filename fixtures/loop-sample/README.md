# loop-sample — fixture for the review&fix loop (T-015)

A tiny, self-contained REVIEWABLE UNIT used to exercise the loop machinery
end to end: `pipeline.spec.json` (spec schema), a review skill with a
deterministic companion, functional `checks`, and a **planted-defect**
implementation that passes the functional checks but violates the style
checklist.

```
fixtures/loop-sample/
├── pipeline.spec.json        spec: scope, slices[].review_skills, checks (exit-0 cmds)
├── skills/sample-style-review/SKILL.md   review skill + checklist (SAMPLE-1..4)
├── bin/
│   ├── audit.sh              deterministic companion: re-runs the checklist on the
│   │                         CURRENT tree, emits findings (review-loop-protocol contract)
│   └── check.sh              functional checks (syntax, behavior) — the spec `checks`
└── src/
    ├── shapes.sh             PLANTED DEFECTS: no header comment, no set -u, a TODO,
    │                         two undocumented functions (5 BLOCKING findings in v1)
    └── utils.sh              clean (baseline)
```

## What the loop must produce

- **PASS** — the loop fixes the planted defects (one commit per file, on a
  verified effective branch `fleet/pipeline-<id>`), cycle-3 fresh review and
  the `checks` are all green.
- **FAILED_TO_CONVERGE** — if a defect cannot be resolved inside the loop
  (see the `no-converge` scenario in `tests/smoke-loop.sh`), after 3 fixed
  cycles the cycle-3 review still reports BLOCKING findings.

## Usage

- Deterministic review (what a reviewer would run as evidence):
  `bash bin/audit.sh` → findings array on stdout.
- Functional checks (the spec `checks`):
  `bash bin/check.sh syntax` / `bash bin/check.sh behavior` (exit 0 = pass).
- Spec validation: `bin/fleet-loop-helper.sh spec-validate pipeline.spec.json`
- Live loop: the captain launches the orchestrator with the filled
  `templates/fleet-loop-orchestrator.brief.md` (see `docs/review-loop.md`).
  Precondition for a live run: this fixture must be a standalone git repo
  (copy it; it runs in its own worktree). `tests/smoke-loop.sh` runs the
  SAME semantics headlessly on a scratch copy — no herdr/pane needed.

## Determinism

`audit.sh` emits stable finding ids that keep their identity across cycles
(`FINDING-SAMPLE-01` … `04` at stable locations), so the loop can track
"repeated findings" and the helper (dedup by id+location) behaves exactly as
it does against real reviewers.