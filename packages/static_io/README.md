# `static_io`

Deterministic bounded I/O runtime pieces, backend selection, and buffer-pool integration.

## Current status

- The root workspace build is the supported entry point; package-local `zig build`
  is not supported.
- `static_io` now uses shared `static_testing` surfaces for deterministic
  `testing.system`, `testing.process_driver`, `testing.sim`,
  `testing.fuzz_runner`, temporal checks, retained failure bundles, and
  benchmark baseline/history review.
- Package-level integration coverage now includes retry, partial completion,
  cancellation recovery, buffer exhaustion, Windows loopback backends,
  deterministic process-boundary flows, and bounded seeded fuzz sequences.
- Canonical package benchmarks now cover:
  buffer checkout/return,
  full-capacity buffer churn,
  submit/complete roundtrip,
  and timeout-plus-retry roundtrip recovery.

## Main surfaces

- `src/root.zig` exports the package API.
- `src/io/runtime.zig` owns the bounded runtime, operation submission, polling,
  cancellation, timeout, and backend coordination contracts.
- `src/io/buffer_pool.zig` owns reusable bounded buffer lifecycle and
  exhaustion/release behavior.
- `src/io/fake_backend.zig`, `src/io/threaded_backend.zig`, and
  `src/io/platform/` own backend implementations and host-specific shims.

## Validation

- `zig build check`
- `zig build check -Denable_os_backends=true`
- `zig build test`
- `zig build test -Denable_os_backends=true`
- `zig build bench`
- `zig build examples`
- `zig build docs-lint`

## Key paths

- `tests/integration/root.zig` wires the package-level deterministic
  integration suite.
- `tests/integration/support.zig` holds the small package-owned helpers shared
  by runtime-centric system tests.
- `benchmarks/` holds the canonical shared-workflow benchmark entry points.
- `examples/` holds bounded usage examples; examples are not the canonical
  regression surface.
- `docs/plans/active/packages/static_io.md` tracks the package work queue.

## Benchmark artifacts

- Benchmark outputs live under `.zig-cache/static_io/benchmarks/<name>/`.
- Canonical review artifacts stay on shared `baseline.zon` plus
  `history.binlog`.
- Re-record baselines when a benchmark workload changes materially.
