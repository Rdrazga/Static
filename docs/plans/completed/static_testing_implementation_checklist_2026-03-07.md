# Plan: `static_testing` Implementation Master Checklist

Date: 2026-03-07 (America/Denver)
Status: Completed
Target package: `packages/static_testing`

## Goal

Track implementation of `static_testing` from package creation through final validation, using the detailed architecture, file-spec, and atomic-task sketches as the design baseline.

## Source Sketches

- `docs/sketches/static_testing_capability_sketch_2026-03-07.md`
- `docs/sketches/static_testing_architecture_2026-03-07.md`
- `docs/sketches/static_testing_file_specs_2026-03-07.md`
- `docs/sketches/static_testing_atomic_tasks_2026-03-07.md`

## Execution Rules

- Work phases in order unless a dependency-free documentation or review task can be pulled forward safely.
- Keep implementation, assertions, tests, and docs together for each logical slice.
- Do not mark a file group complete until its unit tests or smoke tests exist and pass.
- Run cross-review tasks at phase boundaries, not only at the end.
- Move this plan to `docs/plans/completed/` only after final package validation and residual issue review.

## Checklist

### Phase 1: Foundation

- [x] Complete Phase 1 foundation.
  - [x] `src/root.zig`
    - [x] `ST-ROOT-01` Add package root docs and export wiring.
  - [x] `src/testing/root.zig`
    - [x] `ST-TROOT-01` Export phase-1 testing modules only.
  - [x] `src/testing/seed.zig`
    - [x] `ST-SEED-01` Define `Seed` and decimal/hex parse helpers.
    - [x] `ST-SEED-02` Add `formatSeed`.
    - [x] `ST-SEED-03` Add `splitSeed` and `deriveNamedSeed`.
  - [x] `src/testing/identity.zig`
    - [x] `ST-ID-01` Define `ArtifactVersion` and `BuildMode`.
    - [x] `ST-ID-02` Define `RunIdentity`.
    - [x] `ST-ID-03` Add `identityHash`.
  - [x] `src/testing/trace.zig`
    - [x] `ST-TRACE-01` Define `TraceCategory`, `TraceEvent`, and bounded storage config.
    - [x] `ST-TRACE-02` Implement `TraceBuffer.init`, `append`, and `reset`.
    - [x] `ST-TRACE-03` Add snapshot/view helper.
    - [x] `ST-TRACE-04` Add export adapter for profile/timeline output.
  - [x] `src/testing/replay_artifact.zig`
    - [x] `ST-ART-01` Define header magic/version/layout constants.
    - [x] `ST-ART-02` Implement minimal encode path for identity and trace metadata.
    - [x] `ST-ART-03` Implement minimal decode path.
    - [x] `ST-ART-04` Add explicit borrowed `ReplayArtifactView`.
  - [x] `src/testing/checker.zig`
    - [x] `ST-CHECK-01` Define `Violation` and `CheckResult`.
    - [x] `ST-CHECK-02` Define generic checker callback contract.
    - [x] `ST-CHECK-03` Add checkpoint digest helper type.
  - [x] `src/bench/root.zig`
    - [x] `ST-BROOT-01` Export phase-1 benchmark modules.
  - [x] `src/bench/config.zig`
    - [x] `ST-BCFG-01` Define `BenchmarkMode` and `BenchmarkConfig`.
    - [x] `ST-BCFG-02` Implement `validateConfig`.
  - [x] `src/bench/timer.zig`
    - [x] `ST-BTIMER-01` Define timer abstraction and state.
    - [x] `ST-BTIMER-02` Implement `start` and `stop`.
  - [x] `src/bench/case.zig`
    - [x] `ST-BCASE-01` Define `BenchmarkCase` metadata and callback type.
    - [x] `ST-BCASE-02` Add `blackBox` and keepalive helper.
  - [x] `src/bench/group.zig`
    - [x] `ST-BGROUP-01` Define `BenchmarkGroup`.
    - [x] `ST-BGROUP-02` Implement iterator/filter helpers.
  - [x] `src/bench/runner.zig`
    - [x] `ST-BRUN-01` Define raw sample/result structs.
    - [x] `ST-BRUN-02` Implement single-case smoke-mode runner.
    - [x] `ST-BRUN-03` Implement group runner.
  - [x] `src/bench/export.zig`
    - [x] `ST-BEXPORT-01` Implement text export.
    - [x] `ST-BEXPORT-02` Implement JSON export.
    - [x] `ST-BEXPORT-03` Implement CSV/Markdown export.
  - [x] Examples, integration tests, and package build.
    - [x] `ST-EX-01` Add `examples/replay_roundtrip.zig`.
    - [x] `ST-EX-02` Add `examples/bench_smoke.zig`.
    - [x] `ST-ITEST-01` Add `tests/integration/replay_roundtrip.zig`.
    - [x] `ST-BUILD-01` Create package `build.zig` with `test` and `examples`.

### Phase 2: Replay / Fuzz Depth

- [x] Complete Phase 2 replay and fuzz depth.
  - [x] `src/testing/replay_runner.zig`
    - [x] `ST-RRUN-01` Define replay target contract and outcome enum.
    - [x] `ST-RRUN-02` Implement basic artifact replay.
  - [x] `src/testing/corpus.zig`
    - [x] `ST-CORPUS-01` Define corpus metadata and naming scheme.
    - [x] `ST-CORPUS-02` Implement write/read helpers.
  - [x] `src/testing/reducer.zig`
    - [x] `ST-REDUCE-01` Define reduction budget and step result.
    - [x] `ST-REDUCE-02` Implement fixed-point reduction driver.
  - [x] `src/testing/fuzz_runner.zig`
    - [x] `ST-FUZZ-01` Define `FuzzConfig` and per-case result types.
    - [x] `ST-FUZZ-02` Implement deterministic case loop with split seeds.
    - [x] `ST-FUZZ-03` Integrate persistence on failure.
    - [x] `ST-FUZZ-04` Integrate reducer on failure.
  - [x] Examples and integration tests.
    - [x] `ST-EX-03` Add `examples/fuzz_seeded_runner.zig`.
    - [x] `ST-ITEST-02` Add `tests/integration/fuzz_persistence.zig`.

