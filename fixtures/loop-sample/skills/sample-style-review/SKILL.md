---
name: sample-style-review
description: 'Fixture review skill for the loop-sample project (T-015): checklist for minimal, documented, safe shell scripts. Minimal but real review domain: header comment, shebang + set -u, no TODO/FIXME markers, documented functions. The deterministic companion bin/audit.sh implements exactly this checklist, so any reviewer can use it as objective evidence.'
license: MIT
metadata:
  tags: "review, shell, style, checklist, fixture, pi-fleet"
  category: "review"
---

# sample-style-review — fixture review checklist

Evaluate EVERY script under `src/` of the reviewed project. Every checklist
item MUST be evaluated; mark PASS only with concrete evidence.

## Checklist

- **SAMPLE-1 — header comment**: the script starts (right after the shebang,
  skipping blank lines) with a `#` comment describing its purpose.
  Evidence: first non-empty line after the shebang starts with `# `.
- **SAMPLE-2 — shebang + set -u**: the file starts with the
  `#!/usr/bin/env bash` shebang AND contains an unconditional `set -u`
  (or `set -eu`) before the first command.
- **SAMPLE-3 — no TODO/FIXME markers**: no line contains `TODO` or `FIXME`.
- **SAMPLE-4 — documented functions**: every function definition
  (`name() {`) is immediately preceded (no blank line between) by a one-line
  `#` comment describing what it does.

## Domain

The review domain for FINDING IDs is `SAMPLE` →
`FINDING-SAMPLE-nn` (see review-loop-protocol). Findings emitted by
`bin/audit.sh` use stable ids (`FINDING-SAMPLE-01` … `FINDING-SAMPLE-04`):
the same underlying issue keeps the same id across cycles.

## Deterministic companion

`bash bin/audit.sh` re-runs this checklist programmatically on the current
tree and emits the findings array in the review-loop-protocol machine
contract — reviewers may run it as evidence (the final verdict is still
theirs; audit is a tool, not a replacement for the review).