# Plan: `static_testing` review remediation tier 4

Date: 2026-03-09 (America/Denver)
Status: Completed (Moved)
Source review: `docs/plans/completed/static_testing_review_2026-03-09.md`
Package: `packages/static_testing`

## Goal

Address the remaining review surface after the first three remediation passes:

- broaden the benchmark suite to cover additional public surfaces; and
- improve test-rationale comments in the higher-value control-plane and replay/simulation tests.

## Remediation scope

### Benchmark expansion

- [x] Add a replay-artifact encode/decode benchmark under `packages/static_testing/benchmarks/`.
- [x] Add a scheduler decision/replay benchmark under `packages/static_testing/benchmarks/`.
- [x] Wire the new benchmarks into `packages/static_testing/build.zig`.
- [x] Assert semantic postconditions for the new benchmark inputs before timing.

### Test rationale comments

- [x] Add top-of-test rationale comments in `packages/static_testing/src/bench/config.zig`.
- [x] Add top-of-test rationale comments in `packages/static_testing/src/bench/compare.zig`.
- [x] Add top-of-test rationale comments in `packages/static_testing/src/bench/runner.zig`.
- [x] Add top-of-test rationale comments in `packages/static_testing/src/testing/replay_artifact.zig`.
- [x] Add top-of-test rationale comments in `packages/static_testing/src/testing/sim/scheduler.zig`.

### Validation

- [x] Run `zig build test` in `packages/static_testing`.
- [x] Run `zig build integration` in `packages/static_testing`.
- [x] Run `zig build examples` in `packages/static_testing`.
- [x] Run `zig build bench -Doptimize=ReleaseFast` in `packages/static_testing`.
- [x] Remove local package build artifacts under `packages/static_testing/.zig-cache/` after validation.
- [x] Move this plan to `docs/plans/completed/` when remediation is done.
