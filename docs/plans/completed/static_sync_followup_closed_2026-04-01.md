# `static_sync` follow-up plan

Scope: synchronization primitives, cancellation, and coordination building
blocks.

Status: follow-up closed on 2026-04-01. The exported-surface proof map is
complete, the primitive-specific deterministic gap queue is explicitly closed,
and no concrete package-local follow-up remains today.

Reopen note:

- This closure remains the baseline record only.
- `static_sync` reopened on 2026-04-11 for the host-smoke teardown bug,
  benchmark discoverability, and broader benchmark/testing hardening, and that
  reopen is now closed under
  `docs/plans/completed/static_sync_benchmark_and_testing_hardening_closed_2026-04-11.md`.
- A focused post-hardening runtime/benchmark follow-up is also now closed under
  `docs/plans/completed/static_sync_runtime_and_benchmark_followup_closed_2026-04-11.md`.

## Current posture

- `static_sync` now has named deterministic proof ownership across the exported
  mutable primitives, including bounded host-thread regressions for `seqlock`,
  `once`, `cancel`, `event`, `condvar`, `barrier`, `semaphore`, and
  `wait_queue`, plus package-owned model, replay, and simulation coverage
  where those are the better fit.
- `cancel` now has explicit coverage for in-flight `unregister()`,
  fixed-capacity registration, slot reuse, cancel-during-registration,
  multi-registration fanout, and reset-after-fanout re-registration.
- `caps` remains intentionally closed as inline-test-only because it has no
  mutable runtime state.

## Open follow-up triggers

- Reopen only if review finds a concrete uncovered wakeup, timeout, misuse, or
  sequence contract with an exact source owner.
- Add broader benchmark or retained-artifact work only if downstream review
  pressure shows the current primitive proofs are not enough.
- Revisit package boundaries only if queue or scheduler policy starts leaking
  into `static_sync` rather than staying downstream.
