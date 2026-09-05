---
name: fleet-ts-review
description: 'Reviewer contract for the pi-fleet EXTENSION and its TypeScript state machines: task state schema (TaskStateFile + gh-8 cleanup states), cleanup lifecycle (released|already_released|conflict|pending|failed), Treehouse-aware reconciliation (never auto-release active tasks), abort ownership, and the launcher cleanup-owner contract (bin/fleet-cleanup.sh). Use when reviewing pi-fleet lifecycle/state-machine changes or any gh-8 owner-safe worktree release work.'
license: MIT
metadata:
  tags: "pi-fleet, review, typescript, state-machine, lifecycle, cleanup, lease, worktree, gh-8, extension"
  category: "workflow"
---

# fleet-ts-review — extension/TypeScript state-machine & lifecycle review

## Purpose

Domain review skill for the pi-fleet **extension** (`extensions/index.ts` and
the modules it mounts) and the **launcher cleanup contract**
(`bin/fleet-cleanup.sh`, `bin/herdr-launch.sh` release paths). Use it whenever
a review must judge:

- the task state schema and its transitions (`TaskStateFile`),
- the gh-8 cleanup state machine (cleanup states, guarded return, idempotence),
- startup/restart reconciliation (Treehouse-aware, never auto-releasing active tasks),
- abort ownership (`fleet_abort` owning the cleanup or awaiting its durable ack),
- the artifact-bundle durability contract (scout report/findings/summary),
- or any change touching lease acquisition/release in the launcher.

It is the reviewer EXTENSION contract: it pairs with `review-loop-protocol`
(the domain-agnostic reviewer protocol) and `fleet-review-loop` (the
orchestrator). Domain-agnostic rules stay in `review-loop-protocol`; this skill
is pi-fleet-lifecycle specific.

## Scope

Fixes to review:

| Area | Files |
|---|---|
| Task state schema | `extensions/index.ts` (`TaskStateFile`, `CleanupRecord`, states) |
| Watcher / reconciliation | `extensions/index.ts` (`reconcileStaleTasks`, watcher cycle) |
| Abort ownership | `extensions/index.ts` (`fleet_abort`), abort marker handling |
| Launcher cleanup owner | `bin/fleet-cleanup.sh` (guards, idempotence, redaction) |
| Lease acquisition/release | `bin/herdr-launch.sh` (§2 acquisition, release paths, trap) |
| Artifact durability | `bin/herdr-launch.sh` (`persist_artifacts`/`persist_findings`/`persist_failure_result`) |
| Cleanup vocabulary | release + cleanup record schema (`<task-id>.cleanup.json`) |

complementing `bin/fleet-watch.sh` / `bin/fleet-relaunch.sh` (T-019 — out of
scope here unless the change touches lease custody).

## Reference model — the gh-8 lifecycle

