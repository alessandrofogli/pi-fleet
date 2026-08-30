# pipeline-sample — fixture for the implementation pipeline (T-017)

A tiny, self-contained project used to exercise the pipeline machinery
end to end: a **tickets markdown** (source of truth) that the converter
projects into a pipeline spec, an implementation DAG of 2 slices with a
fake dependency, and a deterministic check that verifies the slice
outputs.

```
fixtures/pipeline-sample/
├── tickets.md                  tickets markdown: scope + 2 slices + 1 check
│                               (lib deps: [], cli deps: [lib] — the fake dep)
├── bin/
│   └── check.sh                the spec `checks` target (exit 0 = pass):
│                               bash -n on src/*.sh + slice-output markers
└── README.md                   this file
```

## What the pipeline must produce

- **Converter** — `bin/fleet-pipeline-helper.sh convert tickets.md` emits
  `pipeline.yaml` + `pipeline.spec.json` (valid projection, 2 slices,
  1 check).
- **DAG waves** — `helper waves` orders the slices by the deps written
  in the tickets: wave 1 = `lib` (no deps), wave 2 = `cli` (deps:
  `lib`) — blocking honored.
- **Integration** — after the shipper waves, the orchestrator cherry-
  picks the shipper branches (ONE COMMIT PER FILE preserved) onto the
  effective branch `fleet/pipeline-<id>` following the `integrate`
  plan (file-disjoint batches parallel, shared files sequential).
- **Verify** — `bash bin/check.sh syntax` exits 0 only when both slices
  shipped their `src/lib.sh` / `src/cli.sh` files (each carrying the
  `lib` / `cli` marker) with valid shell syntax.
- **Hook** — the orchestrator then launches the review&fix loop (T-015)
  on the integrated tree (see `skills/pipeline-orchestrator`).

## Usage

- Conversion (from the fixture dir):
  `bin/fleet-pipeline-helper.sh convert tickets.md --out pipeline.yaml --json-out pipeline.spec.json`
- Wave order: `bin/fleet-pipeline-helper.sh waves pipeline.spec.json`
- Integration plan (from a real shipper status):
  `bin/fleet-pipeline-helper.sh integrate pipeline.spec.json shipper-status.json`
- Spec validation: `bin/fleet-loop-helper.sh spec-validate pipeline.spec.json`

`tests/smoke-pipeline.sh` runs the FULL orchestrator semantics headlessly
on a scratch copy (mocked fleet layer, REAL git: per-file commits,
cherry-pick integration) — same isolation strategy as the T-015 loop
smoke.

## Determinism

The converter, wave ordering and integration plan are byte-deterministic
(stable sorts, no randomness), so the smoke can assert exact golden
outputs.