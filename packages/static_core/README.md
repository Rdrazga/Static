# `static_core`

Shared core contracts for the `static` workspace: error vocabulary,
configuration validation, build-option snapshots, and timeout-budget helpers.

## Current status

- The root workspace build is the supported entry point; package-local
  `zig build` is not supported.
- `static_core` is intentionally narrow and monitor-only unless a concrete
  boundary change appears.
- The package currently has direct regression coverage for config validation,
  error-tag round-tripping, build-option naming, and timeout-budget behavior.
- The current closure record lives in
  `docs/plans/completed/static_core_followup_closed_2026-03-31.md`.

## Main surfaces

- `src/root.zig` exports the package API.
- `src/core/errors.zig` owns the shared error vocabulary and classification
  helpers.
- `src/core/config.zig` owns config-validation helpers and lock-state guards.
- `src/core/options.zig` owns build-option snapshots and canonical option
  names.
- `src/core/time_budget.zig` owns the monotonic timeout-budget helper used by
  timed retry loops.

## Validation

- `zig build check`
- `zig build test`
- `zig build examples`
- `zig build docs-lint`

## Key paths

- `tests/integration/root.zig` wires the package-level regression surface.
- `tests/integration/root_surface_negative_contracts.zig` exercises the shared
  root surface against the package vocabulary.
- `examples/config_validate.zig` shows the minimal config-validation flow.
- `examples/errors_vocabulary.zig` shows the shared error vocabulary in use.
- `docs/plans/completed/static_core_followup_closed_2026-03-31.md` records the
  current boundary posture and reopen triggers.

## Artifact notes

- There is no package benchmark surface yet.
- If a future core helper becomes hot enough to justify benchmarking, keep the
  workload bounded and document the canonical artifact path here.
