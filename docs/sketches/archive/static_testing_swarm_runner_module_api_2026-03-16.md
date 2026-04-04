# `static_testing` swarm runner module/API draft

Date: 2026-03-16
Primary feature sketch:
`docs/sketches/archive/static_testing_feature_sketch_swarm_runner_orchestration_2026-03-16.md`

## Purpose

Turn the swarm-runner feature sketch into a concrete module boundary and MVP API
shape that can be implemented without expanding `static_testing` beyond its
current package discipline.

## File placement

The first-pass implementation should land in the existing testing package tree:

- `packages/static_testing/src/testing/swarm_runner.zig`
- `packages/static_testing/src/testing/root.zig`

No new `sim` submodule is needed. The orchestration layer should import and
compose `testing.sim`, not extend its low-level API surface.

## Public types

### `SwarmRunError`

Keep the public operating-error vocabulary narrow:

- `InvalidInput`
- `NoSpaceLeft`

The runner should reuse downstream explicit errors from persistence and scenario
execution rather than collapsing everything into `anyerror`.

### `SwarmProfile`

The profile should encode policy bundles rather than ad hoc booleans:

- `smoke`
- `stress`
- `soak`

These names should map to explicit bounded defaults. Package harnesses may still
override individual budgets through options.

### `SwarmStopPolicy`

The first version only needs:

- `stop_on_first_failure`
- `collect_failures`

`collect_failures` must carry an explicit maximum retained-failure count.

### `SwarmConfig`

The MVP config should be an options struct with explicit bounds:

- `package_name`
- `run_name`
- `base_seed`
- `build_mode`
- `profile`
- `seed_count_max`
- `steps_per_seed_max`
- `failure_retention_max`
- `stop_policy`
- `progress_every_n_runs`

Do not add wall-clock timeouts or host-thread knobs in the MVP. Those are later
host-orchestration concerns.

### `SwarmVariant`

The runner needs a stable per-run scenario selection record:

- `variant_id: u32`
- `variant_weight: u32`
- `label: []const u8`

This should remain metadata-only in the runner. The scenario owns the meaning of
the variant.

### `SwarmExecution`

One run summary should include:

- `run_identity`
- `profile`
- `variant_id`
- `steps_executed`
- `trace_metadata`
- `check_result`
- `failure_artifact_name`

This type should be cheap to retain in bounded arrays for failure collection.

### `SwarmSummary`

The aggregate return value should include:

- `executed_run_count`
- `failed_run_count`
- `retained_failure_count`
- `first_failure`

`first_failure` stays useful even when the stop policy permits collecting more.

## Scenario contract

Use a small callback wrapper, parallel to the existing fuzz-runner style:

- scenario input:
  - `run_identity`
  - `profile`
  - `variant`
  - `steps_per_seed_max`
- scenario output:
  - `trace_metadata`
  - `check_result`
  - optional scenario stats

The scenario callback should build and run one deterministic harness instance.
It should not expose scheduler internals unless the harness explicitly chooses
to treat schedule mode as part of its variant space.

## Variant selection

The runner should not own a generalized weighted-random framework in the MVP.
It only needs deterministic bounded selection over a caller-provided slice of
variants:

- validate total weight is non-zero;
- use split-seed derivation from `base_seed` and `run_index`;
- select one weighted variant deterministically;
- persist the chosen variant metadata into failure artifacts.

Disabled variants can be represented by omitting them or giving them zero weight
before validation.

## Persistence contract

The first version should reuse the current replay-artifact and corpus path:

- retain `RunIdentity`;
- persist trace metadata and checker result;
- store `profile`, `variant_id`, and seed lineage in artifact metadata.

When replay failure bundles land, `swarm_runner` should switch from thin replay
artifacts to richer bundles without changing its top-level control flow.

## Suggested function surface

Keep the initial module small:

- `pub fn SwarmScenario(comptime ScenarioError: type) type`
- `pub fn SwarmRunner(comptime ScenarioError: type) type`
- `pub fn runSwarm(...)`

Private helpers should cover:

- config validation;
- profile-to-bounds derivation;
- weighted variant choice;
- one-run identity construction;
- failure finalization and persistence;
- stop-policy decision.

## Non-goals for the first implementation

- host-thread parallel execution;
- campaign resume files;
- seed-priority heuristics;
- automatic shrinking/minimization;
- multi-scenario scheduling across packages;
- embedded benchmark gating in the runner.

## Recommended implementation order

1. Define public enums, config, and scenario contract.
2. Implement deterministic run identity and variant selection helpers.
3. Implement single-threaded campaign execution with stop policy.
4. Integrate persistence using existing replay artifacts.
5. Add example harness and upgrade path to replay bundles.
