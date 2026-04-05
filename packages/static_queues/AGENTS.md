# `static_queues` package guide
Start here when you need to review, validate, or extend `static_queues`.

## Source of truth

- `README.md` for the package entry point and commands.
- `src/root.zig` for the exported surface.
- `src/testing/root.zig` for the package-owned queue-testing helpers.
- `tests/integration/root.zig` for the package-level deterministic regression surface.
- `benchmarks/` for canonical throughput benchmark entry points and artifact names.
- `docs/plans/completed/static_queues_followup_closed_2026-04-01.md` for the
  current closure posture and reopen triggers.
- `docs/plans/active/workspace_operations.md` for workspace priority and sequencing.
- `docs/architecture.md` for package boundaries and dependency direction.

## Supported commands

- `zig build check`
- `zig build test`
- `zig build harness`
- `zig build examples`
- `zig build bench`
- `zig build docs-lint`

## Working agreements

- Use the root `build.zig` as the supported validation surface.
- Keep queue-family ownership package-local: queue semantics, adapters,
  coordination, and examples should stay here rather than moving into shared
  helpers unless another package can reuse the contract.
- Prefer shared `static_testing` workflows over ad hoc harness code:
  `testing.model`, `testing.sim.explore`, `testing.temporal`, and retained
  replay or failure bundles when the invariant needs them.
- Keep lock-free and blocking paths deterministic in tests and benchmarks.
- Keep benchmark artifacts on shared `baseline.zon` plus `history.binlog`; do
  not introduce package-local benchmark formats.

## Package map

- `src/queues/`: queue families, channels, broadcasting, inbox/outbox,
  coordination, and work-stealing deque implementations.
- `src/concepts/`: lightweight traits and capability contracts used by queue
  families.
- `src/adapters/`: type-erased adapters and helpers over queue contracts.
- `src/testing/`: package-owned conformance helpers and bounded stress checks.
- `tests/integration/`: package-level deterministic mutation, exploration, and
  concurrency coverage.
- `examples/`: bounded usage examples for the supported queue and channel
  surfaces.
- `benchmarks/`: throughput review workloads for ring buffer, SPSC, and
  disruptor paths.

## Change checklist

- Update `README.md`, `AGENTS.md`, and the relevant plan or closure record
  when package behavior or workflow changes.
- Extend `tests/integration/root.zig` when you add new first-class package
  integration coverage.
- Extend `src/testing/root.zig` when you add a new package-owned conformance
  helper.
- Re-record benchmark baselines when workload sizes or semantics change.
- Update root `README.md`, root `AGENTS.md`, and `docs/architecture.md` when
  package guidance or repository navigation changes.
