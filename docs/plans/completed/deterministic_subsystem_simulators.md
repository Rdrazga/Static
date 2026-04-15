# `static_testing` deterministic subsystem simulators completed plan

Locked boundary:
`docs/decisions/2026-03-21_static_testing_simulator_boundary.md`

Exploratory draft:
`docs/sketches/archive/static_testing_simulator_fault_richness_2026-03-21.md`

## Goal

Add reusable bounded simulator components for common subsystem behaviors such as
network delay/partition, storage latency/failure, retry/backpressure, and
time-oriented scheduling.

## End-state design standard

- Assume future users will need a small canonical library of deterministic
  subsystem models instead of repeatedly rebuilding network, storage, retry,
  and time behavior in package-local glue.
- The durable boundary is a family of bounded simulator components that compose
  over `testing.sim.fixture` and caller-owned replay state. It is not a full
  runtime emulator, a catch-all environment simulation layer, or a shared
  retained simulator-artifact system.
- Prefer explicit seeded or planned policies, clear ownership of fault
  behavior, and simulator families that recur across packages over one-off app
  models that would force later API pruning.
- Use the accepted simulator-boundary decision as the filter for whether a new
  "richer" slice belongs in `network_link`, `storage_durability`, an existing
  helper, or nowhere in the shared package surface.

## Locked boundary

From first principles, the shared simulator layer exists to cover repeated
cross-codebase correctness pressure in:

- transport/link behavior;
- async completion lanes;
- durable-state behavior;
- retry/backpressure behavior;
- time observation; and
- ordered effect release.

That means:

- `testing.sim.network_link` owns transport-generic connectivity, delay,
  congestion, and retained pending-delivery diagnosis;
- `testing.sim.storage_lane` owns simple delayed completion without durable
  semantics;
- `testing.sim.storage_durability` owns durable-state delay, integrity,
  recovery, and retained state diagnosis;
- `testing.sim.retry_queue` owns retry/backpressure scheduling;
- `testing.sim.clock` and `testing.sim.clock.RealtimeView` own monotonic and
  observed-time modeling; and
- `testing.ordered_effect` owns out-of-order release review but is not a
  simulator family.

Admissible "richer" work is now locked to:

- network topology/connectivity and transport delay/queueing;
- storage integrity/placement/persistence and recovery semantics; and
- additional time-observation families only if monotonic plus realtime
  projection proves insufficient across repeated downstream scenarios.

Do not treat "richer" as permission to add protocol semantics, app-specific
logic, or a catch-all environment emulator.
Do not add shared retained simulator persistence beyond caller-owned replay
buffers/state.

## Validation

- Unit tests for deterministic behavior and bounded storage.
- One example per first simulator family added.
- Integration coverage for at least one multi-component simulated flow.
- `zig build test`
- `zig build examples`

## Phases

### Phase 0: scope and first components

- [x] Decide the first simulator set: start with bounded network/message
  delivery, then follow with storage delay/failure and bounded retry helpers.
- [x] Define the contract between simulators and `testing.sim.fixture`.
- [x] Reject attempts to model the entire OS/runtime in one step.

### Phase 1: first reusable components

- [x] Add one bounded network/message-delivery simulator.
- [x] Add one bounded storage/operation-latency simulator.
- [x] Add one bounded retry/backpressure helper.
- [x] Keep all policies explicit and seed-driven.

### Phase 2: composition quality

- [x] Add composition examples that combine two simulator families in one test.
- [x] Integrate provenance and temporal assertions once those surfaces exist.
- [x] Add at least one downstream migration that removes package-local simulator
  glue.

## Current status

- `packages/static_testing/src/testing/sim/network_link.zig` now provides the
  first bounded message-delivery simulator, and it now has a first richer
  fault slice with built-in node-isolation partitions, directed/group
  partitions, explicit route-matched fault rules for asymmetric targeted
  drops and targeted extra delay, plus route-specific congestion windows,
  route-matched backlog saturation with explicit overflow behavior, and
  caller-owned pending-delivery snapshot/replay for retained diagnosis and
  deterministic reproduction.
- `packages/static_testing/src/testing/sim/storage_lane.zig` now provides
  bounded delayed storage success/failure completions.
- `packages/static_testing/src/testing/sim/storage_durability.zig` now
  provides the first bounded storage-durability simulator with separate
  read/write delay, explicit `crash()` / `recover()`, pending-write drop
  semantics, fixed-value corruption policies, an explicit post-recover
  stabilization guardrail for repairable worlds, bounded caller-owned state
  snapshot/replay over pending operations and stored values, bounded
  misdirected-write placement faults, acknowledged-but-not-durable write
  omission faults, and traceable outcomes.
- `packages/static_testing/src/testing/sim/retry_queue.zig` now provides
  bounded retry scheduling with explicit backoff and attempt exhaustion.
