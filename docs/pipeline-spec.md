# Pipeline Spec Schema

This document is the **source of truth** for the pipeline spec schema
used by the review loops (`fleet-review-loop` skill) and the future loop
machinery (T-015). This is a documentation-only schema: the Markdown
below defines the fields; no machine schema file exists yet.

A pipeline spec describes ONE reviewable unit of work: its scope, the
slices it is split into (each with implementation and review skills),
and the deterministic checks that verify it.

## Top-level keys

| Key     | Type     | Required | Description |
|---------|----------|----------|-------------|
| `scope` | string   | yes      | Free-form description of the work covered by the pipeline: the ticket/objective, the acceptance target, and the boundary of what the loop may touch. Defines the scope control boundary for reviewers and fixers. |
| `slices`| array    | yes      | Ordered list of slices (see below). At least one slice. Each slice runs **after** all of its `deps` have completed. |
| `checks`| array    | yes      | Deterministic checks (see below). May be empty (`checks: []`) when the project has no applicable checks. |

## `slices[]` entries

| Field           | Type    | Required | Description |
|-----------------|---------|----------|-------------|
| `id`            | string  | yes      | Unique, stable, lowercase slug identifying the slice (e.g. `py-core`). Referenced by other slices via `deps`. |
| `title`         | string  | yes      | Short human-readable title (e.g. "Python core implementation"). |
| `impl_skills`   | array   | yes      | Skill names that guide/constrain the implementation of this slice (e.g. `python-style`, `mcp-guidelines`). May be empty. |
| `review_skills` | array   | yes      | Review skill names that MUST be evaluated for this slice. Each entry maps to one reviewer (one reviewer per review skill). A non-empty list is expected; the loop must never silently skip a configured review skill. |
| `deps`          | array   | yes      | Slice `id`s that must be completed before this slice starts. May be empty (`deps: []`). Must reference valid slice ids; cycles are invalid. |

The review domain used for FINDING IDs (`FINDING-<DOMAIN>-nn`,
see the `review-loop-protocol` skill) is derived from each
`review_skills` entry (e.g. `python-style-review` → `PY-STYLE`).

## `checks[]` entries

| Field  | Type   | Required | Description |
|--------|--------|----------|-------------|
| `name` | string | yes      | Short unique identifier (e.g. `typecheck`, `test`, `lint`). |
| `cmd`  | string | yes      | Shell command to run from the project root. Exit code 0 = pass; any non-zero exit = fail. |

Checks run after fixes (deterministic verification phase of the loop)
and may run after implementation of each slice. A fix agent's claim of
success is not sufficient by itself — the check output is the evidence.

## Example

```yaml
scope: >
  port the legacy analyzer to a library API with typed inputs/outputs,
  wire it through the existing CLI, and keep the smoke suite green.
  The loop may touch src/, bin/ and tests/ only.

slices:
  - id: lib-core
    title: Core library API
    impl_skills: [python-style, python-typing]
    review_skills: [python-style-review, python-design-review]
    deps: []
  - id: cli-wiring
    title: CLI wiring
    impl_skills: [python-style, mcp-guidelines]
    review_skills: [mcp-guidelines-review]
    deps: [lib-core]

checks:
  - { name: typecheck, cmd: "npx tsc --noEmit" }
  - { name: test,      cmd: "npm test" }
  - { name: lint,      cmd: "npm run lint" }
```

## Rules

- Markdown here is the source of truth; any future machine schema
  (JSON Schema / TS types) must be generated from or validated against
  this document, not the other way around.
- Slices are a DAG: `deps` may form a chain (sequential slices) or
  branches (parallelizable slices). The loop executes a slice only
  after all of its `deps` are done.
- `checks` apply to the whole pipeline; a slice does not declare its
  own individual checks at this stage.
- Unknown keys are rejected by the future machinery; every key above is
  required at its level (no optional keys in the current revision).