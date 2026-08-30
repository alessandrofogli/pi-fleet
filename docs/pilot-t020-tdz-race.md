# T-020 — TDZ race in `getFleetPosture()`: recon (WIP)

Status: recon findings only — committed before the fix (process WIP, per the
task brief). The delivery report (before/after proof, regression test result,
acceptance) lives in the task's `.done.json`.

## Symptom

Two `fleet_launch` calls in the same tick: the second crashes with

```
ReferenceError: Cannot access 'DEFAULT_NESTED_MAX_DEPTH' before initialization
```

(sibling observed: `Cannot access 'POSTURES' before initialization` at the
first T-014 launch). First observed in the T-018 pilot
(`docs/pilot-t018-e2e.md` Finder 2, `extensions/index.ts:47-51`).

## Root cause — CONFIRMED, runtime-sensitive

`extensions/index.ts` `getFleetPosture()` (pre-fix):

```ts
let _fleetPosture: typeof import("./fleet-posture.js") | null = null;
async function getFleetPosture() {
  if (_fleetPosture) return _fleetPosture;
  try { _fleetPosture = await import("./fleet-posture.js"); ... }
}
```

The module is cached only AFTER the `await import(...)` resolves. Two
concurrent callers (fleet_launch execute calls the getter twice:
line ~817 `getNestedMaxDepth()`, line ~845 `getPosture()`/`isValidPosture()`)
both see `_fleetPosture === null` and each fires its own `import()`.

- Plain Node ESM dedupes (module registry) → no crash reproducible there.
- pi's extension loader is **jiti**, not Node ESM:
  `core/extensions/loader.js:428` `const module = await jiti.import(extensionPath, { default: true })`.
  jiti re-instantiates the transpiled module per import; a second import while
  the first instance is mid-instantiation yields a namespace whose const bindings
  (`DEFAULT_NESTED_MAX_DEPTH`, `POSTURES`, ...) are still in TDZ. Dereferencing
  `.getNestedMaxDepth()` / `.getPosture()` / `.isValidPosture()` on it throws
  `Cannot access 'X' before initialization` OUTSIDE the getter's try/catch
  (the dereference happens in `execute()`), so the launch crashes.

Evidence (repro via the exact production loader, `jiti@2.7.0`, node v26.4.0,
`moduleCache:false` — /tmp/t020-repro/repro-jiti.mjs):

- BEFORE fix: two same-tick `fleet_launch` executes → launch 1 ok, launch 2
  REJECTED with the exact referenced error — 8/8 rounds, deterministic.
- AFTER fix (single-flight promise cache): 0 crashes in 8/8 rounds.

## Fix (chosen: promise cache in index.ts, minimal)

Single-flight: cache the in-flight `import()` **promise** (not the module), so
N concurrent callers await the SAME import. Fail-soft preserved: on rejection
the cache resets so the next caller starts a fresh cycle (same retry semantics
as the old code when the module was null).

- `extensions/index.ts` `getFleetPosture()` — the only change. fleet-posture.ts
  itself needs NO change: its consts are already initialized at module load
  (no top-level await, no circular imports) — the TDZ only arises from the
  duplicate instantiation, which the single-flight removes.
- Write path (`fleet_posture` set, `extensions/index.ts:1252`) uses the same
  getter → fixed by the same change.

## No-regression guard (T-013)

- `fleetToolsGate()` untouched: captain / nested-opt-in / mute semantics and the
  depth cap (`getNestedMaxDepth()` default 2) unchanged — the fix only changes
  HOW the posture module is loaded, not what it returns.
- Sibling lazy loaders (`getFleetGroup/Outcomes/Inbox/Bootstrap/Learn`) share
  the same latent pattern but are preloaded once at module scope and read via
  sync getters in hot paths; they never double-fetched in the field. Per the
  brief's "do not refactor more than needed", they are left untouched (flagged
  as a possible follow-up).

## Regression test (added)

`tests/smoke-nested.sh` scenario S7: two `fleet_launch` in the SAME tick with a
shared groupId → both resolve (no TDZ), both spawn, launcher invoked for both,
state files written; then both complete → barrier delivers EXACTLY ONE group
digest (first member buffered, no individual wake).

## Acceptance to verify

- `npx tsc --noEmit` clean.
- `bash tests/smoke-nested.sh` green (S1..S7).
- Same-tick jiti repro (before/after) — commands in the delivery report.