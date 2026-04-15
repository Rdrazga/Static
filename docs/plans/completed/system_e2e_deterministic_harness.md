# `static_testing` system and end-to-end deterministic harness completed plan

Design draft:
`docs/sketches/archive/static_testing_system_e2e_deterministic_harness_2026-03-18.md`

## Goal

Compose multiple deterministic components, simulated subsystems, and optional
process boundaries into one bounded system/e2e harness surface.

## End-state design standard

- Assume unknown users will need to compose real library state, reusable
  simulators, and bounded process boundaries into one deterministic review
  surface without writing their own harness shell.
- The durable boundary is a library-owned composition layer over run identity,
  temporal checks, retained artifacts, and deterministic component wiring. It
  is not a hosted orchestrator, deployment manager, or environment runner.
- Prefer explicit component registration, caller-owned state, bounded artifact
  policy, and replayable failures over convenience APIs that would later leak
  execution policy or force framework-style refactors.

## Validation

- Unit tests for composition contracts and deterministic run identity handling.
- One package-facing example that composes multiple simulated components.
- One integration test that persists an end-to-end deterministic failure with
  replay and provenance.
- `zig build test`
- `zig build examples`
- `zig build harness`

## Current status

- `packages/static_testing/src/testing/system.zig` now provides the first
  bounded single-process composition harness over shared fixture, trace, run
  identity, checker, and failure-bundle surfaces.
- `SystemHarnessConfig` now validates explicit `ComponentSpec` registration,
  and `runWithFixture()` now accepts caller-owned user state plus a shared
  `SystemContext`.
- `SystemFailurePersistence` now owns a system-level artifact selection surface
  so `testing.system` no longer exposes raw failure-bundle context as the
  normal write-policy API.
- `packages/static_testing/examples/system_storage_retry_flow.zig` now shows a
  composed deterministic run over network, storage, and retry components.
- `packages/static_testing/examples/system_process_driver_flow.zig` now adds a
  bounded process-boundary composition example over one driver component plus a
  simulated mailbox/fixture flow.
- Those two package-owned system examples are now also promoted onto the
  package smoke and root harness surfaces, and onto the supported root example
  surface, so `testing.system` no longer depends on manual example execution.
- `packages/static_testing/tests/integration/system_failure_bundle.zig` now
  proves a composed deterministic failure can persist through the shared
  failure-bundle path with retained trace data.
- `packages/static_testing/tests/integration/system_process_driver_flow.zig`
  now proves the same retained-failure path across a bounded process-driver
  component inside `testing.system`.
- `packages/static_io/tests/integration/system_runtime_retry_flow.zig` now
  provides the first real downstream package adopter of `testing.system`,
  proving a bounded runtime + buffer-pool retry flow with shared temporal
  assertions and retained failure-bundle provenance.
- `packages/static_io/tests/integration/system_process_driver_runtime_retry.zig`
  now provides a third real downstream package adopter of `testing.system`,
  proving a bounded process-driver plus runtime/buffer/retry composition with
  retained provenance and stderr through the system-owned failure path.
- `packages/static_net_native/tests/integration/system_loopback_endpoints.zig`
  now provides a second real downstream package adopter of `testing.system`,
  proving the same harness also fits bounded live loopback endpoint agreement
  over real native socket queries without widening into broad live-network
  coverage.
- The package now has enough prerequisite substrate to start it: shared
  simulation fixture setup, caller-selected retained artifacts, bounded
  provenance/temporal surfaces, reusable subsystem simulators, and failure
  bundles.
- The first bounded system harness is now present across pure simulated,
  process-boundary, and multiple real package compositions. Additional
  adopter-driven hardening is deferred; callers can use lower-level helpers
  directly where the high-level API is not the right fit.

## Phases

### Phase 0: composition boundary

- [x] Define how components register with the harness and how deterministic time
  and identity flow through them.
- [x] Decide the first relationship between `testing.sim`, `process_driver`,
  replay artifacts, and failure bundles.
- [x] Keep the first version single-process and caller-owned; reject hosted test
  environments.

### Phase 1: bounded composition MVP

- [x] Add a composition harness for multiple deterministic components in one
  run.
- [x] Support shared run identity, trace collection, and failure retention.
- [x] Reuse `testing.sim.fixture` and failure bundles rather than inventing a
  separate artifact path.

### Phase 2: e2e usefulness

- [x] Add one example with multiple subsystems or services in one deterministic
  run.
- [x] Add one example that combines simulated and process-boundary components if
  that remains deterministic and bounded.
- [x] Add one replay path that reproduces a retained e2e failure.

Completion note:

- Keep the landed implementation focused on composition and retention, not on
  hosted orchestration, worker management, or environment ownership.
- Do not keep extra adopter-driven hardening on the active queue; reopen the
  plan only if repo-owned work reveals a concrete system-surface bug or
  missing bounded contract.

### Phase 3: only if justified

- [x] Defer sharded or multi-worker execution until a concrete repo-owned need
  appears.
- [x] Keep hosted deployment/test-environment management out of scope.
