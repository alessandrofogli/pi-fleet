---
name: fleet-bash-review
description: 'Review checklist for bash / launcher code in pi-fleet (bin/*.sh, tests/*.sh, skills). Run when reviewing or auditing shell scripts: pipefail and exit-code discipline, quoting/array safety, never-suppressed errors, atomic file operations, no eval, guarded treehouse/herdr operations, bounded loops, and the gh-7 native-initial-request delivery semantics. Emit structured findings (FINDING-BASH-nn) per the review-loop-protocol contract.'
license: MIT
metadata:
  tags: "review, bash, shell, launcher, hardening, pi-fleet"
  category: "workflow"
---

# fleet-bash-review — bash/launcher review checklist

## Purpose

Deterministic, evidence-backed review of shell scripts in pi-fleet (launcher,
watchers, helpers, smokes) before merge. The reviewer runs the checklist below
against the modified scripts, reports PASS/FAIL per item with file:line
evidence, and emits structured findings via the `review-loop-protocol` contract
(`FINDING-BASH-nn` in the done-marker). Read the target scripts FIRST — never
review from memory of the diff.

## Non-negotiable invariants

1. **Explicit shell strictness.** Every *executable* script must have at least
   `set -u` (`set -euo pipefail` where the script's semantics allow; scripts
   that intentionally continue after failed probes must justify the deviation).
   Verbose `eval`, bare `$@`-re-splitting, and `set +e` regions require a comment
   explaining the exact race they handle.
   - PASS if: `set -u` (or stronger) is present and every variable read is
     either set or defaulted (`${VAR:-}`).
   - FAIL if: a script reads `$VAR` without default under `set -u`, or a
     function modifies a global that a caller reads unsafely.

2. **Quoting/array safety.** Every expansion that can carry spaces or
   metacharacters (paths, briefs, argv, JSON) must be double-quoted; multi-part
   argv must be built with arrays, never by string concatenation; `@`-file
   arguments and paths like `$STATE_HOME/<id>.child-prompt.md` must survive as
   ONE element (spaces, `$`, backticks, quotes, `;` inside).
   - PASS if: `herdr_cli agent start ... -- "${MODEL_ARGS[@]}" "@$CHILD_PROMPT_PATH"`;
     no `$*`/unquoted `$@` forwarding of payloads; no `eval` of user data.
   - FAIL if: `eval "$BRIEF"`, unquoted `$PANE_ID`, `agent start $ARGS` (word
     splitting), or a case where a path with spaces would split.

3. **Never-suppressed errors.** `|| true`, `2>/dev/null`, and `&&`-chains must
   not hide a failure that changes the task outcome. Distinguish:
   - acceptable: idempotent teardown (`close_tab; release_worktree` best-effort),
     probes that must not fail the run, cleanup of possibly-missing files
     (`rm -f ... 2>/dev/null || true`).
   - FAIL: a state write (`jq ... > tmp && mv tmp json`), the prompt-file
     install, or the done-marker consume where the error is swallowed and the
     script claims success anyway. `fail_task` must be reachable from every
     new failure path.

4. **Atomic file operations.** Temp sibling + `mv` for every state/prompt write;
   `umask 077` for private payloads (the child-prompt file); verify AFTER the
   move (`-f/-s/-r`) before the file is consumed; never a half-written file
   observable by the watcher.
   - PASS if: `( umask 077; printf ... > "$X.tmp.$$" ) && mv "$X.tmp.$$" "$X"`,
     with a guard `[[ ! -f "$X" || ! -s "$X" || ! -r "$X" ]]` before use.
   - FAIL if: `> "$X"` direct on a live path, or a write whose failure is
     ignored while the script continues to consume `$X`.

5. **No `eval`.** `eval` on constructed strings (knobs, paths, JSON) is a code-
   injection foot-gun; replace with arrays/indirection or `${!name}` patterns.
   A remaining `eval` requires an explicit justification and a test covering it.

6. **Guarded treehouse/herdr operations.** `treehouse get --lease ...` must be
   paired with `treehouse return` on EVERY exit path (success, failure, abort,
   signal); pane/tab close must not be skipped when the agent fails; the lease
   holder must be the task id; no `treehouse`/`herdr` op may run unguarded on a
   path outside the task's own scope.

7. **Bounded loops / no silent hangs.** Every loop with external side effects
   (retries, polls, waits) needs an explicit bound (count × sleep, deadline);
   recursive finds and jq pipes need a depth bound; no unbounded `while true`
   without a deadline check inside.

8. **gh-7 native-initial-request semantics** (when the launcher is in scope):
   - the complete CHILD_PROMPT is materialized BEFORE `agent start`;
   - exactly ONE `@<prompt-file>` argv element after `--`, separate from the
     `--model provider/id` pair;
   - NO `agent prompt`, NO readiness/`interactive_ready` wait, NO ACK retry, NO
     fallback delivery — delivery is `agent start` returning OK;
   - the transient prompt file is removed on every terminal path (EXIT trap)
     and reclaimed per task id for SIGKILL leftovers; durable brief files are
     NEVER removed;
   - `--resume` rebuilds the prompt file (never reuses a deleted one, never a
     second manual prompt).

## Reporting

Return a checklist table (`PASS`/`FAIL` per invariant group with `file:line`
evidence) plus structured findings `FINDING-BASH-nn` (one per real defect, with
a concrete fix suggestion and the test that should cover it). A script that has
any FAIL item is NOT reviewable-green, even if the tests pass: the checklist is
the gate, test green is supporting evidence only.

## Usage

```text
Use this skill when the captain asks for a review of launcher/watch/smoke bash,
or when a review-loop passes a bash-domain ticket. Pair with
review-loop-protocol (finding format) — this skill is the domain-specific
checklist.
```