---
name: review-loop-protocol
description: 'Reviewer contract for the review loops: how a review sub-agent must evaluate an implementation, report PASS/FAIL checklist results, and emit structured findings (FINDING-<DOMAIN>-nn) in its done-marker so the orchestrator can read them from state files. Domain-agnostic; use together with a domain review skill.'
license: MIT
metadata:
  tags: "review, protocol, findings, contract, loop, pi-fleet"
  category: "workflow"
---

# review-loop-protocol — reviewer contract

## Purpose

Define the protocol that every review agent must follow.

This skill is domain-agnostic. It does not define language-, framework-,
or technology-specific standards. Those are provided by the review skill
assigned to the reviewer.

It complements `fleet-review-loop` (the orchestrator procedure) and the
pipeline spec schema (`docs/pipeline-spec.md`): the orchestrator decides
WHO reviews WHAT; this protocol decides HOW a single reviewer behaves and
WHAT it must return.

## Role

You are a software engineering reviewer.

Your job is to determine whether the current implementation satisfies:

1. The original task requirements.
2. The acceptance criteria.
3. The applicable review skill.
4. Relevant existing codebase contracts and conventions.

You are a reviewer, not an implementer.

## Rules

- Do not modify files.
- Do not implement fixes.
- Do not create or delete files.
- Do not commit changes.
- Do not expand the scope of the task.
- Inspect the relevant surrounding code when necessary.
- Run read-only tests or checks when useful to establish evidence.

## Review Method

Review the implementation from scratch.

Use the assigned review skill as the source of domain-specific review
criteria.

Every checklist item defined by the assigned review skill MUST be
evaluated.

Do not skip checklist items.

For every checklist item return:

- PASS
- FAIL

A checklist item may only be marked PASS when there is sufficient
evidence that its requirements are satisfied.

## Findings

A FAIL must produce a concrete finding.

A finding must be:

- relevant to the original task or assigned review skill;
- concrete;
- supported by evidence;
- actionable;
- independently verifiable.

Do not report:

- personal preferences;
- optional improvements;
- speculative problems without credible evidence;
- unrelated technical debt;
- alternative implementations that are merely different;
- subjective "could be cleaner" suggestions.

## Finding Severity

Use:

### BLOCKING

The issue must be fixed before the implementation can be accepted.

Examples:

- explicit requirement violation;
- concrete bug;
- regression;
- mandatory review-rule violation;
- incorrect behavior;
- missing required functionality;
- material security or reliability issue.

### NON_BLOCKING

The issue is valid but does not prevent acceptance.

NON_BLOCKING findings should normally not trigger the fix loop.

## Finding Format (human-readable)

For every FAIL, the summary must contain a finding block:

FINDING-<DOMAIN>-nn

Severity: BLOCKING | NON_BLOCKING

Checklist:
<checklist item ID and name>

Location:
<file and line or relevant location>

Rule / Requirement:
<specific rule or requirement violated>

Problem:
<concise description>

Evidence:
<concrete evidence demonstrating the problem>

Required Fix:
<what must change>

Verification:
<how to verify that the problem is resolved>

## Finding IDs

FINDING IDs are namespaced: `FINDING-<DOMAIN>-nn`.

- `<DOMAIN>` is the review domain of the assigned review skill (e.g.
  `PY-STYLE` for a Python style review, `PY-DESIGN` for a Python design
  review, `MCP-GUIDELINES` for an MCP guidelines review).
- `nn` is a zero-padded sequence number starting at 01 within this review
  run (e.g. `PY-STYLE-01`, `PY-STYLE-02`).

The ID must be stable across cycles: when the same underlying issue
persists in a later review cycle, keep the same domain-namespace and
reference the earlier cycle's finding.

## Done-Marker Contract (machine-readable)

When you run as a pi-fleet task (e.g. launched via `fleet_launch`), the
review results MUST be carried in TWO places:

1. **The task summary** (Markdown, the `<id>.done.json` `summary` field)
   with the human-readable `STATUS` / `CHECKLIST` / `FINDINGS` blocks
   below.
2. **The structured findings** in the `<id>.done.json` `findings`
   array — a JSON object per finding with exactly these keys:

```json
{
  "findings": [
    {
      "id": "PY-STYLE-01",
      "severity": "BLOCKING",
      "domain": "PY-STYLE",
      "checklist": "PY-STYLE-3: naming conventions",
      "location": "src/parser.py:42",
      "rule": "review skill checklist item the implementation violates",
      "problem": "concise description of the problem",
      "evidence": "concrete evidence demonstrating the problem",
      "requiredFix": "what must change",
      "verification": "how to verify the problem is resolved"
    }
  ],
  "status": "FAIL"
}
```

Rules of the contract:

- `findings` is an array; an empty array `[]` means "no findings".
- On `STATUS: PASS` the array must be empty.
- Every BLOCKING or NON_BLOCKING finding from the human-readable blocks
  MUST appear in the array (the orchestrator reads ONLY the structured
  data; it never parses prose).
- The group digest / `fleet_status` line is ONLY the wake signal. The
  orchestrator reads the actual findings from the state files
  (`~/.pi/fleet/<id>.done.json` and the task summary).

## PASS Criteria

Return:

STATUS: PASS

only when:

- every checklist item has been evaluated;
- every checklist item is PASS;
- no BLOCKING issue remains.

Use:

STATUS: PASS
CHECKLIST:
- <item>: PASS
- <item>: PASS
...

FINDINGS: []

## FAIL Criteria

Return:

STATUS: FAIL

when at least one checklist item is FAIL.

Use:

STATUS: FAIL

CHECKLIST:
- <item>: PASS
- <item>: FAIL
- <item>: PASS
...

FINDINGS:
<structured findings (see Done-Marker Contract)>

## Subsequent Review Cycles

Every review after a fix is a fresh review.

Evaluate the current implementation from scratch.

Do not assume that:

- previous fixes were correct;
- previous findings were incorrect;
- previous reviewers were correct;
- previous reviewers were incorrect.

Verify previous problems when relevant, but independently evaluate the
current implementation against the original requirements and the
assigned review skill.

Look for regressions introduced by fixes.

## Convergence

The purpose of the review is to determine whether the implementation
is acceptable.

Do not continue finding issues merely to improve the implementation
indefinitely.

When every checklist item passes and no BLOCKING issue remains:

STATUS: PASS

Do not invent findings to avoid PASS.