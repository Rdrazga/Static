# `static_sync` runtime and benchmark follow-up

Scope: close the focused post-hardening reopen for the broken `condvar`
benchmark owner, `cancel` registration hot-path cost, polling-fallback wait
aggressiveness, avoidable wake fanout, and contention-watchdog observer cost.

Status: follow-up closed on 2026-04-11. The `condvar` benchmark source bug is
fixed, the targeted runtime hot paths are tightened without reopening
primitive correctness issues, and the affected test, harness, and benchmark
surfaces are revalidated.

## Validated issue scope

- `packages/static_sync/benchmarks/condvar_baselines.zig` referenced a removed
  metadata symbol and no longer compiled in OS-backend-enabled builds.
- `CancelRegistration.register()` paid unnecessary failed exchange work on
  occupied slots, which inflated the registration-heavy `cancel` benchmark
  cases.
- polling-fallback waits still used pure spin-hint backoff and were harsher on
  CPU and scheduler stability than they needed to be.
- `Semaphore.post(1)` still broadcast to all parked waiters on a `0 -> 1`
  transition.
- `Event.set()` still performed redundant wake work in the parking-backed path
  when already signaled.
- the contention benchmark watchdog still sampled the clock aggressively enough
  to risk contaminating the bounded contention measurements.

## Implemented fixes

- [condvar_baselines.zig](/I:/Forbin%20Solutions/Library%20Dev/static/packages/static_sync/benchmarks/condvar_baselines.zig)
  now records the correct parking-backed environment tags, so the owner
  compiles again in OS-backend-enabled builds.
- [cancel.zig](/I:/Forbin%20Solutions/Library%20Dev/static/packages/static_sync/src/sync/cancel.zig)
  now filters clearly occupied registration slots with a load before attempting
  the exchange, keeping the previous slot-selection semantics while cutting the
  heavy failed-RMW path that dominated `cancel_register_4`.
- The same cancel file now uses bounded phased backoff while waiting for an
  in-flight callback to finish, instead of raw indefinite spin hints.
- [backoff.zig](/I:/Forbin%20Solutions/Library%20Dev/static/packages/static_sync/src/sync/backoff.zig)
  now escalates from pure spin hints to spin-plus-yield once the retry
  exponent grows, so polling-fallback waits remain bounded but less hostile.
- [semaphore.zig](/I:/Forbin%20Solutions/Library%20Dev/static/packages/static_sync/src/sync/semaphore.zig)
  now uses `signal()` for single-permit wakeups and reserves `broadcast()` for
  multi-permit transitions.
- [event.zig](/I:/Forbin%20Solutions/Library%20Dev/static/packages/static_sync/src/sync/event.zig)
  now skips redundant wake work only on the parking-backed `set()` path when
  the event is already signaled, while leaving the uncontended non-parking hot
  path unchanged.
- [support.zig](/I:/Forbin%20Solutions/Library%20Dev/static/packages/static_sync/benchmarks/support.zig)
  now throttles watchdog clock polling with a bounded stride instead of
  sampling time on every watchdog loop iteration.

## Proof posture

- `zig build test`
- `zig build harness`
- `zig build docs-lint`
- `zig build static_sync_fast_paths`
- `zig build static_sync_cancel_lifecycle`
- `zig build static_sync_contention`
- `zig build -Denable_os_backends=true static_sync_contention`
- `zig build -Denable_os_backends=true static_sync_condvar`

## Current posture

- The `condvar` benchmark owner is source-correct again; the remaining
  OS-backend-enabled `static_sync_condvar` failure on this Windows host is an
  external `AccessDenied` launch problem against the built executable in
  `.zig-cache`, not the earlier package-local compile defect.
- `cancel_register_4` is materially lower than the pre-change local run, while
  the broader `cancel` lifecycle owner stays inside its prior benchmark band.
- polling-fallback contention still behaves as a noisy host-thread diagnostic
  surface, but it now does less avoidable spinning and the package test/model
  surfaces stayed green after the change.
- single-permit semaphore wakeups no longer create avoidable broadcast fanout,
  and parking-backed `Event.set()` avoids redundant wake work without
  regressing the default uncontended fast path.

## Reopen triggers

- Reopen if `static_sync_condvar` regresses back into a package-local compile
  failure or if the current Windows `AccessDenied` launch issue is shown to
  come from package behavior rather than the host environment.
- Reopen if a later benchmark run shows `cancel` registration cost climbing
  back into the earlier pre-filter range without a deliberate semantic change.
- Reopen if polling-fallback waits or the contention watchdog again show a
  concrete CPU-burn or measurement-observer regression that this closure no
  longer bounds.
