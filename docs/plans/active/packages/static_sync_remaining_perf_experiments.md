# `static_sync` remaining performance experiments

Scope: prototype the two highest-value remaining `static_sync` performance
ideas from the 2026-04-11 sketch, keep the existing correctness and hostile-host
proof posture intact, and measure whether the changes are worth keeping.

## Review focus

- `wait_queue.waitValue()` still slices timeout budgets into `1 ms` polling
  windows whenever a cancel token is present.
- `CancelRegistration.register()` improved materially after the earlier
  load-before-CAS fix, but it still linearly scans the bounded 16-slot
  registration table from slot `0`.
- The sketch already records the key design risks: `wait_queue` race ordering
  and the current `cancel` slot-order proof surface.

## Approved direction

- Reopen only for bounded experiments that can be validated against the
  current model, sim, replay, host-smoke, and benchmark surfaces.
- Keep `cancel` slot ordering stable unless the proof surface is intentionally
  updated in the same slice.
- Prefer adding attribution benchmarks before relying on a benchmark claim that
  existing owners cannot show directly.

## Current state

- The first direct `wait_queue` cancel-wake prototype was tried and rejected:
  it exposed a lost-wake race between the cancel callback and futex park, so
  the runtime change was backed out instead of being kept.
- The `cancel` slot-acquisition idea remains open, but the host-side Zig build
  wrapper on this machine became unstable during the experiment, so the change
  needs a cleaner rerun before it can be accepted.

## Ordered SMART tasks

1. `Cancel slot acquisition experiment`
   Prototype a bounded slot-acquisition improvement in
   `packages/static_sync/src/sync/cancel.zig` that preserves the current
   lowest-slot allocation behavior while reducing repeated occupied-slot work.
   Done when:
   - the `cancel` tests still prove current slot-index expectations;
   - `zig build static_sync_cancel_lifecycle` passes; and
   - the local registration-path result is no worse than the current baseline
     band.
   Validation:
   - `zig build test`
   - `zig build static_sync_cancel_lifecycle`
2. `wait_queue cancel-wake experiment`
   Prototype a cancel-registration-backed wake path in
   `packages/static_sync/src/sync/wait_queue.zig` so timed waits do not depend
   on `1 ms` poll slices when cancel registration succeeds, while keeping a
   bounded fallback path if registration is unavailable.
   Done when:
   - direct wait_queue tests still pass;
   - hostile-host and model coverage still pass;
   - a dedicated benchmark owner or equivalent attribution surface exists for
     cancel-after-park cost; and
   - the new path does not regress zero-timeout or existing contention owners.
   Validation:
   - `zig build test`
   - `zig build static_sync_timeout_path`
   - `zig build static_sync_contention`
3. `Docs and closure decision`
   Record the experiment outcome in package and workspace docs, and either
   keep the changes with a completed closure record or back them out and
   archive the findings.
   Done when:
   - `README.md`, `AGENTS.md`, and the relevant plan/closure doc match the
     final code;
   - the sketch and active queue reference the same outcome; and
   - docs lint passes.
   Validation:
   - `zig build docs-lint`

## Ideal state

- `cancel` registration keeps its current fixed-capacity semantics and slot
  order while paying less control-plane cost under churn.
- `wait_queue` cancellation becomes wake-driven when possible rather than
  timeout-slice-driven, without weakening explicit timeout, cancellation, or
  teardown behavior.
- The retained benchmark and proof surfaces are strong enough to justify
  either keeping the experiments or reverting them cleanly.
