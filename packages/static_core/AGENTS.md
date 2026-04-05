# `static_core` package guide
Start here when you need to review, validate, or extend `static_core`.

## Source of truth

- `README.md` for the package entry point and commands.
- `src/root.zig` for the exported surface.
- `tests/integration/root.zig` for the package-level regression surface.
- `docs/plans/completed/static_core_followup_closed_2026-03-31.md` for the
  current closure posture and reopen triggers.
- `docs/plans/active/workspace_operations.md` for workspace priority and
  sequencing.
- `docs/architecture.md` for package boundaries and dependency direction.

## Supported commands

- `zig build check`
- `zig build test`
- `zig build examples`
- `zig build docs-lint`

## Working agreements

- Use the root `build.zig` as the supported validation surface.
- Keep `static_core` narrow: shared config, error vocabulary, build-option
  accessors, and timeout-budget helpers belong here; higher-level policy does
  not.
- Keep the package self-describing with direct tests and examples rather than
  broad shared harness expansion.
- Keep package guidance aligned with the root docs and update this file when
  the package boundary or supported workflow changes.

## Package map

- `src/root.zig`: package root exports for shared core contracts.
- `src/core/errors.zig`: canonical shared error vocabulary and classification.
- `src/core/config.zig`: configuration validation and lock-state guards.
- `src/core/options.zig`: build-option snapshot and named option accessors.
- `src/core/time_budget.zig`: monotonic timeout-budget helper for retry loops.
- `tests/integration/root.zig`: package-level regression entry point.
- `tests/integration/root_surface_negative_contracts.zig`: root-surface
  negative-contract coverage.
- `examples/config_validate.zig`: minimal config-validation usage example.
- `examples/errors_vocabulary.zig`: minimal shared-error vocabulary example.

## Change checklist

- Update `README.md`, `AGENTS.md`, and the relevant plan or closure record when
  package behavior or workflow changes.
- Extend `tests/integration/root.zig` when you add new first-class package
  regression coverage.
- Add or refresh package examples when a public surface needs a canonical usage
  path.
- Update root `README.md`, root `AGENTS.md`, and `docs/architecture.md` when
  package guidance or repository navigation changes.
