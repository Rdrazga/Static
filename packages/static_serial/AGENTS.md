# `static_serial` package guide
Start here when you need to review, validate, or extend `static_serial`.

## Source of truth

- `README.md` for the package entry point and surface summary.
- `src/root.zig` for the exported API surface.
- `tests/integration/root.zig` for package-level deterministic coverage.
- `benchmarks/` for canonical benchmark entry points and artifact names.
- `docs/plans/completed/static_serial_review_2026-03-20.md` for the review
  record.
- `docs/plans/completed/static_serial_followup_closed_2026-03-23.md` for the
  closure posture and reopen triggers.
- `docs/plans/active/workspace_operations.md` for workspace priority and
  sequencing.
- `docs/architecture.md` for package boundaries and dependency direction.

## Supported commands

- `zig build check`
- `zig build test`
- `zig build examples`
- `zig build bench`
- `zig build docs-lint`

## Working agreements

- Use the root `build.zig` as the supported validation surface.
- Keep `static_serial` focused on structured wire-format helpers, not on
  transport, runtime, or socket ownership.
- Keep reader, writer, varint, zigzag, checksum, and view behavior aligned
  with `static_bits` primitives rather than duplicating low-level byte utilities.
- Prefer shared `static_testing` surfaces for malformed-frame replay, model
  coverage, and benchmark workflow plumbing.
- Keep benchmark review artifacts on shared `baseline.zon` plus
  `history.binlog` rather than inventing package-local artifact formats.
- Keep examples as usage demonstrations, not the canonical regression surface.

## Package map

- `src/root.zig` exports the package API.
- `src/serial/errors.zig` owns structured serialization error vocabulary.
- `src/serial/reader.zig` owns bounded decode helpers.
- `src/serial/writer.zig` owns bounded encode helpers.
- `src/serial/varint.zig` owns framed varint helpers.
- `src/serial/zigzag.zig` owns signed varint encoding helpers.
- `src/serial/checksum.zig` owns framed checksum helpers.
- `src/serial/view.zig` owns frame views and borrowed decode surfaces.
- `tests/integration/` owns deterministic malformed-frame and incremental
  framing coverage.
- `examples/` owns usage examples for roundtrips and frame parsing.
- `benchmarks/` owns the canonical shared-workflow benchmark entry points.

## Change checklist

- Update `README.md`, `AGENTS.md`, and the relevant completed plan record when
  package behavior or workflow changes.
- Extend `tests/integration/root.zig` when you add a new first-class package
  regression surface.
- Add or refresh examples when a public surface needs a canonical usage path.
- Re-record benchmark baselines when workload sizes or semantics change.
- Update root `README.md`, root `AGENTS.md`, and `docs/architecture.md` when
  package guidance or repository navigation changes.
