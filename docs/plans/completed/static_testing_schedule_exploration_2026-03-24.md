# `static_testing` schedule exploration completion

Feature source:
`docs/sketches/archive/static_testing_feature_sketch_schedule_exploration_2026-03-10.md`

## Goal

Provide bounded deterministic schedule exploration over the shared simulation
layer without widening into a general concurrency model checker.

## Completed outcome

- `packages/static_testing/src/testing/sim/explore.zig` now closes with
  retained binary exploration records, explicit metadata-only versus decision
  reads, stable text summaries, and two bounded exploration modes:
  `portfolio` and `pct_bias`.
- `packages/static_testing/src/testing/sim/scheduler.zig` now provides the
  `pct_bias` strategy as a deterministic single-preemption PCT-style bias over
  the existing ready-set scheduler.
- `packages/static_testing/examples/sim_explore_portfolio.zig`,
  `packages/static_testing/examples/sim_explore_pct_bias.zig`,
  `packages/static_testing/tests/integration/sim_explore_portfolio.zig`, and
  `packages/static_testing/tests/integration/sim_explore_pct_bias.zig` now
  prove replayable retained exploration on both bounded modes.

## Final boundary decision

- Keep exploration scoped to deterministic scheduler choices over the shared
  simulation fixture.
- Keep DFS, arbitrary runtime/thread exploration, and shared fault-script
  permutation helpers out of scope unless a later concrete package plan
  reopens them.

## Validation

- `zig build test`