- `packages/static_testing/examples/sim_network_link.zig`,
  `packages/static_testing/examples/sim_network_link_group_partition.zig`,
  `packages/static_testing/examples/sim_network_link_backlog_pressure.zig`,
  `packages/static_testing/examples/sim_network_link_record_replay.zig`,
  `packages/static_testing/tests/integration/sim_network_link_fault_rules.zig`,
  `packages/static_testing/tests/integration/sim_network_link_record_replay.zig`,
  `packages/static_testing/examples/sim_storage_lane.zig`,
  `packages/static_testing/examples/sim_storage_durability.zig`,
  `packages/static_testing/examples/sim_storage_durability_misdirected_write.zig`,
  `packages/static_testing/examples/sim_storage_durability_acknowledged_not_durable.zig`,
  `packages/static_testing/examples/sim_storage_durability_record_replay.zig`,
  `packages/static_testing/examples/sim_retry_queue.zig`, and
  `packages/static_testing/examples/sim_storage_retry_flow.zig` now cover both
  single-simulator use and deterministic composition.
- `packages/static_testing/tests/integration/sim_storage_retry_flow.zig` now
  proves multi-component composition with temporal assertions.
- `packages/static_testing/tests/integration/sim_storage_durability_faults.zig`
  now proves crash -> recover -> missing-read -> corrupted-write ->
  corrupted-read ordering under shared fixture tracing and temporal checks, and
  also proves bounded misdirected-write placement, acknowledged-but-not-durable
  writes, and repair-phase restabilization after recovery.
- `packages/static_testing/tests/integration/sim_storage_durability_record_replay.zig`
  now proves caller-owned storage-state snapshot/replay reproduces stored
  values plus pending repair-phase operations under deterministic fixture
  timing.

Concrete next slices under the accepted boundary, ranked by expected shared
value:

1. [x] Storage placement/persistence fault:
   bounded misdirected writes in `testing.sim.storage_durability`.
2. [x] Storage persistence omission fault:
   add one explicit acknowledged-but-not-durable or partial-durable write
   family.
3. [x] Network topology fault:
   add one directed/group partition surface that is more expressive than a
   single isolated node but still transport-generic.
4. [x] Network queue pressure:
   add one bounded route/backlog saturation policy with explicit overflow
   behavior.
5. [x] Shared retained simulator persistence rejected:
   caller-owned replay buffers/state remain the boundary and shared versioned
   simulator artifacts are now out of scope.
- `packages/static_sync/tests/integration/sim_wait_protocols.zig` now provides
  the first real downstream migration off package-local simulator glue by
  using `testing.sim.fixture` for shared deterministic event-loop setup across
  its wait/wake protocol scenarios.
- `packages/static_io/tests/integration/sim_buffer_retry_plan_matrix.zig` now
  proves planned failure insertion over `testing.sim.storage_lane`,
  `testing.sim.retry_queue`, and `testing.sim.fixture` can drive bounded retry
  outcomes deterministically without package-local random harness glue.

Remaining design work:

- Keep reusable failure insertion focused on explicit simulator policy and
  bounded seeded inputs; do not add a global fault-DSL unless several packages
  repeat the same fault-scripting patterns.
- Keep using the accepted simulator-boundary decision to reject simulator work
  that is package-specific, protocol-specific, or already cleanly expressible
  by composing existing surfaces.
- The refreshed TigerBeetle VOPR comparison shows the biggest remaining
  simulator gaps are:
  - network fault richness beyond the now-landed node-isolation partitions,
    directed/group partitions, route-matched `drop` / `add_delay` rules,
    route-specific congestion windows, route-matched backlog saturation, and
    caller-owned pending-delivery snapshot/replay, especially any broader
    transport-generic policy vocabulary that repeated downstream use still
    proves necessary;
  - storage durability behavior beyond the now-landed crash/corruption slice,
    especially richer recoverability-aware guardrails and additional durable
    fault families justified by repeated downstream use.
- Time simulation now includes opt-in bounded reference-time offset/drift
  projection through `testing.sim.clock.RealtimeView`; only add richer time
  families if repeated downstream use proves the current view surface too
  narrow.
- Consider additional subsystem families such as cache or service-discovery
  components only after repeated concrete need.

## Completion note

This foundational simulator plan is complete. The shared network, storage,
retry, and time surfaces are landed, and the remaining decisions are now:

- downstream adoption of the landed simulator boundary;
- whether repeated users justify reopening richer bounded network or storage
  policy; and
- whether new simulator families are needed at all.

Those are follow-on package-boundary decisions, not standing execution work for
this plan.

### Phase 3: deferred or rejected

- [x] Defer additional subsystem families such as cache or service-discovery
  simulation until repeated concrete need proves the current family set is
  insufficient.
- [x] Keep full production-runtime emulation out of scope.
