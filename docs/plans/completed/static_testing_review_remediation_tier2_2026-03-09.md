# Plan: `static_testing` review remediation tier 2

Date: 2026-03-09 (America/Denver)
Status: Completed (Moved)
Source review: `docs/plans/completed/static_testing_review_2026-03-09.md`
Package: `packages/static_testing`

## Goal

Address the next tier of review findings after the first correctness pass:

- build and packaging hygiene;
- timeout cleanup error semantics;
- generated-doc coverage for simulation wrappers;
- benchmark/example semantics that should model package expectations more clearly.

## Remediation scope

### Build and packaging

- [x] Export `packages/static_testing/benchmarks` in `packages/static_testing/build.zig.zon`.
- [x] Replace name-based example option wiring in `packages/static_testing/build.zig` with explicit example metadata.

### Timeout cleanup semantics

- [x] Remove panic-on-cleanup behavior from `packages/static_testing/src/bench/process.zig`.
- [x] Remove panic-on-cleanup behavior from `packages/static_testing/src/testing/process_driver.zig`.

### Documentation and usage posture

- [x] Add `///` coverage to the main public simulation wrapper methods in `packages/static_testing/src/testing/sim/clock.zig`.
- [x] Add `///` coverage to the main public simulation wrapper methods in `packages/static_testing/src/testing/sim/fault_script.zig`.
- [x] Add `///` coverage to the main public simulation wrapper methods in `packages/static_testing/src/testing/sim/mailbox.zig`.
- [x] Add `///` coverage to the main public simulation wrapper methods in `packages/static_testing/src/testing/sim/scheduler.zig`.
- [x] Add `///` coverage to the main public simulation wrapper methods in `packages/static_testing/src/testing/sim/timer_queue.zig`.
- [x] Document the by-value payload guidance for mailbox and timer-queue generic payloads.
- [x] Make benchmark programs assert their semantic postconditions before timing.
- [x] Make `packages/static_testing/examples/fuzz_seeded_runner.zig` treat output-directory cleanup as explicit best effort instead of panicking.

### Validation

- [x] Run `zig build test` in `packages/static_testing`.
- [x] Run `zig build integration` in `packages/static_testing`.
- [x] Run `zig build examples` in `packages/static_testing`.
- [x] Run `zig build bench -Doptimize=ReleaseFast` in `packages/static_testing`.
- [x] Move this plan to `docs/plans/completed/` when remediation is done.
