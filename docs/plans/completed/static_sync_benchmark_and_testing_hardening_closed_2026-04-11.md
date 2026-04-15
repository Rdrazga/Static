# `static_sync` benchmark and testing hardening follow-up

Scope: close the 2026-04-11 reopen for host-smoke teardown safety, benchmark
discoverability and attribution, primitive-facing retained-failure proof, and
broader lifecycle or hostile-runtime coverage across the synchronization
primitives package.

Status: follow-up closed on 2026-04-11. The concrete host-smoke crash path is
removed, the benchmark surface is directly runnable and materially more
explanatory, retained replay now targets real primitive misuse or invariant
stories, and lifecycle plus hostile-runtime proof is broadened through model,
simulation, temporal, and bounded fault-injection coverage.

## Validated issue scope

- `host_wait_smoke.zig` could return on timeout before joining a spawned
  worker, leaving the root `zig build test` surface exposed to later crashes.
- The root build did not expose named `static_sync` benchmark owners, and the
  package benchmark support was thinner than newer packages.
- Benchmark coverage and attribution were too narrow for the exported
  primitive families, making it hard to localize regressions beyond elapsed
  time alone.
- Parts of the replay and retained-failure surface proved harness mechanics
  more than package-local primitive behavior.
- Lifecycle and ordering proof was real but uneven across `cancel`, `event`,
  `semaphore`, `wait_queue`, and related synchronization stories.

## Implemented fixes

- [host_wait_smoke.zig](/I:/Forbin%20Solutions/Library%20Dev/static/packages/static_sync/tests/integration/host_wait_smoke.zig)
  now uses ready-to-wait handshakes, stage-labelled timeout reporting, and
  bounded cleanup on every exit path so failures do not leave live worker
  threads behind.
- The root build now exposes direct named benchmark steps for the admitted
  owners, and `static_sync` benchmark owners share one support path with
  explicit environment notes, bounded tags, and workload-shape metadata.
- The package benchmark matrix now includes direct owners for fast paths,
  contention, cancel lifecycle, barrier phase and wait, once and grant,
  seqlock, timeout paths, condvar, and benchmark references. The admitted
  contention surfaces use bounded watchdogs and distinguish parking-backed
  waits from polling-fallback runs in their metadata.
- Benchmark hotspot review was tightened through decomposition rather than
  guesswork. The package now has an investigation sketch plus isolated owners
  that separate once first-call from done fast-path cost, grant issue or
  validate or write cost, cancel registration from fanout cost, barrier phase
  arrival from blocking wait cost, and seqlock read-begin or retry from writer
  lock or unlock work.
- [replay_fuzz_sync_primitives.zig](/I:/Forbin%20Solutions/Library%20Dev/static/packages/static_sync/tests/integration/replay_fuzz_sync_primitives.zig)
  and
  [fuzz_persistence_sync.zig](/I:/Forbin%20Solutions/Library%20Dev/static/packages/static_sync/tests/integration/fuzz_persistence_sync.zig)
  now retain and replay primitive-facing misuse or invariant traces instead of
  relying on threshold-triggered synthetic failure.
- [failure_bundle.zig](/I:/Forbin%20Solutions/Library%20Dev/static/packages/static_testing/src/testing/failure_bundle.zig)
  now preserves full-width `u128` checkpoint digests during retained bundle
  serialization, with a direct regression test proving the shared fix.
- `static_sync` now owns additional bounded `testing.model` targets for cancel
  lifecycle, semaphore progression, and a capability-gated `wait_queue`
  contract, so lifecycle proof is no longer concentrated only in barrier and
  seqlock.
- `static_sync` now owns additional simulator and temporal protocol checks for
  event set or reset reuse, semaphore post-before-timeout ordering, and cancel
  reset ordering.
- `static_sync` now owns bounded hostile-runtime proofs for delayed wake,
  repeated timeout or retry, cancel-reset reuse, and delayed wake propagation,
  with Windows-safe join handling on the worker-thread fault tests.

## Proof posture

- `zig build test`
- `zig build harness`
- `zig build docs-lint`
- Direct benchmark-owner validation across the admitted `static_sync` owners,
  including `static_sync_fast_paths`, `static_sync_contention`,
  `static_sync_cancel_lifecycle`, `static_sync_barrier_phase`,
  `static_sync_barrier_wait`, `static_sync_once_and_grant`,
  `static_sync_seqlock`, `static_sync_timeout_path`, and
  `static_sync_benchmark_references`

## Current posture

- `static_sync` now has explicit package-owned proof for host-smoke teardown
  safety, primitive-facing retained replay, bounded lifecycle modeling,
  schedule-sensitive protocol checks, and hostile-runtime delay or retry
  behavior without leaning on unbounded stress loops.
- The benchmark surface is directly runnable from the root build, broad enough
  to cover the important exported primitive families, and split enough to make
  timing signals diagnostically useful instead of only descriptive.
- The package remains scoped to synchronization primitives and coordination
  building blocks; queue policy, scheduler fairness, runtime ownership, and
  downstream orchestration remain intentionally out of scope.

## Reopen triggers

- Reopen if a host-smoke or hostile-runtime path can again leave live worker
  threads behind after timeout, panic, or cancellation.
- Reopen if a first-class exported primitive loses direct benchmark coverage or
  if admitted benchmark metadata stops distinguishing the workload shape needed
  to interpret regressions.
- Reopen if retained replay falls back to synthetic harness-only failure
  triggers instead of primitive-facing reduced traces.
- Reopen if a new lifecycle or ordering bug class appears that current direct,
  model, sim, temporal, or bounded fault-injection proof cannot express
  truthfully inside the package boundary.
