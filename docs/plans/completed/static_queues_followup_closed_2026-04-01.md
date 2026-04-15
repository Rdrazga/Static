# `static_queues` follow-up plan

Scope: queue, channel, inbox, outbox, and handoff structures.

Status: follow-up closed on 2026-04-01. The exported-family proof map is
complete, the blocking-protocol duplication decision is recorded, the package-
owned deterministic `SpscChannel` coordination queue is explicitly closed, and
the helper/benchmark/root reviews now live as recorded outcomes instead of
unfinished active work.

## Current posture

- `static_queues` now has package-owned deterministic coverage for the root
  `SpscChannel` coordination boundaries that were still open during the active
  sweep, including blocked-send / blocked-recv close ordering, timed-send /
  timed-recv close ordering, timed-recv buffered-item ordering, and timed-send /
  timed-recv progress ordering.
- The package-local `src/testing/` review is recorded: conformance helpers stay
  queue-family-local, while `lock_free_stress` remains the only move-later
  candidate if `static_testing` grows a shared bounded-progress stress surface.
- The canonical benchmark/root review is recorded: keep the existing queue
  benchmark executables and keep the root `core`, `memory`, and `sync` aliases.

## Open follow-up triggers

- Reopen only if review finds a concrete uncovered coordination, handoff, or
  readiness contract with an exact queue-family owner.
- Add new exploration or simulation work only when a specific queue or channel
  boundary proves that the current deterministic slices are not enough.
- Revisit helper extraction only if `static_testing` grows a shared stress or
  conformance surface that can own the package-local helper without losing
  queue-specific invariants.
