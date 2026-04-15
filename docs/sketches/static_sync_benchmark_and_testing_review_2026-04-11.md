# `static_sync` benchmark and testing review

Date: 2026-04-11

Scope: determine the current issues in `static_sync`, then audit its testing
and benchmarking posture against the same stricter standard used for
`static_ecs`:

1. benchmark coverage should make likely performance hangups visible and
   explainable;
2. test coverage should stay robust under misuse, partial failure, retained
   replay, host instability assumptions, and bounded hostile exploration.

This is a sketch review. It records the current package posture, concrete
issues found during inspection, and the improvement backlog needed to reopen
`static_sync` cleanly.

## Review method

- Read package guidance:
  `packages/static_sync/README.md`,
  `packages/static_sync/AGENTS.md`,
  and `docs/plans/completed/static_sync_followup_closed_2026-04-01.md`.
- Read the concrete integration tests under
  `packages/static_sync/tests/integration/`.
- Read the package-owned benchmark owners under
  `packages/static_sync/benchmarks/`.
- Read the source inline-test surface under `packages/static_sync/src/sync/`.
- Inspect root build wiring in `build.zig`.
- Reuse the concrete failure already surfaced by `zig build test` during the
  earlier workspace review and verify its root cause in
  `tests/integration/host_wait_smoke.zig`.

## Validation notes

- The package test surface is reachable only through the root `zig build test`
  integration wiring.
- During the workspace test run, `packages/static_sync/tests/integration/host_wait_smoke.zig`
  timed out waiting for a worker-start flag, then the test process later
  segfaulted inside the worker thread.
- The segfault is explainable from the test code itself:
  `host_wait_smoke.zig` returns early on timeout before joining or otherwise
  containing the spawned thread. That leaves the worker thread still holding
  pointers to stack-owned test state after the test frame unwinds.
- `zig build -h` does not currently expose direct named `static_sync`
  benchmark steps, even though the benchmark executables are defined in
  `build.zig`.

## Immediate concrete issue

### 1. `host_wait_smoke.zig` has a real teardown bug that can turn a timeout into a crash

Evidence:

- Each host-smoke case spawns a worker thread with pointers to stack-owned
  context.
- The main test path calls `waitForFlag(..., 100 * std.time.ns_per_ms)`.
- On timeout, the test returns `error.Timeout` before joining the spawned
  thread or isolating the crash in a child process.
- The earlier root test failure showed exactly that shape: timeout first,
  segfault second, with the worker crashing while storing into a
  `waiter_started` atomic.

Impact:

- A scheduler delay or host hiccup in one smoke test can become memory-unsafe
  test behavior instead of a bounded failure report.
- This is a real package issue, not only a flaky environment artifact.

Minimum fix direction:

- never let these tests return before the worker is joined or otherwise
  terminated safely;
- use a child-process wrapper for intentionally crashy or timeout-sensitive
  host smoke when cleanup cannot be guaranteed inside the same process;
- widen the startup timeout or use a deterministic ready handshake that proves
  the worker reached the blocking point rather than only "thread has started
  running."

## Current testing posture

Compared with `static_ecs`, `static_sync` already uses the shared testing
surfaces much more broadly.

Strengths:

- inline source tests are extensive across `barrier`, `cancel`, `condvar`,
  `event`, `grant`, `once`, `semaphore`, `seqlock`, and `wait_queue`;
- integration tests use `testing.model`, `fuzz_runner`, replay persistence,
  `testing.sim`, and temporal assertions;
- misuse-path coverage exists for zero-timeout semantics and cancel lifecycle;
- host-thread smoke exists for event, semaphore, wait_queue, and condvar
  handoff behavior.

That is a strong base. The review gaps are mostly about robustness, realism,
and benchmark clarity rather than total absence of shared-harness adoption.

## Testing findings

### 2. Shared-harness adoption is real, but some package-owned campaigns are still too synthetic to count as strong primitive hardening

Evidence:

- `replay_fuzz_sync_primitives.zig` runs deterministic fuzz campaigns for
  event, semaphore, and cancel state machines.
- `fuzz_persistence_sync.zig` proves persistence and replay of a reduced
  failing seed, but the failing condition is an artificial threshold over
  `seed.value`, not a real primitive bug class or a reduced semantic failure.

