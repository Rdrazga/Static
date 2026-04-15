# `static_testing` repair and liveness execution completed plan

Feature source:
`docs/sketches/archive/static_testing_repair_liveness_execution_2026-03-21.md`

Follow-on design inputs:

- `docs/decisions/2026-03-21_static_testing_simulator_boundary.md`
- `docs/sketches/archive/static_testing_ordered_effect_sequencer_2026-03-21.md`

## Goal

Add a reusable deterministic execution layer that separates fault-heavy runs
from repair/convergence runs, with typed pending reasons and bounded summaries.

## End-state design standard

- Assume unknown users will need to validate not only safety under faults, but
  also recovery after those faults are healed.
- The durable boundary is a reusable execution contract over phases,
  convergence budgets, and typed pending reasons. It is not a theorem prover,
  consensus-specific liveness checker, or hosted orchestrator.
- Keep repair policy caller-owned while the phase split, summary shape, and
  pending-reason vocabulary stay reusable and stable.

## Validation

- Unit tests for phase-budget validation, stop-on-safety-failure behavior, and
  pending-reason reporting.
- One package-facing example that converges only after repair is applied.
- One package-owned higher-level adopter after the core helper stabilizes.
- `zig build test`
- `zig build examples`

## Phases

### Phase 0: execution contract

- [x] Define fault versus repair phase vocabulary.
- [x] Define a first typed pending-reason vocabulary.
- [x] Define one bounded summary format.

### Phase 1: first reusable helper

- [x] Add a reusable helper module under `packages/static_testing/src/testing/`.
- [x] Export it from `packages/static_testing/src/testing/root.zig`.
- [x] Add unit coverage for converged, pending, and safety-failure paths.
- [x] Add one package example that exercises the helper directly.

### Phase 2: harness integration

- [x] Decide whether the next integration belongs directly in
  `testing.swarm_runner`, `testing.system`, or one lower shared layer.
  Decision:
  land the first bridge in `testing.system`, because it already owns shared
  fixture context, traces, and retained failure bundles without forcing
  swarm-specific campaign policy onto direct users.
 - [x] Add typed pending-reason retention to one higher-level harness path if
   the current summary proves insufficient.
   Decision:
   retain pending reasons as optional first-class `manifest.zon` metadata in
   failure bundles, so review tooling can read structured convergence blockers
   without parsing violation-message text.
- [x] Add one package-owned higher-level adopter with real queue/timer/process
  recovery pressure.

### Phase 3: only if justified

- [ ] Expand the pending-reason vocabulary only when repeated downstream use
  proves the first enum too narrow.
- [ ] Keep distributed-system-specific quorum or topology semantics out of the
  core helper.
- [x] Add one bounded swarm retention path that reuses the same retained
  pending-reason contract instead of inventing swarm-local recovery metadata.

## Current status

- `packages/static_testing/src/testing/liveness.zig` now provides the first
  reusable helper surface:
  - phase configuration via `RepairLivenessConfig`;
  - typed pending reasons via `PendingReason` and `PendingReasonDetail`;
  - callback-driven execution via `RepairLivenessScenario`; and
  - stable plain-text output via `formatSummary()`.
- `packages/static_testing/examples/repair_liveness_basic.zig` now provides the
  first package-facing example, and the example is wired into the package and
  workspace example surfaces.
- `packages/static_testing/src/testing/system.zig` now provides
  `runRepairLivenessWithFixture()` plus a reusable
  `SystemRepairLivenessRunner(...)` contract, so direct bounded system flows
  can share the same phase split, summary, and retained-failure behavior.
- `packages/static_testing/src/testing/failure_bundle.zig` now carries optional
  typed `pending_reason` metadata in `manifest.zon`, making retained
  convergence blockers part of the canonical bundle contract instead of a
  message-format convention.
- `packages/static_io/tests/integration/system_runtime_repair_liveness.zig` now
  provides the first downstream adopter, proving runtime timeout -> retry ->
  repaired read convergence under `testing.system`.
- `packages/static_testing/src/testing/swarm_runner.zig` now forwards optional
  `pending_reason` through retained failure bundles, and
  `packages/static_testing/tests/integration/swarm_sim_runner.zig` proves that
  the retained swarm bundle exposes the same typed blocker metadata.
- Additional swarm-side or adopter-driven expansion is deferred. The retained
  pending-reason shape and first higher-level bridge are landed.
