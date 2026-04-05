# `static_scheduling` package guide
Start here when you need to review, validate, or extend `static_scheduling`.

## Source of truth

- `README.md` for the package entry point and command surface.
- `src/root.zig` for the exported surface.
- `tests/integration/root.zig` for the package-level deterministic regression surface.
- `benchmarks/` for the canonical benchmark entry point and artifact names.
- `examples/` for bounded usage examples.
- `docs/plans/completed/static_scheduling_followup_closed_2026-04-01.md` for the
  current closure posture and reopen triggers.
- `docs/plans/active/workspace_operations.md` for workspace priority and sequencing.
- `docs/architecture.md` for package boundaries and dependency direction.

## Supported commands

- `zig build check`
- `zig build test`
- `zig build bench`
- `zig build examples`
- `zig build docs-lint`

## Working agreements

- Use the root `build.zig` as the supported validation surface.
- Keep `static_scheduling` focused on deterministic scheduling policy:
  task graphs, timer wheels, pollers, thread pools, parallel-for helpers, and executors belong here.
- Keep `core` and `sync` as narrow dependency entry points; do not grow a second policy layer in package docs or code.
- Prefer shared `static_testing` workflows for replay, fuzz, temporal checks, exploration, provenance, and retained failures.
- Keep timer-queue scenario scaffolding local when the setup is scheduling-specific; keep generic harness patterns in `static_testing`.
- Keep benchmark artifacts on shared `baseline.zon` plus `history.binlog`; do not add package-local artifact formats.

## Package map

- `src/root.zig`: package export surface and dependency aliases.
- `src/scheduling/topo.zig`: deterministic DAG ordering helpers.
- `src/scheduling/task_graph.zig`: task-graph ownership and planning.
- `src/scheduling/timer_wheel.zig`: bounded timer-wheel scheduling and cancellation.
- `src/scheduling/poller.zig`: poller coordination helpers.
- `src/scheduling/thread_pool.zig`: worker-pool coordination.
- `src/scheduling/parallel_for.zig`: bounded parallel iteration helpers.
- `src/scheduling/executor.zig`: job execution and join/timeout behavior.
- `tests/integration/`: package-level deterministic replay, model, exploration, and timeout coverage.
- `examples/task_graph_topo.zig`: bounded usage example for task-graph planning.
- `benchmarks/planning_baselines.zig`: canonical planning and timer-wheel review workloads.

## Change checklist

- Update `README.md`, `AGENTS.md`, and the relevant plan or closure record when package behavior or workflow changes.
- Extend `tests/integration/root.zig` when you add new first-class package integration coverage.
- Re-record benchmark baselines when workload sizes or semantics change.
- Update root `README.md`, root `AGENTS.md`, and `docs/architecture.md` when package guidance or repository navigation changes.