### Phase 3: Benchmark Expansion

- [x] Complete Phase 3 benchmark expansion.
  - [x] `src/bench/stats.zig`
    - [x] `ST-BSTATS-01` Define `BenchmarkStats`.
    - [x] `ST-BSTATS-02` Implement mean/median/min/max.
    - [x] `ST-BSTATS-03` Implement percentile helpers.
  - [x] `src/bench/compare.zig`
    - [x] `ST-BCMP-01` Define comparison result type.
    - [x] `ST-BCMP-02` Implement stats comparison.
  - [x] `src/bench/process.zig`
    - [x] `ST-BPROC-01` Define process benchmark config and case types.
    - [x] `ST-BPROC-02` Implement single-command smoke benchmark with warmups excluded.
    - [x] `ST-BPROC-03` Add env/args/prepare-hook support.
  - [x] Integration tests.
    - [x] `ST-ITEST-03` Add `tests/integration/process_bench_smoke.zig`.

### Phase 4: Simulation And End-To-End

- [x] Complete Phase 4 simulation and end-to-end support.
  - [x] `src/testing/driver_protocol.zig`
    - [x] `ST-DPROTO-01` Define wire headers and version constants.
    - [x] `ST-DPROTO-02` Implement encode/decode helpers.
  - [x] `src/testing/process_driver.zig`
    - [x] `ST-PDRV-01` Define process-driver config and lifecycle state.
    - [x] `ST-PDRV-02` Implement spawn and shutdown.
    - [x] `ST-PDRV-03` Implement request/response exchange.
  - [x] `src/testing/sim/clock.zig`
    - [x] `ST-SCLOCK-01` Define logical time/duration types.
    - [x] `ST-SCLOCK-02` Implement advance/jump APIs.
  - [x] `src/testing/sim/timer_queue.zig`
    - [x] `ST-STIMER-01` Wrap `static_scheduling.timer_wheel` behind a simulation-friendly API.
  - [x] `src/testing/sim/mailbox.zig`
    - [x] `ST-SMAIL-01` Wrap `static_queues.ring_buffer` as typed mailbox.
  - [x] `src/testing/sim/fault_script.zig`
    - [x] `ST-SFAULT-01` Define fault kinds and script entry shape.
    - [x] `ST-SFAULT-02` Implement script validation and due-fault lookup.
  - [x] `src/testing/sim/checkpoint.zig`
    - [x] `ST-SCHK-01` Define checkpoint digest wrapper and compare helper.
  - [x] `src/testing/sim/scheduler.zig`
    - [x] `ST-SSCHED-01` Define scheduler config and decision record.
    - [x] `ST-SSCHED-02` Implement deterministic ready-set selection.
    - [x] `ST-SSCHED-03` Implement replay of recorded decisions.
  - [x] `src/testing/sim/event_loop.zig`
    - [x] `ST-SEVENT-01` Define event loop config and stop conditions.
    - [x] `ST-SEVENT-02` Implement single-step orchestration.
    - [x] `ST-SEVENT-03` Implement run loop with budgets.
  - [x] Examples and integration tests.
    - [x] `ST-EX-04` Add `examples/sim_timer_mailbox.zig`.
    - [x] `ST-ITEST-04` Add `tests/integration/sim_schedule_replay.zig`.
    - [x] `ST-ITEST-05` Add `tests/integration/process_driver_roundtrip.zig`.
    - [x] `ST-SUP-01` Add `tests/support/driver_echo.zig` and build wiring.

### Cross-Review And Package Signoff

- [x] Complete cross-review and signoff.
  - [x] Planning review tasks.
    - [x] `ST-XREV-01` Review architecture sketch against file specs.
    - [x] `ST-XREV-02` Review atomic tasks against file specs.
    - [x] `ST-XREV-03` Review all planning sketches against the capability sketch.
  - [x] Package validation.
    - [x] Run package unit tests.
    - [x] Run package integration tests.
    - [x] Run package examples.
    - [x] Review new code for remaining correctness, assertion, error-handling, documentation, and test-coverage gaps.
  - [x] Documentation closeout.
    - [x] Update sketches if implementation forced any design corrections.
    - [x] Record any residual follow-up items separately instead of leaving them implicit.
    - [x] Move this plan to `docs/plans/completed/` once validation passes.

## Validation Record

- `zig build integration --summary all` in `packages/static_testing` passed: `7/7`.
- `zig build smoke --summary all` in `packages/static_testing` passed: `7/7` integration tests plus the selected smoke examples.
- `zig build test --summary all` in `packages/static_testing` passed: `87/87`.
- `zig build examples --summary all` in `packages/static_testing` passed.
- `zig build test --summary all` at the workspace root passed: `1039/1078`, `39` skipped.
- `zig build examples --summary all` at the workspace root passed.

## Residual Follow-Up

- A higher-level `testing.driver` facade remains optional; the implemented Phase 4 surface is `driver_protocol` plus `process_driver`.
- Richer simulated network and disk transports remain future simulation-layer work.
