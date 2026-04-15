# `static_scheduling` follow-up plan

Scope: task-graph and scheduler-oriented coordination utilities.

Status: follow-up closed on 2026-04-01. The exported-surface proof map is
complete, the deterministic exported-surface gap queue is explicitly closed,
the canonical benchmark set is recorded, and the remaining boundary/root plus
shared-harness extraction review has been resolved.

## Current posture

- `static_scheduling` now has named proof ownership across the exported
  scheduling surfaces, including task-graph replay, timer-wheel model /
  temporal / exploration / replay proofs, direct `poller` regressions, and the
  bounded `thread_pool` wakeup, drain, and backpressure slices.
- Keep the root `core` alias and keep the root `sync` alias: both remain
  narrow, truthful dependency entry points for downstream users and do not
  create a second scheduler-local policy layer.
- No queue-overlap helper remains to review; the stale `static_queues`
  dependency/import wiring is already removed, and the package keeps queue
  ownership downstream.
- Keep the timer-queue explore / replay scenario scaffolding local. The shared
  fixture, scheduler, exploration runner, retained record, and provenance
  mechanisms already live in `static_testing`; the remaining package-owned code
  is timer-queue-specific scenario setup plus package-specific assertions.

## Open follow-up triggers

- Reopen only if review identifies a concrete uncovered readiness, timeout,
  wakeup-order, or cancellation contract with an exact scheduling-surface
  owner.
- Revisit helper extraction only if another scheduler package starts
  duplicating the same timer-queue scenario scaffolding rather than just using
  the shared `static_testing` fixture/explore/replay surfaces directly.
- Revisit root aliases only if `core` or `sync` stop being narrow dependency
  entry points and start implying scheduler-owned policy.