Outcome and cleanup are **separate state machines** (issue #8 Phase 0):

- Task outcome: `spawning` → `running` → `done | failed | aborted`
  (`needs_input` is an interactive pause, not terminal). Only
  `done`, `failed`, `aborted` are terminal.
- Cleanup states: `unknown | pending | released | already_released | conflict | failed`
  (persisted in `<task-id>.cleanup.json` and mirrored in the task record
  `.cleanup`).

Cleanup invariants (every review must verify them):

1. **Owner guard**: release happens ONLY via `treehouse return --force
   --if-lease-id <persisted-id>` (preferred) or `--if-lease-holder
   'pi-fleet:<task-id>'` (fallback). NEVER an unguarded `--force`.
2. **No suppressed status**: the real exit status and output of the guarded
   return are captured and persisted (redacted, truncated). Pipes `|| true`
   that swallow the status are a FAIL.
3. **Idempotence**: repeated and concurrent calls converge on one durable
   record: matching live lease + successful return → `released`; no live lease
   at the exact identity (verified via `treehouse status --json`) →
   `already_released`; same path held by another identity → `conflict` (no
   return attempt); dirty/unreturnable → `pending`/`failed` with the reason.
4. **Active tasks are never auto-released**: `spawning|running|needs_input`
   must be excluded from reconciliation and from the owner (the owner refuses
   them). A signal-killed launcher marks the task failed BEFORE the shared
   cleanup owner runs, so the trap never releases an active task.
5. **Identity over path**: ownership matching uses the persisted lease id +
   exact holder, never `cwd`/path alone. A record without a persisted lease
   identity is flagged `pending` (operator review) — duplicate historical
   records sharing a path must never cause path-only cleanup.
6. **UI close before return**: pane/tab are closed before the guarded return
   (Treehouse process-termination ordering: return kills the processes in the
   worktree).
7. **Artifacts before release**: the done-marker payload is validated and
   persisted (`<id>.result.json` with the FULL original payload,
   `<id>.findings.json` with BLOCKING/NON_BLOCKING counts, `<id>.report.md`
   copy with size/sha256 metadata) BEFORE the transient marker is consumed and
   BEFORE any release. If artifact persistence fails → cleanup stays `pending`,
   do not claim successful task finalization.
8. **Durable ack**: `fleet_abort` records the intent (`.abort` marker), closes
   the UI, and either runs the shared owner itself or awaits its persisted
   acknowledgement — never claims `released` without the record.

## Checklist (all must pass for a PASS verdict)

### C1 — Task schema and cleanup vocabulary
- [ ] `TaskStateFile` carries the gh-8 identity fields: `worktreePath`
      (canonical persisted path), `leaseId` (from `treehouse get --json`),
      `leaseHolder` (`pi-fleet:<task-id>`), `leaseAcquiredAt`, `cleanup`
      (`CleanupRecord` with `lastResult` + append-only `attempts[]`).
- [ ] Cleanup attempts keep `guard`, `guardValue`, the REAL `exitStatus`
      (number or null — never swallowed), and redacted `output`.
- [ ] `spawning|running|needs_input` stay excluded from every
      auto-release decision.

### C2 — Shared cleanup owner (bin/fleet-cleanup.sh)
- [ ] Loads path + identity from the task record; rejects ambiguous records.
- [ ] Re-reads `treehouse status --json` immediately before any return; a
      missing/unparseable/malformed status is `pending` (retryable), never a
      verdict.
- [ ] Guarded return only (`--if-lease-id` preferred, `--if-lease-holder`
      fallback); exact-identity match required; otherwise `conflict`.
- [ ] Real exit status + redacted output persisted; `--classify-only` (report
      mode) never returns; per-task lock with stale takeover; every write is
      atomic (tmp + rename) so a crash leaves the previous valid record.

### C3 — Reconciliation (reconcileStaleTasks)
- [ ] Terminal tasks (+persisted identity) get the classification pass;
      default report-only (`--classify-only`), guarded release only under an
      explicit opt-in (`FLEET_RECONCILE_RELEASE=1` — Phase-7 gate).
- [ ] Active tasks are never released even when the pane is missing (the
      legacy zombie re-classification only changes the TASK outcome, never
      the lease).
- [ ] Duplicate/path-only/ambiguous records are flagged, never released.

### C4 — Abort ownership (fleet_abort)
- [ ] Durable abort intent written first; UI close; state → `aborted`
      (only from active states). Then the shared owner runs (or the durable
      record is awaited) BEFORE the tool claims release.
- [ ] The tool response carries the real cleanup result, never a bare claim.

### C5 — Launcher integration (bin/herdr-launch.sh)
- [ ] Acquisition persists the lease identity with the task record BEFORE
      child work begins; incomplete/ambiguous acquisition rejected.
- [ ] Every release path (done, abort, timeout, child crash, agent-start
      failure, early teardown, INT/TERM trap) goes through the shared owner;
      local ownership (WT_PATH) is dropped only on released/already_released.
- [ ] Signal trap marks failed first when the task is not terminal (so the
      owner never sees an active task).
- [ ] Scout durability: `report.md` is COPIED outside the worktree (a
      relative `reportPath` is a source location, not the artifact) with
      size/sha metadata; findings validated; the full done-marker payload
      preserved; transient marker consumed only after persistence.

### C6 — Failure injection and tests
- [ ] Fake treehouse/herdr adapters + isolated temp state are used (never a
      live pool); crash injection (kill mid-status / mid-return / after
      artifact persist) leaves recoverable records; concurrent
      abort+completion does not double-release.

## PASS / FAIL semantics

- **PASS** — every checklist item above passes AND the review-loop-protocol
  blocking rules hold: no unguarded release, no path-only cleanup, no active
  auto-release, artifacts durable before return.
- **FAIL** — any item fails. Severity rules:
  - BLOCKING: unguarded `treehouse return --force`; suppressed return status;
    active-task auto-release; path-only cleanup from duplicate records;
    transient marker consumed before artifact persistence; false
    `released` claims without a durable record.
  - NON_BLOCKING: missing redaction of tool output, incomplete metric
    logging, missing doc/comment updates.

## Done-Marker Contract

As a pi-fleet task, carry the review result in TWO places (per
`review-loop-protocol`):

1. **The task summary** (Markdown) with the `STATUS` / `CHECKLIST` / `FINDINGS`
   blocks — include per-check PASS/FAIL with file:line evidence.
2. **The structured `findings` array** in the done-marker, one object per
   finding with exactly: `id` (`FLEET-LIFE-01`, domain namespace
   `FLEET-LIFE`), `severity` (`BLOCKING|NON_BLOCKING`), `domain`,
   `checklist` (which C1–C6 item), `location` (file:line), `rule`, `problem`,
   `evidence`, `requiredFix`, `verification`.

Example:

```json
{
  "status": "FAIL",
  "findings": [
    {
      "id": "FLEET-LIFE-02",
      "severity": "BLOCKING",
      "domain": "FLEET-LIFE",
      "checklist": "C2: guarded return only",
      "location": "bin/fleet-cleanup.sh:42",
      "rule": "release must use --if-lease-id/--if-lease-holder, never an unguarded return",
      "problem": "the return path pipes the status away with `|| true`",
      "evidence": "line 42 `treehouse return \"$WT\" 2>&1 | sed ... || true`",
      "requiredFix": "capture rc+output, persist, return 0 only on released/already_released",
      "verification": "re-run the gh-8 cleanup smoke and check the cleanup record keeps the real exitStatus"
    }
  ]
}
```

On PASS the array must be empty.