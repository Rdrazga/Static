# Workspace validation follow-up closed 2026-04-04

Scope: root validation commands, shared testing workflow, lock-free queue
stress coverage, and benchmark/harness signal clarity.

Status: closed on 2026-04-04. The root command semantics are now explicit, the
observed flaky `static_queues` and `static_sync` concurrency failures are
stabilized, and the root-facing docs now match the implemented command split.

## Recorded outcomes

- `LockFreeMpscQueue` keeps the documented best-effort non-blocking contract
  under contention. Bounded eventual progress is not part of the queue API.
- `packages/static_queues/src/testing/lock_free_stress.zig` now proves bounded
  safety and conservation under contention instead of converting transient
  `WouldBlock` churn into a false correctness failure.
- `zig build harness` now stays a success-only smoke surface. Intentionally
  retained-failure examples remain available on `zig build examples`, but the
  harness step no longer runs the `model_sim_fixture` or `swarm_sim_runner`
  demos that emitted failure-like text.
- `zig build bench` remains review-only by default. Benchmark regressions still
  print through the shared baseline workflow, but the build does not gate on
  them unless a caller-owned workflow opts into regression enforcement.
- `packages/static_sync/src/sync/cancel.zig` test cleanup now uses time-based
  waits and unconditional thread release/join cleanup so a timed wait failure
  cannot leave a live registration thread behind and corrupt the next test.

## Validation

- `zig build docs-lint`
- `zig build harness`
- `zig build examples`
- `zig build bench`
- `zig build test` repeated 5 times before the `static_sync` follow-up and 3
  times after it
- `zig build ci` repeated 2 times after the `static_sync` follow-up

## Reopen triggers

- Reopen if a root validation command again mixes success-only and intentional
  retained-failure output in a way that obscures operator signal.
- Reopen if `static_queues` lock-free coverage needs a stronger progress
  contract than the current non-blocking queue API documents.
- Reopen if benchmark gating becomes a workspace policy rather than a
  caller-owned opt-in workflow.
