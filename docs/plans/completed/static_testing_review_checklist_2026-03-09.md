# Plan: `static_testing` package review checklist

Date: 2026-03-09 (America/Denver)
Status: Completed (Moved)
Package: `packages/static_testing`
Review: `docs/plans/completed/static_testing_review_2026-03-09.md`

## Goal

Perform a fresh file-by-file review of `packages/static_testing` for:

- Zig and general best practices.
- Conformance with `agents.md`.
- Testing best practices, assertion strategy, error semantics, and negative-space coverage.
- Comments, doc comments, example coverage, and `zig doc` readiness.
- Performance footguns, benchmark quality, and benchmark gaps.

## Review method

- Review each file in package order and add findings to `docs/plans/completed/static_testing_review_2026-03-09.md`.
- Check each item only after its findings are recorded.
- Finish with a cross-file synthesis and validation pass.

## Checklist

### Package hygiene and structure

- [x] Review package layout, generated artifacts, and package-level entry points.
- [x] Review benchmark posture and benchmark scope against package responsibilities.

### Build metadata

- [x] Review `packages/static_testing/build.zig`.
- [x] Review `packages/static_testing/build.zig.zon`.

### Package root

- [x] Review `packages/static_testing/src/root.zig`.

### Bench subsystem

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

### Testing subsystem

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

### Simulation subsystem

- [x] Review `packages/static_testing/src/testing/sim/root.zig`.
- [x] Review `packages/static_testing/src/testing/sim/clock.zig`.
- [x] Review `packages/static_testing/src/testing/sim/checkpoint.zig`.
- [x] Review `packages/static_testing/src/testing/sim/timer_queue.zig`.
- [x] Review `packages/static_testing/src/testing/sim/mailbox.zig`.
- [x] Review `packages/static_testing/src/testing/sim/scheduler.zig`.
- [x] Review `packages/static_testing/src/testing/sim/fault_script.zig`.
- [x] Review `packages/static_testing/src/testing/sim/event_loop.zig`.

### Benchmarks

- [x] Review `packages/static_testing/benchmarks/stats.zig`.
- [x] Review `packages/static_testing/benchmarks/timer_queue.zig`.

### Examples

- [x] Review `packages/static_testing/examples/bench_smoke.zig`.
- [x] Review `packages/static_testing/examples/fuzz_seeded_runner.zig`.
- [x] Review `packages/static_testing/examples/process_bench_smoke.zig`.
- [x] Review `packages/static_testing/examples/process_driver_roundtrip.zig`.
- [x] Review `packages/static_testing/examples/replay_roundtrip.zig`.
- [x] Review `packages/static_testing/examples/replay_runner_roundtrip.zig`.
- [x] Review `packages/static_testing/examples/sim_timer_mailbox.zig`.

### Integration tests and support

- [x] Review `packages/static_testing/tests/integration/root.zig`.
- [x] Review `packages/static_testing/tests/integration/fuzz_persistence.zig`.
- [x] Review `packages/static_testing/tests/integration/process_bench_smoke.zig`.
- [x] Review `packages/static_testing/tests/integration/process_driver_roundtrip.zig`.
- [x] Review `packages/static_testing/tests/integration/replay_roundtrip.zig`.
- [x] Review `packages/static_testing/tests/integration/sim_schedule_replay.zig`.
- [x] Review `packages/static_testing/tests/support/driver_echo.zig`.

### Cross-file synthesis

- [x] Review error vocabulary and error-path coverage across the package.
- [x] Review assertion density, pair assertions, and invalid-input handling boundaries.
- [x] Review comments, `//!` / `///` coverage, and generated-doc readiness.
- [x] Review allocation discipline, boundedness, and hot-path performance posture.
- [x] Review example coverage and identify missing usage demonstrations.
- [x] Review benchmark coverage and recommend additions or deferrals.

### Validation

- [x] Run `zig build test` in `packages/static_testing`.
- [x] Run `zig build integration` in `packages/static_testing`.
- [x] Run `zig build examples` in `packages/static_testing`.
- [x] Run `zig build bench -Doptimize=ReleaseFast` in `packages/static_testing`.
- [x] Move this checklist to `docs/plans/completed/` when the review is complete.
