# `static_queues`

Bounded queues, channels, adapters, and queue-testing helpers for message
handoff.

## Current status

- The root workspace build is the supported entry point; package-local
  `zig build` is not supported.
- The package owns queue-family implementations for ring buffers, SPSC/MPSC/
  SPMC/MPMC variants, channels, broadcast/disruptor fanout, inbox/outbox,
  intrusive and locked queues, work-stealing deques, and a bounded priority
  queue.
- Package-owned deterministic coverage includes queue-family conformance,
  channel close/wait behavior, ring-buffer runtime sequences, intrusive detach
  and reuse, priority-queue index tracking, QoS MPMC receive fallback, and
  `WaitSet` channel-selection exploration.
- Throughput review workloads are admitted for `ring_buffer`, `spsc`, and
  `disruptor` on the shared benchmark workflow.
- The current closure posture and reopen triggers live in
  `docs/plans/completed/static_queues_followup_closed_2026-04-01.md`.

## Main surfaces

- `src/root.zig` exports the package API and the queue-family surface.
- `src/queues/` owns the concrete queue, channel, coordination, deque, and
  messaging implementations.
- `src/concepts/` owns the queue capability contracts.
- `src/adapters/` owns the type-erased adapters over those contracts.
- `src/testing/` owns package-local conformance and stress helpers.
- `tests/integration/` owns deterministic regression coverage and bounded
  exploration.
- `examples/` owns small bounded usage examples for the supported surfaces.
- `benchmarks/` owns the admitted throughput review workloads.

## Validation

- `zig build check`
- `zig build test`
- `zig build harness`
- `zig build examples`
- `zig build bench`
- `zig build docs-lint`

## Key paths

- `tests/integration/root.zig` wires the package-level deterministic
  regression suite.
- `src/testing/root.zig` wires package-owned conformance helpers.
- `benchmarks/support.zig` defines the shared benchmark workflow settings and
  output conventions.
- `benchmarks/ring_buffer_throughput.zig`
- `benchmarks/spsc_throughput.zig`
- `benchmarks/disruptor_throughput.zig`
- `examples/` contains the bounded usage examples that mirror the supported
  package surfaces.

## Benchmark artifacts

- Benchmark outputs live under `.zig-cache/static_queues/benchmarks/<name>/`.
- Canonical review artifacts stay on shared `baseline.zon` plus
  `history.binlog`.
- Re-record baselines when a benchmark workload or queue contract changes
  materially.
