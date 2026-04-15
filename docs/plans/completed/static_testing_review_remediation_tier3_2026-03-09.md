# Plan: `static_testing` review remediation tier 3

Date: 2026-03-09 (America/Denver)
Status: Completed (Moved)
Source review: `docs/plans/completed/static_testing_review_2026-03-09.md`
Package: `packages/static_testing`

## Goal

Close the remaining hygiene and audit gaps after the first two remediation passes:

- strengthen benchmark control-plane contracts and assertions;
- add direct examples for the main uncovered public surfaces; and
- leave the package tree free of generated local build artifacts after validation.

## Remediation scope

### Benchmark control-plane audit

- [x] Strengthen `packages/static_testing/src/bench/config.zig` validation assertions and postconditions.
- [x] Harden `packages/static_testing/src/bench/compare.zig` to reject internally inconsistent stats summaries before comparison.
- [x] Strengthen `packages/static_testing/src/bench/runner.zig` preconditions and result-shape assertions.
- [x] Add regression coverage for any new benchmark control-plane validation rules.

### Direct examples

- [x] Add a direct corpus persistence example for `packages/static_testing/src/testing/corpus.zig`.
- [x] Add a direct trace JSON export example for `packages/static_testing/src/testing/trace.zig`.
- [x] Add a raw protocol encode/decode example for `packages/static_testing/src/testing/driver_protocol.zig`.
- [x] Add a direct scheduler replay example for `packages/static_testing/src/testing/sim/scheduler.zig`.
- [x] Add a benchmark export-format example for `packages/static_testing/src/bench/export.zig`.
- [x] Add a large-run scratch-stats example for `packages/static_testing/src/bench/stats.zig`.
- [x] Wire new examples into `packages/static_testing/build.zig`.

### Hygiene

- [x] Remove local package build artifacts under `packages/static_testing/.zig-cache/` after validation.

### Validation

- [x] Run `zig build test` in `packages/static_testing`.
- [x] Run `zig build integration` in `packages/static_testing`.
- [x] Run `zig build examples` in `packages/static_testing`.
- [x] Run `zig build bench -Doptimize=ReleaseFast` in `packages/static_testing`.
- [x] Move this plan to `docs/plans/completed/` when remediation is done.
