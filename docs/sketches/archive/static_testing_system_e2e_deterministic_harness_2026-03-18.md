# `static_testing` system/e2e deterministic harness sketch

Date: 2026-03-18

## Goal

Add a first-class bounded composition surface that lets callers run multiple
deterministic components under one shared run identity, one shared simulation
fixture, and one retained-artifact policy.

## Immediate design

- Public module: `testing.system`
- First surface: single-process, caller-owned, fixture-backed execution only
- Shared identity: callers provide one `RunIdentity` for the whole composed run
- Shared trace: the harness reuses the fixture trace buffer and derives bundle
  metadata from the retained snapshot when failures occur
- Shared retention: failures persist through `failure_bundle` rather than a
  separate system-local artifact path
- Component registration: the first registration model is a bounded list of
  `ComponentSpec { name }`, validated for non-empty unique names
- User state: the harness accepts caller-owned state/context so real subsystem
  components can be composed without globals or namespace tricks

## First implementation boundary

- `runWithFixture()` should:
  - validate component registration and retained-trace prerequisites
  - create a `SystemContext` over the shared fixture, run identity, and
    registered components
  - call one user-provided run callback with caller-owned state plus the shared
    context
  - return one `SystemExecution` with shared trace metadata, checker result,
    and optional retained bundle metadata
- The harness should not:
  - own worker pools
  - infer component wiring
  - invent a system-local replay format
  - absorb `process_driver` into phase 1

## Why this boundary is correct

- It closes the composition gap without introducing a hosted runtime.
- It keeps the surface Zig-idiomatic: explicit config, caller-owned state, and
  narrow generic callbacks.
- It reuses the already-stabilized lower layers:
  - `testing.identity`
  - `testing.sim.fixture`
  - `testing.trace`
  - `testing.checker`
  - `testing.failure_bundle`

## Remaining follow-up after the first implementation

- add one process-boundary composition example only if deterministic and
  bounded behavior stays clear
- add richer system-level retained summaries only if real users need more than
  the existing bundle + trace surfaces
- evaluate sharded or multi-worker execution only after the single-process
  harness is stable
