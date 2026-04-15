# `static_testing` state-machine harness plan

Feature source:
`docs/sketches/archive/static_testing_feature_sketch_state_machine_harness_2026-03-10.md`

## Goal

Add a sequential deterministic state-machine harness that persists replayable
failing action traces and reuses the package's checker and reduction model.

## End-state design standard

- Assume this is the canonical stateful review harness for unknown users across
  API-state, protocol-state, parser/codec, and resource-lifecycle tests.
- The durable boundary is a deterministic action-trace runner with replay,
  minimization, retention, and good failure summaries. It is not a general
  property-testing DSL, strategy language, or unbounded search engine.
- Treat action generation, replay persistence, reducer behavior, and artifact
  shape as long-lived contracts now so later simulator or package adoption work
  can extend the same boundary instead of bypassing it.

## Validation

- Unit tests for harness budgets, callback contracts, and failure artifacts.
- One example for sequential API state-machine testing.
- `zig build test`
- `zig build examples`
- `zig build harness`

## Phases

### Phase 0: harness contract

- [x] Define the callback bundle and first-use-case boundaries.
- [x] Define the failing action-trace artifact format.
- [x] Decide that state digests are not part of the first artifact version.
- [x] Freeze the MVP around sequential action traces only; keep simulated and
  concurrent models out of the first version.

### Phase 1: MVP

- [x] Add `testing.model` with a sequential callback-driven harness.
- [x] Support explicit seed and fixed action-count budgets.
- [x] Persist failing action traces for replay and triage.
- [x] Keep the readable retained-action mirror typed and Zig-native via
  optional `actions.zon` sidecars instead of JSON.
- [x] Reuse `checker` vocabulary for invariant failures.
- [x] Support one narrow action-generation contract that does not require a
  separate generator framework.
- [x] Add one example that ports an existing hand-written package campaign onto
  the harness.

### Phase 2: debugging quality

- [x] Add reducer-aware action minimization.
- [x] Improve failure summaries to identify the first bad action clearly.
- [x] Add examples for both API-state and protocol-state test styles.
- [x] Add one package integration test that proves artifact replay and reduction
  are good enough for real package review use.
- [x] Migrate one real downstream package campaign onto the shared harness via
  `packages/static_serial/tests/integration/model_incremental_frames.zig`.
- [x] Keep migrating later real downstream package campaigns where they clearly
  fit the same shared harness, including
  `packages/static_net/tests/integration/model_incremental_decoder.zig` and
  `packages/static_string/tests/integration/model_intern_pool_sequences.zig`.

### Phase 3: only if justified

- [x] Explore coupling with `testing.sim` for simulation-backed models.
- [ ] Reject a general strategy DSL unless covered by the separate strategy
  feature plan.