Impact:

- The package does exercise the replay and persistence machinery.
- Part of that coverage is still validating the harness more than validating
  `static_sync` primitive behavior.

Improvement direction:

- keep the harness-smoke style proof, but add retained reduced failures tied to
  real primitive invariants or real reduced misuse scenarios rather than only
  threshold-triggered synthetic failures.

### 3. Model coverage is good, but narrow relative to the package surface

Evidence:

- `testing.model` is used for barrier generation semantics and seqlock token
  parity.
- There is no comparable model target for event, semaphore, cancel, wait_queue,
  once, or grant.

Impact:

- Two important primitives have bounded shadow-model proof.
- The package still lacks model-backed sequence exploration for several other
  stateful surfaces, especially wakeup and registration lifecycles.

Improvement direction:

- add bounded model targets for at least wait_queue wake/cancel/timeout
  rotation, cancel registration lifecycle, and one event or semaphore
  progression story where the current replay fuzz is too shallow.

### 4. Host-smoke coverage is useful but currently brittle and under-instrumented

Evidence:

- `host_wait_smoke.zig` uses a 100 ms startup wait budget for event,
  semaphore, wait_queue, and condvar tests.
- It uses a coarse "worker_started" flag rather than a proof that the worker
  is actually blocked in the intended wait.
- It does not isolate failure in a child process.
- It does not capture retained failure context or richer diagnostic metadata on
  timeout.

Impact:

- The smoke surface can fail spuriously on slow or noisy hosts.
- When it fails, diagnostics are weaker than they should be and can cascade
  into unsafe teardown.

Improvement direction:

- replace start-only handshakes with blocking-point handshakes where practical;
- isolate timeout-sensitive smoke in child processes or equivalent bounded
  wrappers;
- emit more concrete diagnostics about which handshake step failed.

### 5. Simulation and temporal coverage is meaningful, but still concentrated on wait_queue and condvar

Evidence:

- `sim_wait_protocols.zig` exercises wait_queue wake-before-timeout,
  condvar broadcast protocol, and condvar timeout protocol through simulation
  and temporal assertions.
- There is no comparable `testing.sim` or temporal proof for event, semaphore,
  once, cancel, or barrier host-bound wait/wake protocols.

Impact:

- The package has one clear success case for using the shared simulator well.
- Temporal and schedule-exploration confidence is still uneven across the
  broader primitive set.

Improvement direction:

- extend schedule-exploration only where it adds real value:
  event set/reset/wait ordering, semaphore permit handoff plus timeout
  ordering, and cancel wake ordering are the best next fits.

### 6. Retained failure posture is mostly ephemeral

Evidence:

- replay and fuzz tests use `std.testing.tmpDir()` and validate that the shared
  persistence path works during the test;
- the package does not appear to keep package-owned retained reproducers or a
  durable in-repo failure corpus for reduced primitive failures.

Impact:

- The package proves persistence mechanics, but not a durable retained bug
  backlog.
- When a real reduced failure appears later, the current posture offers less
  repository memory than the newer retained-failure pattern used elsewhere.

Improvement direction:

- keep the tmpdir harness checks, but add explicit package-owned retained
  replay inputs when a real reduced primitive failure family exists.

## Benchmark posture

`static_sync` has two benchmark owners:

- `benchmarks/fast_paths.zig`
- `benchmarks/contention_baselines.zig`

The existing suite is small and pragmatic, but it now lags behind the more
recent benchmark discipline visible in packages like `static_ecs`.

## Benchmark findings

### 7. Benchmark coverage is too narrow for the package surface

Covered today:

- uncontended fast paths for event, semaphore, cancel, and once;
- bounded contention handoff for event, semaphore, and wait_queue;
- thread spawn/join baseline for interpretation.

Missing:

- barrier fast path and reusable phase progression cost;
- cancel registration, unregister, reset, and fanout cost;
- seqlock reader begin/retry and write lock/unlock under read-heavy and
  write-heavy contention;
- condvar signal and broadcast handoff cost;
- once contended caller cost;
- grant token issue/validation cost;
- wait primitive timeout path cost.

Impact:

- The benchmark suite does not yet represent the breadth of the package.
- Performance regressions in several exported primitives could land with no
  canonical benchmark owner watching them.

