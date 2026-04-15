# Plan: `static_testing` review remediation

Date: 2026-03-09 (America/Denver)
Status: Completed (Moved)
Source review: `docs/plans/completed/static_testing_review_2026-03-09.md`
Package: `packages/static_testing`

## Goal

Fix the highest-priority correctness and contract issues identified in the 2026-03-09 package review.

## Remediation scope

### Process driver

- [x] Fix `packages/static_testing/src/testing/process_driver.zig` shutdown to wait on the owned child in place.
- [x] Redesign `packages/static_testing/src/testing/process_driver.zig` receive semantics for oversized responses so the stream remains synchronized or the session becomes explicitly terminal.
- [x] Add regression coverage for the updated process-driver response semantics.

### Simulation and trace

- [x] Fix `packages/static_testing/src/testing/trace.zig` sequence-boundary append overflow.
- [x] Fix `packages/static_testing/src/testing/sim/scheduler.zig` to validate `ScheduleDecision.step_index` during replay.
- [x] Make `packages/static_testing/src/testing/sim/event_loop.zig` state-safe on trace/enqueue failure paths.
- [x] Add regression coverage for event-loop rollback and trace-boundary behavior.

### Replay and benchmark boundaries

- [x] Harden `packages/static_testing/src/testing/replay_artifact.zig` decode validation for inconsistent trace metadata.
- [x] Fix `packages/static_testing/src/bench/stats.zig` percentile rank overflow handling.
- [x] Fix `packages/static_testing/src/bench/process.zig` measured-run index overflow for prepare hooks.
- [x] Add regression coverage for replay-artifact and benchmark-boundary fixes.

### Documentation touch-ups

- [x] Add or improve public docs in the touched root and helper surfaces where the review found high-value gaps.

### Validation

- [x] Run `zig build test` in `packages/static_testing`.
- [x] Run `zig build integration` in `packages/static_testing`.
- [x] Run `zig build examples` in `packages/static_testing`.
- [x] Run targeted `zig build bench -Doptimize=ReleaseFast` in `packages/static_testing`.
- [x] Move this plan to `docs/plans/completed/` when remediation is done.
