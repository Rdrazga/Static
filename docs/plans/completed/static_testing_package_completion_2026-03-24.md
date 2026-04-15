# `static_testing` package completion record

Date: 2026-03-24

## Scope closed

- `docs/plans/active/packages/static_testing.md`
- `docs/plans/active/packages/static_testing_feature_sketch_implementation.md`
- `docs/plans/active/packages/static_testing_feature_sketch_phases.md`
- `docs/plans/active/packages/static_testing_features/swarm_runner_orchestration.md`
- `docs/plans/active/packages/static_testing_features/artifact_formats_and_storage.md`
- `docs/plans/active/packages/static_testing_features/schedule_exploration.md`

## Final package posture

- `testing.swarm_runner` stops at bounded deterministic campaign execution,
  resume, sharding, worker-lane host-thread execution, campaign summaries, and
  one retained-seed suggestion per variant. Richer clustering, hosted
  orchestration, and cross-package runner policy remain caller-owned.
- Shared artifact storage is now closed around `artifact.document` for bounded
  `ZON` documents and `artifact.record_log` for append-only binary streams.
  Artifact emission stays caller-controlled at the workflow layer rather than
  being forced by the storage helpers.
- `testing.sim.explore` now closes with two bounded schedule modes:
  `portfolio` over `first` plus seeded schedules and `pct_bias` for one
  deterministic PCT-style preemption point per schedule index. DFS, general
  thread exploration, and shared fault-script permutation helpers remain out of
  scope.
- The `static_testing` active-plan surface is intentionally gone. Reopen it
  only when a concrete repo-owned gap appears that the current shared harness
  surface cannot cover without regrowing package-local testing frameworks.

## Completion notes

- Swarm retention policy is intentionally capped at the current bounded
  campaign summary plus retained-seed suggestion layer.
- Repair/liveness stays one layer below swarm in `testing.liveness` and
  `testing.system`; swarm only forwards the same typed pending-reason metadata
  through retained bundles.
- Compatibility support that is intentionally retained is now explicit:
  `bench.baseline` accepts v2-v3 baseline documents and
  `bench.history_binary` accepts v1-v3 history records. Newer unsupported
  versions on retained bundle, replay, trace, exploration, and swarm record
  surfaces still fail closed.

## Validation

- `zig build test`