### 8. Benchmark observability is elapsed-time oriented and weaker than newer package owners

Evidence:

- both benchmark owners manually call
  `bench.workflow.writeTextAndOptionalBaselineReport`;
- neither owner forwards explicit `environment_note` or `environment_tags`;
- there is no package-local support helper analogous to the newer ECS benchmark
  support module;
- the output focuses on timing only and does not emit primitive-specific shape
  facts such as handoff count, capability gating, or blocking-support status in
  benchmark history metadata.

Impact:

- benchmark history is less informative for compatibility filtering and
  cross-host interpretation than the newer package owners;
- the package pays repeated benchmark-workflow boilerplate and makes future
  observability improvements harder to apply consistently.

Improvement direction:

- add a shared package-local benchmark support helper;
- forward explicit environment notes and bounded tags;
- record primitive and workload shape metadata needed to interpret the timing.

### 9. Root benchmark discoverability is weaker than it should be

Evidence:

- `build.zig` defines the static_sync benchmark executables internally;
- `zig build -h` does not expose direct named steps for those owners;
- direct attempts to run `zig build static_sync_fast_paths` and
  `zig build static_sync_contention` failed with "no step named ..."

Impact:

- the canonical benchmark owners are harder to iterate directly than the newer
  ECS owners;
- this hurts review speed and makes the package benchmark surface less
  self-explanatory.

Improvement direction:

- expose direct named root build steps for the canonical static_sync owners and
  keep them aligned with the aggregate `zig build bench` surface.

### 10. Contention benchmarks have no bounded watchdog or failure-reporting path

Evidence:

- `contention_baselines.zig` spawns worker threads and runs ping-pong loops
  with blocking waits;
- it relies on `catch unreachable` and unconditional joins;
- there is no timeout or bounded abort path if a primitive deadlocks or a host
  backend misbehaves.

Impact:

- if a contention benchmark regresses into a deadlock, the benchmark surface is
  more likely to hang than to fail cleanly with a useful report;
- this is the benchmark analogue of the host-smoke brittleness issue.

Improvement direction:

- add bounded watchdog behavior or a deterministic timeout harness around the
  contention owners so hangs become reportable benchmark failures rather than
  indefinite stalls.

## Overall assessment

`static_sync` is ahead of `static_ecs` in shared testing adoption. It already
uses model, replay, fuzz, simulation, temporal checks, host smoke, and a broad
inline test map.

Its current weaknesses are different:

- one concrete host-smoke bug can turn a timeout into a crash;
- parts of the replay/fuzz surface still validate the harness more than the
  primitives;
- model and sim coverage are real but uneven across the exported primitive set;
- benchmark coverage and benchmark ergonomics lag behind the package's claimed
  maturity.

Short version:

- tests: broad and modern, but one real host-smoke bug plus several realism and
  retention gaps;
- benchmarks: serviceable, but too narrow and less disciplined than the newer
  package owners.

## Recommended improvement order

1. Fix `host_wait_smoke.zig` first.
   Priority:
   - safe teardown on timeout;
   - stronger worker-ready handshake;
   - child-process isolation where same-process failure cannot be contained.
2. Normalize benchmark ergonomics.
   Priority:
   - add direct root build steps for static_sync benchmark owners;
   - add a package-local support helper;
   - forward environment notes and bounded tags into history metadata.
3. Expand benchmark coverage to the uncovered exported primitives.
   Priority:
   - seqlock;
   - cancel registration/fanout;
   - barrier;
   - condvar;
   - once contention;
   - grant token issue/validation.
4. Broaden model and simulation coverage where they add real value.
   Priority:
   - cancel registration lifecycle;
   - wait_queue or semaphore timeout/cancel ordering;
   - one event wake/reset ordering story.
5. Replace synthetic replay/fuzz persistence-only proof with retained
   primitive-facing reduced failures when real failure families exist.
6. Add bounded watchdog handling around contention benchmarks so hangs fail
   cleanly.

## Bottom line

`static_sync` does not need the same kind of foundational shared-harness
adoption push that `static_ecs` needs. It already has that. The package does
need a reopen for host-smoke safety, benchmark discoverability and coverage,
and more primitive-facing retained/adversarial proof rather than harness-smoke
only proof.
