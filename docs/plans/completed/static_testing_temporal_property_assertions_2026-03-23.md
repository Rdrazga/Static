# `static_testing` temporal property assertions plan

## Goal

Provide bounded temporal/property assertions for deterministic runs, such as
`eventually`, `never after`, `happens-before`, `at-most-once`, and
`exactly-once`.

## End-state design standard

- Assume deterministic review will need a canonical temporal vocabulary across
  models, simulations, queues, schedulers, and system flows, not repeated
  package-local trace predicates.
- The durable boundary is a bounded trace-driven assertion surface with strong
  deterministic summaries and retained-failure integration. It is not a full
  temporal-logic language or theorem-proving system.
- Keep the matcher model and retained-failure path stable now so future package
  migrations share the same review vocabulary instead of layering mini-DSLs.

## Validation

- Unit tests for temporal assertion semantics over synthetic traces.
- One model-based example and one simulation-based example.
- Integration coverage that persists a temporal assertion failure through the
  normal replay/failure-bundle path.
- `zig build test`
- `zig build examples`

## Phases

### Phase 0: bounded assertion model

- [x] Define the first assertion vocabulary and what inputs it consumes:
  bounded trace-driven `EventMatcher` checks over labels plus optional category,
  value, cause-sequence, correlation, and surface metadata.
- [x] Decide that the first surface is trace-driven rather than callback-driven.
- [x] Keep the first version bounded and single-run; reject unbounded liveness
  proof scope.

### Phase 1: MVP

- [x] Add a small assertion surface for `eventually`, `never`, and
  `happens-before`.
- [x] Add deterministic failure summaries that identify the first violated
  relation.
- [x] Integrate with `checker` vocabulary and failure bundles.

### Phase 2: practical expansion

- [x] Add `at-most-once` and `exactly-once` helpers.
- [x] Add integration examples grounded in queue/scheduler or protocol flows.
- [x] Add one package migration where package-local temporal logic becomes a
  shared helper.

## Current status

- `packages/static_testing/src/testing/temporal.zig` now provides bounded
  trace-driven `eventually`, `never`, `happens-before`, `at-most-once`, and
  `exactly-once` checks with deterministic failure summaries.
- `packages/static_testing/examples/model_temporal_assertions.zig` and
  `packages/static_testing/examples/sim_temporal_assertions.zig` now exercise
  the package-facing model and simulation surfaces.
- `packages/static_testing/tests/integration/temporal_failure_bundle.zig` now
  proves temporal failures persist through the retained failure-bundle path.
- `packages/static_sync/tests/integration/sim_wait_protocols.zig` now contains
  the first real downstream migrations onto the shared temporal helpers.

Remaining design work:

- Keep the direct matcher-based surface stable while more downstream uses land.
- Only add a small declarative layer if repeated package migrations show that
  the direct API is too noisy.

### Phase 3: only if justified

- [ ] Consider a tiny declarative layer only if the direct API becomes too noisy.
- [ ] Reject full temporal logic or theorem-proving ambitions.
