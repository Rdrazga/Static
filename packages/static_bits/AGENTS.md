# `static_bits` package guide
Start here when you need to review, validate, or extend `static_bits`.

## Source of truth

- `README.md` for the package entry point and surface summary.
- `src/root.zig` for the exported API surface.
- `tests/integration/root.zig` for package-level deterministic runtime coverage.
- `tests/compile_fail/` for comptime misuse and boundary proofs.
- `benchmarks/` for canonical benchmark entry points and artifact names.
- `docs/plans/completed/static_bits_review_2026-03-20.md` for the review record.
- `docs/plans/completed/static_bits_followup_closed_2026-03-23.md` for the
  closure posture and reopen triggers.
- `docs/plans/active/workspace_operations.md` for workspace priority and
  sequencing.
- `docs/architecture.md` for package boundaries and dependency direction.

## Supported commands

- `zig build test`
- `zig build examples`
- `zig build bench`
- `zig build docs-lint`

Command intent:

- Keep `zig build test` as the primary pass/fail surface for unit, compile-fail,
  and deterministic integration coverage.
- Keep `zig build examples` for usage demos and self-checking package samples.
- Treat `zig build bench` as review-only unless a benchmark workflow explicitly
  opts into gating.
- Use `zig build docs-lint` to keep package docs and cross-links mechanically
  aligned with the workspace source of truth.

## Working agreements

- Use the root `build.zig` as the supported validation surface.
- Keep `static_bits` narrow: primitive mechanics over caller-owned memory.
- Keep compile-time misuse checks package-local and explicit instead of hiding
  them behind shared runtime harnesses.
- Prefer shared `static_testing` surfaces for replay, fuzz, retained failures,
  and benchmark workflow plumbing.
- Keep benchmark review artifacts on shared `baseline.zon` plus `history.binlog`
  rather than inventing package-local artifact formats.
- Keep examples as usage demonstrations, not the canonical regression surface.

## Package map

- `src/bits/endian.zig`: endian-safe integer loads and stores.
- `src/bits/cast.zig`: checked integer casts.
- `src/bits/cursor.zig`: bounded byte and bit readers, writers, and checkpoints.
- `src/bits/varint.zig`: canonical LEB128 encode and decode helpers.
- `src/bits/bitfield.zig`: bit-range extraction and packing utilities.
- `tests/compile_fail/`: comptime invalid-shape coverage for the public API.
- `tests/integration/`: deterministic runtime replay and fuzz coverage.
- `examples/`: usage examples for the public surfaces.
- `benchmarks/`: cursor, endian, and varint roundtrip review workloads.

## Change checklist

- Update `README.md`, `AGENTS.md`, and the relevant completed plan record when
  package behavior or workflow changes.
- Extend `tests/integration/root.zig` when you add a new first-class runtime
  regression surface.
- Extend `tests/compile_fail/` when you add a new compile-time contract
  boundary.
- Re-record benchmark baselines when workload sizes or semantics change.
- Update root `README.md`, root `AGENTS.md`, and `docs/architecture.md` when
  package guidance or repository navigation changes.
