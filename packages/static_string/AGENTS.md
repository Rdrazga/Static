# `static_string` package guide
Start here when you need to review, validate, or extend `static_string`.

## Source of truth

- `README.md` for the package entry point and surface summary.
- `src/root.zig` for the exported API surface.
- `tests/integration/root.zig` for the package-level deterministic regression
  surface.
- `benchmarks/` for canonical benchmark entry points and artifact names.
- `examples/` for bounded usage examples.
- `docs/plans/completed/static_string_review_2026-03-21.md` for the review
  record.
- `docs/plans/completed/static_string_followup_closed_2026-03-23.md` for the
  current closure posture and reopen triggers.
- `docs/plans/active/workspace_operations.md` for workspace priority and
  sequencing.
- `docs/architecture.md` for package boundaries and dependency direction.

## Supported commands

- `zig build check`
- `zig build test`
- `zig build bench`
- `zig build examples`
- `zig build docs-lint`

## Working agreements

- Use the root `build.zig` as the supported validation surface.
- Keep `static_string` centered on bounded text storage, explicit encoding
  policy, and deterministic interning.
- Prefer shared `static_testing` surfaces for replay, fuzz, retained failures,
  and benchmark workflow plumbing.
- Keep examples as usage demonstrations, not the canonical regression surface.
- Keep benchmark review artifacts on shared `baseline.zon` plus `history.binlog`
  rather than inventing package-local artifact formats.

## Package map

- `src/string/bounded_buffer.zig`: fixed-capacity append buffer behavior.
- `src/string/utf8.zig`: explicit UTF-8 validation helpers.
- `src/string/ascii.zig`: ASCII-focused helpers and normalization.
- `src/string/intern_pool.zig`: deterministic bounded interning and symbol
  lookup.
- `tests/integration/`: malformed-text replay/fuzz and sequence-sensitive
  intern-pool coverage.
- `benchmarks/`: text-validation and interning review workloads.
- `examples/`: bounded usage examples for the exported text surfaces.

## Change checklist

- Update `README.md`, `AGENTS.md`, and the relevant completed plan record when
  package behavior or workflow changes.
- Extend `tests/integration/root.zig` when you add a new first-class runtime
  regression surface.
- Add or refresh an example when a public surface needs a canonical usage
  path.
- Re-record benchmark baselines when workload sizes or semantics change.
- Update root `README.md`, root `AGENTS.md`, and `docs/architecture.md` when
  package guidance or repository navigation changes.
