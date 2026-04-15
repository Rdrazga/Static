# Plan: `static_testing` Package Review Checklist

Date: 2026-03-08 (America/Denver)
Status: Completed (Moved)
Package: `packages/static_testing`
Review: `docs/sketches/static_testing_review_2026-03-08.md`

## How to use this checklist

- For each file, review: API shape, assertions/invariants, error semantics, bounds/limits, allocation behavior, performance footguns, test coverage, docs/comments.
- Record findings in `docs/sketches/static_testing_review_2026-03-08.md`.
- Check boxes as each item is reviewed.

## Checklist

### Package hygiene

- [x] Audit committed artifacts (`.zig-cache/`, `phase2_fuzz_test-*.bin`) and recommend keep/remove + `.gitignore` posture.
- [x] Confirm package has a clear "how to run tests/examples" entry point (build steps and/or docs).

### Build system

- [x] Review `packages/static_testing/build.zig`.
- [x] Review `packages/static_testing/build.zig.zon`.

### Public root

- [x] Review `packages/static_testing/src/root.zig`.

### Bench subsystem (`packages/static_testing/src/bench/`)

- [x] Review `packages/static_testing/src/bench/root.zig`.
- [x] Review `packages/static_testing/src/bench/config.zig`.
- [x] Review `packages/static_testing/src/bench/case.zig`.
- [x] Review `packages/static_testing/src/bench/group.zig`.
- [x] Review `packages/static_testing/src/bench/runner.zig`.
- [x] Review `packages/static_testing/src/bench/timer.zig`.
- [x] Review `packages/static_testing/src/bench/stats.zig`.
- [x] Review `packages/static_testing/src/bench/compare.zig`.
- [x] Review `packages/static_testing/src/bench/export.zig`.
- [x] Review `packages/static_testing/src/bench/process.zig`.

### Testing subsystem (`packages/static_testing/src/testing/`)

- [x] Review `packages/static_testing/src/testing/root.zig`.
- [x] Review `packages/static_testing/src/testing/seed.zig`.
- [x] Review `packages/static_testing/src/testing/identity.zig`.
- [x] Review `packages/static_testing/src/testing/trace.zig`.
- [x] Review `packages/static_testing/src/testing/replay_artifact.zig`.
- [x] Review `packages/static_testing/src/testing/replay_runner.zig`.
- [x] Review `packages/static_testing/src/testing/corpus.zig`.
- [x] Review `packages/static_testing/src/testing/reducer.zig`.
- [x] Review `packages/static_testing/src/testing/checker.zig`.
- [x] Review `packages/static_testing/src/testing/fuzz_runner.zig`.
- [x] Review `packages/static_testing/src/testing/driver_protocol.zig`.
- [x] Review `packages/static_testing/src/testing/process_driver.zig`.

### Simulation subsystem (`packages/static_testing/src/testing/sim/`)

- [x] Review `packages/static_testing/src/testing/sim/root.zig`.
- [x] Review `packages/static_testing/src/testing/sim/clock.zig`.
- [x] Review `packages/static_testing/src/testing/sim/checkpoint.zig`.
- [x] Review `packages/static_testing/src/testing/sim/timer_queue.zig`.
- [x] Review `packages/static_testing/src/testing/sim/mailbox.zig`.
- [x] Review `packages/static_testing/src/testing/sim/scheduler.zig`.
- [x] Review `packages/static_testing/src/testing/sim/fault_script.zig`.
- [x] Review `packages/static_testing/src/testing/sim/event_loop.zig`.

### Tests (`packages/static_testing/tests/`)

- [x] Review `packages/static_testing/tests/integration/root.zig`.
- [x] Review `packages/static_testing/tests/integration/replay_roundtrip.zig`.
- [x] Review `packages/static_testing/tests/integration/fuzz_persistence.zig`.
- [x] Review `packages/static_testing/tests/integration/process_bench_smoke.zig`.
- [x] Review `packages/static_testing/tests/integration/process_driver_roundtrip.zig`.
- [x] Review `packages/static_testing/tests/integration/sim_schedule_replay.zig`.
- [x] Review `packages/static_testing/tests/support/driver_echo.zig`.

### Examples (`packages/static_testing/examples/`)

- [x] Review `packages/static_testing/examples/replay_roundtrip.zig`.
- [x] Review `packages/static_testing/examples/bench_smoke.zig`.
- [x] Review `packages/static_testing/examples/fuzz_seeded_runner.zig`.
- [x] Review `packages/static_testing/examples/sim_timer_mailbox.zig`.

### Cross-file / cross-package review

- [x] Verify error vocabulary matches workspace patterns (no swallowed errors, no `anyerror` at boundaries).
- [x] Verify determinism contract: seeded RNG usage, stable ordering, stable serialization.
- [x] Verify bounds and limits: fixed capacities, bounded loops, explicit maximums.
- [x] Verify allocation policy: hot paths do not allocate; allocations are bounded and in setup paths.
- [x] Verify assertion density and "pair assertions" on critical invariants.
- [x] Verify doc posture: `//!` module docs, `///` public API docs, example coverage, and `zig doc` compatibility.
- [x] Benchmark assessment: what to benchmark, what to compare against, and how to keep benchmarks honest.

### Validation

- [x] Run `zig build test` in `packages/static_testing`.
- [x] Run `zig build integration` in `packages/static_testing`.
- [x] Run `zig build examples` in `packages/static_testing`.
- [x] Run `zig build smoke` in `packages/static_testing`.
- [x] (Optional) Run workspace-root `zig build test --summary all` and note regressions.
