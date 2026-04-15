# Workspace Validation Root Cause Report 2026-04-04

## Scope

This report records the root-level validation results observed on April 4, 2026
from the repository root on Windows (`x86_64-windows-gnu`) using the supported
commands from [`README.md`](../../../README.md).

Commands executed:

- `zig build docs-lint`
- `zig build check`
- `zig build test`
- `zig build harness`
- `zig build examples`
- `zig build bench`
- `zig build ci`

## Observed outcomes

1. `zig build docs-lint`
   Passed.
2. `zig build check`
   Passed.
3. `zig build test`
   Failed once, then passed on rerun.
   The failing run reported seed `0xa3d84fcf` and one failing test:
   `testing.root.test.lock-free stress tests validate bounded progress and conservation`.
4. `zig build harness`
   Passed.
   The output contains retained-failure and stress-demo text, but the command
   exits successfully.
5. `zig build examples`
   Passed.
6. `zig build bench`
   Passed.
   The output contains multiple `baseline_compare passed=false` sections, but
   the command exits successfully.
7. `zig build ci`
   Passed in the observed reruns.
   This is consistent with a flaky test rather than missing CI wiring because
   [`build.zig`](../../../build.zig) wires `ci` to `tests_step` at line 302.

## Primary root cause

The real repo-level failure is a flaky lock-free stress test in `static_queues`,
not a deterministic compile failure and not a simulation harness failure.

### Failing surface

- The failing assertion is in
  [`packages/static_queues/src/testing/lock_free_stress.zig`](../../../packages/static_queues/src/testing/lock_free_stress.zig)
  at line 106.
- The failure condition is `producer_failed == true`, not duplicate delivery,
  not out-of-range delivery, and not a direct data corruption signal.

### Why it flakes

The stress harness assumes that repeated `error.WouldBlock` results should be
rare enough that every producer can eventually complete within a fixed outer
retry budget. The queue implementation does not guarantee that.

Evidence:

- The stress harness config is aggressive:
  - `items_per_producer = 256` at line 17
  - `send_attempts_max = 8_192` at line 18
  - queue `capacity = 64` at line 22
  - producer failure is latched at lines 58-59
- The queue explicitly documents that `trySend` may return `error.WouldBlock`
  both when the queue is full and when contention exhausts the internal CAS
  retry bound:
  - [`packages/static_queues/src/queues/core/lock_free_mpsc.zig`](../../../packages/static_queues/src/queues/core/lock_free_mpsc.zig)
    line 5
  - `trySend` starts at line 132
  - CAS exhaustion returns `error.WouldBlock` at line 155
- The queue backoff is spin-only, not scheduler-yielding:
  - [`packages/static_sync/src/sync/backoff.zig`](../../../packages/static_sync/src/sync/backoff.zig)
    line 21
  - `std.atomic.spinLoopHint()` at line 30

### Root-cause statement

The test harness treats transient forward-progress loss as a hard correctness
failure. Under Windows scheduling and contention, producers can burn through:

- the queue's internal `cas_retries_max`
- the harness's outer `send_attempts_max`

without violating the queue's documented semantics. That makes the test a
timing-sensitive false negative: it fails because the harness demands stronger
progress guarantees than the queue contract currently provides.

## Secondary findings

### Harness output that looks like an error is expected

`zig build harness` prints text that looks like a failure, but the command
passes because some examples intentionally demonstrate retained-failure output.

Evidence:

- [`packages/static_testing/examples/model_sim_fixture.zig`](../../../packages/static_testing/examples/model_sim_fixture.zig)
  deliberately returns `checker.CheckResult.fail(...)` at line 115
- the same example asserts that a failed case must exist at line 245

This is diagnostic/demo output, not a harness regression.

### Benchmark regressions are reported but not build-gating

`zig build bench` emits many `baseline_compare passed=false` sections, but the
step still exits successfully because baseline comparison is non-gating unless
the workflow explicitly enables it.

Evidence:

- [`packages/static_testing/src/bench/workflow.zig`](../../../packages/static_testing/src/bench/workflow.zig)
  sets `enforce_gate: bool = false` at line 31
- it only returns `error.RegressionDetected` when `enforce_gate` is true at
  line 143

This is a reporting/triage surface, not the root command failure observed in
`zig build test`.

## Practical conclusion

There is one actual validation failure class observed at the root:

- flaky lock-free progress testing in `static_queues`

The other noisy outputs are expected by design:

- retained-failure and stress-demo text from `zig build harness`
- baseline regression text from `zig build bench`

## Recommended follow-up

1. Decide whether `LockFreeMpscQueue.trySend()` is supposed to provide bounded
   eventual progress under this stress shape, or only best-effort non-blocking
   behavior.
2. If best-effort non-blocking behavior is the intended contract, relax or
   rewrite `runLockFreeMpscStress()` so it does not convert repeated transient
   `WouldBlock` results into a correctness failure.
3. If stronger progress is intended, then the queue implementation needs a
   contract change and likely a different contention strategy than the current
   spin-only backoff plus fixed CAS retry bound.
4. If benchmark regressions should fail CI, wire the benchmark step through a
   workflow config that sets `enforce_gate = true`; otherwise keep treating the
   current `bench` output as review data rather than build failure.
