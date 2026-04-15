# `static_testing` swarm runner orchestration completion

Feature source:
`docs/sketches/archive/static_testing_feature_sketch_swarm_runner_orchestration_2026-03-16.md`

## Goal

Add a bounded deterministic swarm runner for many-seed scenario portfolios
without drifting into hosted orchestration or a general job scheduler.

## Completed outcome

- `packages/static_testing/src/testing/swarm_runner.zig` now owns deterministic
  seed enumeration, weighted variant selection, resume support, static
  sharding, bounded campaign records, bounded campaign summaries, retained-seed
  suggestions, and bounded host-thread worker lanes with deterministic
  main-thread commit order.
- Retained swarm failures reuse the shared failure-bundle contract, including
  caller-selected trace artifacts and optional typed `pending_reason` metadata.
- `packages/static_testing/examples/swarm_sim_runner.zig` and
  `packages/static_testing/tests/integration/swarm_sim_runner.zig` remain the
  package-facing proof that the public swarm surface is ergonomic and replayable.

## Final boundary decision

- Keep the current bounded per-variant summary plus retained-seed suggestion
  layer as the shared contract.
- Keep richer clustering, long-run triage heuristics, and hosted orchestration
  in caller repos unless repeated repo-owned demand proves one narrower shared
  contract.

## Validation

- `zig build test`

