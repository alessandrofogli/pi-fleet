# Pipeline Tickets — Markdown Format (converter input)

This document is the **source of truth** for the input format of the
pipeline **tickets markdown**, the document a pipeline is planned from
(planning/Phase 1 is manual). The deterministic converter
(`bin/fleet-pipeline-helper.sh convert`) projects such a ticket document
into a **pipeline spec** (YAML `pipeline.yaml` + JSON mirror
`pipeline.spec.json`) that follows the schema in
[`docs/pipeline-spec.md`](pipeline-spec.md) (T-014).

For how to run a pipeline end-to-end (tickets -> converter -> DAG waves
-> shippers -> hybrid integration -> checks -> review&fix loop), see
the "Review loop / pipeline" section in the README.

Relationship to the spec:

- Markdown (this format) is the **source of truth** — humans plan in
  markdown;
- `pipeline.yaml` / `pipeline.spec.json` are a **lossless projection** —
  the converter never rewrites the markdown, it only reads it;
- the machine schema (`schemas/pipeline-spec.schema.json`,
  `fleet-loop-helper.sh spec-validate`) is the mirror the projection is
  validated against: **unknown keys and cycles are invalid** and the
  converter refuses to emit an invalid projection.

## Document layout

```markdown
# <title>                                   optional single `# ` line (ignored)

## scope                                    REQUIRED — free-form text
<free text lines; the last `## ` heading ends the block>

## slice <id>                               one section per slice (>= 1)
title: <text>                              REQUIRED
impl_skills: <a, b, ...>                   comma list; omitted = []
review_skills: <a, b, ...>                 comma list; omitted = []
deps: <id1, id2, ...>                      comma list; omitted = []

## checks                                   optional — `name: cmd` lines
<name>: <shell command>
```

## Rules

- **Sections** start with `## ` and one of: `scope`, `slice <id>`,
  `checks`. Any other `## ` section is an error (unknown key).
  `# ` at the very start of the document is the optional title and is
  ignored by the projection.
- **Slice ids**: `^[a-z0-9][a-z0-9-]*$` (lowercase slug, same pattern as
  the machine schema); unique across the document; `deps` must reference
  existing slice ids and form a **DAG** (cycles are invalid — rejected
  during projection validation).
- **Slice fields**: exactly the schema keys `title`, `impl_skills`,
  `review_skills`, `deps`. Unknown fields are errors. `deps` is written
  in the tickets and is what drives the orchestrator waves
  (independent slices -> same parallel wave; a slice blocks its
  dependents -> next wave). List fields are comma-separated; leading/
  trailing whitespace and empty elements are trimmed; an omitted or
  empty list projects to `[]` (the projection always carries every
  schema-required key).
- **Checks**: each line is `name: cmd` — `name` (no whitespace, unique)
  followed by a colon and a shell command executed from the project
  root (exit 0 = pass, `gate-run.sh` semantics). An omitted `## checks`
  section projects to `checks: []`.
- **Comments**: a line starting with `<!--` is ignored everywhere
  (single-line HTML comments only).
- **Noise**: blank lines are ignored; `${var}` and other shell syntax
  in `cmd` values is NOT expanded by the converter — commands are
  projected verbatim and executed later by the verification phase.
- **Lossless projection**: every semantic bit of the markdown (scope
  text, ids, titles, skill lists, deps, checks) appears in the
  projection; the converter adds nothing and drops nothing (whitespace
  normalization only).

## Example

```markdown
# pipeline-sample tickets — shapes calculator (T-017)

## scope
Build a tiny shell library (lib, rectangle area and perimeter) and a CLI
wrapper (cli) that calls it. The pipeline may touch src/ and bin/ only.

## slice lib
title: Library — rectangle area/perimeter functions
impl_skills: shell-style
review_skills: sample-style-review
deps:

## slice cli
title: CLI wrapper over lib
impl_skills: shell-style
review_skills: sample-style-review
deps: lib

## checks
syntax: bash bin/check.sh syntax
```

Converted by:

```bash
bin/fleet-pipeline-helper.sh convert tickets.md \
  --out pipeline.yaml --json-out pipeline.spec.json
```

`cli` depends on `lib`, so the orchestrator spawns `lib` alone in wave 1
(no deps) and `cli` in wave 2 — deps written in the tickets, read by the
converter, honored by the wave executor.