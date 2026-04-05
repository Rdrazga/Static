# `static_scheduling`

Deterministic scheduling primitives for task graphs, timer wheels, pollers, executors, and bounded parallel helpers.

## Current status

- The root workspace build is the supported entry point; package-local `zig build` is not the supported validation path.
- The follow-up plan is closed on 2026-04-01.
- Exported-surface proof ownership is complete, the stale `static_queues` wiring has been removed, and the package keeps queue ownership downstream.
- Package coverage includes task-graph replay/fuzz, timer-wheel model, exploration, temporal, and replay proofs, plus executor join-timeout coverage.
- Canonical benchmarks are recorded for task-graph planning and timer-wheel schedule/cancel workloads.

## Main surfaces

- `src/root.zig` exports the package API and narrow `core` / `sync` dependency aliases.
- `src/scheduling/topo.zig` owns deterministic DAG ordering helpers.
- `src/scheduling/task_graph.zig` owns task-graph storage, dependency insertion, and planning.
- `src/scheduling/timer_wheel.zig` owns bounded timer scheduling and cancellation.
- `src/scheduling/poller.zig` owns poller coordination helpers.
- `src/scheduling/thread_pool.zig` owns worker-pool coordination.
- `src/scheduling/parallel_for.zig` owns bounded parallel iteration helpers.
- `src/scheduling/executor.zig` owns job execution and join/timeout behavior.
- `tests/integration/root.zig` wires the deterministic package regression surface.
- `examples/task_graph_topo.zig` shows bounded task-graph usage.
- `benchmarks/planning_baselines.zig` records the canonical benchmark review workloads.

## Validation

- `zig build check`
- `zig build test`
- `zig build bench`
- `zig build examples`
- `zig build docs-lint`

## Key paths

- `tests/integration/model_timer_wheel.zig` covers timer-wheel model behavior.
- `tests/integration/explore_timer_queue_cancel_tick.zig` covers bounded exploration for cancel-before-tick behavior.
- `tests/integration/replay_explore_timer_queue_provenance.zig` covers retained exploration provenance.
- `tests/integration/replay_fuzz_task_graph.zig` covers replay-backed task-graph invariants.
- `tests/integration/executor_join_timeout.zig` covers blocked-worker join and timeout behavior.
- `benchmarks/planning_baselines.zig` is the canonical admitted benchmark entry point.

## Benchmark artifacts

- Benchmark outputs live under `.zig-cache/static_scheduling/benchmarks/planning_baselines/`.
- Canonical review artifacts stay on shared `baseline.zon` plus `history.binlog`.
- Re-record baselines when task counts, graph shapes, timer capacity, or scheduling semantics change materially.
