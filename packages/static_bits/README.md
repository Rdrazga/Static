# `static_bits`

Allocation-free bit and byte primitives for the `static` workspace.

## Current status

- The root workspace build is the supported validation entry point; package
  behavior is exercised through the workspace, not ad hoc local workflows.
- `static_bits` owns the primitive mechanics for endian loads/stores, checked
  integer casts, byte and bit cursors, canonical LEB128 helpers, and bitfield
  packing.
- Compile-fail misuse checks stay package-local and explicit.
- Deterministic runtime replay/fuzz coverage lives in `tests/integration/` and
  uses shared `static_testing` surfaces.
- Canonical benchmark review now covers cursor/endian and cursor-based varint
  roundtrips through shared `bench.workflow` artifacts.

## Main surfaces

- `src/root.zig` exports the package API.
- `src/bits/endian.zig` owns endian-safe integer loads and stores.
- `src/bits/cast.zig` owns checked integer conversion helpers.
- `src/bits/cursor.zig` owns byte and bit readers, writers, and checkpoints.
- `src/bits/varint.zig` owns canonical signed and unsigned LEB128 helpers.
- `src/bits/bitfield.zig` owns bit extraction and packing helpers.

## Validation

- `zig build test`
- `zig build examples`
- `zig build bench`
- `zig build docs-lint`

Command intent:

- `zig build test` covers unit tests, compile-fail fixtures, and the retained
  malformed-runtime integration surface.
- `zig build examples` keeps the package examples compiling and running as
  usage demos.
- `zig build bench` is review-only by default and reports against the shared
  benchmark history artifacts.

## Key paths

- `tests/integration/root.zig` wires the deterministic malformed-runtime and
  retained replay coverage.
- `tests/integration/replay_fuzz_malformed_runtime.zig` holds the package's
  shared `static_testing` replay/fuzz proof.
- `tests/compile_fail/` holds comptime misuse fixtures for the public API
  boundary.
- `benchmarks/support.zig` holds the shared benchmark reporting helpers.
- `benchmarks/byte_cursor_u32le_roundtrip.zig` and
  `benchmarks/varint_cursor_roundtrip.zig` are the canonical review workloads.
- `examples/` holds bounded usage samples for each public surface.
- `docs/plans/completed/static_bits_review_2026-03-20.md` records the review
  pass that established the current package posture.
- `docs/plans/completed/static_bits_followup_closed_2026-03-23.md` records the
  closure posture and reopen triggers.

## Benchmark artifacts

- Benchmark outputs live under `.zig-cache/static_bits/benchmarks/<name>/`.
- Canonical review artifacts stay on shared `baseline.zon` plus
  `history.binlog`.
- Re-record baselines when a benchmark workload changes materially or the
  semantic contract moves.
