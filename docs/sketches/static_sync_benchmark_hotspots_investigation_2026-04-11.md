# `static_sync` benchmark hotspots investigation

Date: 2026-04-11

Scope: analyze the current `static_sync` benchmark hotspots after the recent
benchmark-surface expansion and watchdog hardening, then record the most
credible issue hypotheses, the likely benchmark-shape confounders, and the
best proof steps before changing implementation behavior.

This is a live sketch. It is intentionally hypothesis-oriented rather than a
closure record.

## Inputs

- `packages/static_sync/src/sync/once.zig`
- `packages/static_sync/src/sync/grant.zig`
- `packages/static_sync/src/sync/cancel.zig`
- `packages/static_sync/src/sync/barrier.zig`
- `packages/static_sync/src/sync/seqlock.zig`
- `packages/static_sync/src/sync/event.zig`
- `packages/static_sync/src/sync/semaphore.zig`
- `packages/static_core/src/core/time_budget.zig`
- `packages/static_sync/benchmarks/once_and_grant_baselines.zig`
- `packages/static_sync/benchmarks/cancel_lifecycle_baselines.zig`
- `packages/static_sync/benchmarks/barrier_phase_baselines.zig`
- `packages/static_sync/benchmarks/seqlock_baselines.zig`
- `packages/static_sync/benchmarks/timeout_path_baselines.zig`
- `packages/static_sync/benchmarks/contention_baselines.zig`
- `packages/static_sync/benchmarks/support.zig`
- current `baseline.zon` artifacts under `.zig-cache/static_sync/benchmarks/`

## Method

1. Re-run the current benchmark owners on the same host.
2. Compare current medians and tails against the recorded baselines.
3. Read the implementation code for each hot area.
4. Separate likely implementation hotspots from benchmark-shape or
   environment-shape artifacts.
5. Record proof steps that can falsify each hypothesis cleanly.

## Iteration 1: raw benchmark signals

The strongest current signals were:

- `once_first_call_cycle`: baseline about `11.88 ns/op`, current about
  `16.24 ns/op`
- `grant_issue_validate_write`: baseline about `8.85 ns/op`, current about
  `15.97 ns/op`
- `grant_record_write_dedup`: baseline about `5.96 ns/op`, current about
  `8.83 ns/op`
- `cancel_fanout_4`: baseline about `156.38 ns/op`, current about
  `195.85 ns/op`
- `barrier_phase_cycle_4`: median only slightly higher than baseline, but
  current tail much worse
- `seqlock_read_begin_retry_stable`: baseline about `1.64 ns/op`, current
  about `2.95 ns/op`
- `seqlock_write_cycle`: baseline about `23.33 ns/op`, current about
  `32.20 ns/op`
- `event_timed_wait_timeout_zero`: current median still cheap, but one sample
  had a large tail spike
- default `static_sync_contention` on the no-OS-backend path regressed badly
  after the watchdog change
- `-Denable_os_backends=true static_sync_contention` passed and looked
  materially healthier, including the new `wait_queue` case

Immediate suspicion from the raw data:

- `once`, `seqlock` write, and `barrier` all share `std.Thread.Mutex` on the
  measured path, so there may be a common mutex-side cost or jitter story.
- `grant` regressions are probably not a mutex story because `Grant` has no
  host-thread synchronization.
- the default contention regressions are more likely a benchmark-shape artifact
  than a primitive regression because the watchdog change replaced unbounded
  waits with sliced `timedWait(...)` loops inside the timed path.

## Iteration 2: code-path facts

### 1. `Once` first-call cycle

Facts from `once.zig`:

- `Once.call(...)` does an acquire load on `done`.
- first-call path enters `callSlow(...)`.
- `callSlow(...)` takes a mutex, does a monotonic load, an acquire load, may
  execute the callback, stores `done = true` with release ordering, then the
  caller performs another acquire load in the postcondition.
- the benchmark case in `once_and_grant_baselines.zig` measures:
  fresh `Once` construction, one full first-call path, and one already-done
  fast-path call.

Important implication:

- the current owner is not measuring the first-call path in isolation. It is
  measuring:
  one mutex-protected slow path plus one extra acquire-load-only call.

### 2. `Grant` issue/validate and record-write paths

Facts from `grant.zig`:

- `grantWrite(...)` calls `grant(...)`, which calls `findResourceIndex(...)`
  and may search the fixed array linearly.
- `issueToken(...)` checks `hasAccess(...)`, then calls `canConsume(...)`,
  which does another `findResourceIndex(...)`.
- `validateToken(...)` checks metadata fields, then calls `hasAccess(...)`
  again, and may call `canConsume(...)` for consume tokens.
- `recordWrite(...)` checks `canWrite(...)`, then `wasWritten(...)`, then
  after insertion calls `wasWritten(...)` again for the assertion.
- `wasWritten(...)` is also a linear scan over the write records.
- the current benchmark owners construct a fresh grant and then measure
  multi-operation composite flows rather than one helper at a time.

Important implication:

- even the simplest one-resource benchmark case still pays several tiny linear
  scans and duplicate helper calls per measured op.

### 3. `Cancel` fanout

Facts from `cancel.zig` and `cancel_lifecycle_baselines.zig`:

- `CancelRegistration.register(...)` linearly scans the fixed registration
  array with `cmpxchgStrong(...)`.
- `CancelSource.cancel(...)` linearly scans the full registration array,
  swaps out each slot, and calls the registered callback.
- the benchmark case named `cancel_fanout_4` includes:
  source construction, registration of all callbacks, cancel, callback atomic
  increments, result checking, and unregister cleanup.

Important implication:

- the measured case is heavily over-composed. A regression in
  `cancel_fanout_4` does not by itself tell us whether the issue is in
  registration, callback dispatch, callback body cost, cancellation slot walk,
  or unregister cleanup.

### 4. `Barrier` phase cycle

Facts from `barrier.zig` and `barrier_phase_baselines.zig`:

- `Barrier.arrive(...)` takes a mutex on every arrival.
- the final arrival of a phase broadcasts the condvar when parking waits are
  supported, even if no waiters are actually blocked.
- the current benchmark owner does not use `arriveAndWait(...)` or a second
  thread. It performs four sequential `arrive(...)` calls on one thread and
  then checks the generation.

Important implication:

- the current owner is mostly a mutex-plus-final-broadcast benchmark for the
  no-waiter path, not a benchmark of real barrier rendezvous behavior.

### 5. `SeqLock`

Facts from `seqlock.zig` and `seqlock_baselines.zig`:

- stable reads use only `seq.load(.acquire)` and `readRetry(...)`.
- write cycles take `writer_mutex.lock()`, then do `fetchAdd(...)` twice on the
  padded sequence counter.
- the stable-read benchmark uses a fresh stack `SeqLock` each iteration.
- the write benchmark uses a fresh stack `SeqLock` and one full mutex-backed
  write cycle each iteration.

Important implication:

- the stable-read case is so tiny that host noise and stack/allocation shape
  can distort ratios quickly.
- the write case is another mutex-bearing path and should be compared against
  the `Once` and `Barrier` mutex-bearing signals before assuming a seqlock-only
  regression.

### 6. Default contention benchmark after watchdog hardening

Facts from `contention_baselines.zig`:

- the bounded watchdog design uses timed wait slices inside the timed callback.
- event contention now loops on `event.timedWait(5 ms)` rather than `event.wait()`.
- semaphore contention now loops on `semaphore.timedWait(5 ms)` rather than
  `semaphore.wait()`.
- on the no-OS-backend path, `event.timedWait(...)` and
  `semaphore.timedWait(...)` use `TimeoutBudget.init(...)` and
  `remainingOrTimeout(...)` in retry loops rather than a direct blocking wait.
- on the OS-backend-enabled path, the underlying blocking primitives can park
  more truthfully and the benchmark currently looks much healthier.

Facts from `time_budget.zig`:

- `TimeoutBudget.init(...)` calls `std.time.Instant.now()` for positive timeouts.
- `remainingOrTimeout(...)` calls `std.time.Instant.now()` again on each check.

Important implication:

- the current no-OS-backend contention owner is measuring watchdog-enforced
  timeout-budget overhead in the success path.
- that violates the original design intent that watchdog logic should not
  contaminate the timed portion of successful runs.

### 7. Zero-timeout event timed wait

Facts from `event.zig` and `time_budget.zig`:

- `event.timedWait(0)` should return `error.Timeout` immediately through
  `TimeoutBudget.init(0)` without entering the loop.
- the current regression is almost entirely one bad sample; the median stayed
  cheap.

Important implication:

- this currently looks much more like benchmark-sample noise or host
  preemption than a logic-level event timeout regression.

## Iteration 3: refined hypotheses

### A. High-confidence benchmark-shape issue: default no-OS-backend contention numbers are contaminated by watchdog enforcement

Why this is likely:

- the regression appeared only after the watchdog refactor;
- the code path now uses `timedWait(...)` slices directly in the timed loop;
- `timedWait(...)` on the no-OS-backend path pays timeout-budget clock queries
  in the hot loop;
- the OS-backend-enabled contention run is much more stable and passed.

How to prove:

1. Add a diagnostic owner that runs the same ping-pong flow with direct
   `wait()` calls under a child-process or process-benchmark watchdog.
2. Compare:
   current in-process timed-slice owner vs process-isolated true-wait owner.
3. If the process-isolated owner drops back near the earlier numbers, the
   regression belongs to the benchmark design, not the primitives.

Best improvement direction:

- move blocking contention owners to a process-benchmark or equivalent external
  kill/watchdog surface so the timed path can use the real primitive wait path.

### B. High-confidence implementation/attribution issue: `Grant` paths do repeated tiny linear scans and helper fan-out

Why this is likely:

- the code directly shows repeated `findResourceIndex(...)`,
  `hasAccess(...)`, `canConsume(...)`, and `wasWritten(...)` passes;
- the benchmark cases are composite enough that the repeated scans stack.

How to prove:

1. Add benchmark owners for:
   `grant_write_admit_single_resource`,
   `grant_issue_token_single_resource`,
   `grant_validate_token_single_resource`,
   `grant_record_write_insert`,
   `grant_record_write_duplicate_hit`.
2. Add temporary counters or a compile-time instrumentation branch to count
   `findResourceIndex(...)` and `wasWritten(...)` calls per benchmark op.
3. Compare current helper fan-out against a refactor that carries the found
   resource index forward through the call chain.

Best improvement direction:

- fuse helper lookups so the one-resource common path does not rescan the same
  fixed arrays repeatedly;
- split the benchmark owner so it stops hiding where the cost sits.

### C. High-confidence attribution issue: `cancel_fanout_4` is too composite to localize

Why this is likely:

- the benchmark includes registration, slot search, callback dispatch,
  callback atomic increments, and unregister;
- the regression size is modest enough that any one of those pieces could be
  responsible.

How to prove:

1. Split the owner into:
   `cancel_register_4`,
   `cancel_only_4_preinstalled`,
   `cancel_callback_noop_4`,
   `cancel_callback_atomic_counter_4`,
   `cancel_unregister_after_cancel_4`.
2. Compare atomic-increment callbacks against noop callbacks.
3. Compare preinstalled registrations against fully composed setup-per-op.

Best improvement direction:

- keep the full-lifecycle owner, but add decomposed owners so the suite can
  explain whether registration search, callback execution, or cleanup is the
  real hotspot.

### D. Medium-confidence shared-root issue: mutex-backed fast paths may have a common drift source

Affected signals:

- `once_first_call_cycle`
- `seqlock_write_cycle`
- `barrier_phase_cycle_4`

Why this is plausible:

- all three touch `std.Thread.Mutex` on the measured path;
- their regressions are directionally aligned even though the surrounding
  logic differs.

What lowers confidence:

- `Grant` regressed too, and it does not use mutexes;
- `Barrier` is benchmarking a synthetic no-waiter closure path rather than a
  real rendezvous;
- some of the observed movement may still be host jitter.

How to prove:

1. Add one small `mutex_lock_unlock` reference owner for the same build mode
   and host.
2. Add one decomposed `once_first_call_only` owner without the second done
   fast-path call.
3. Add one decomposed `seqlock_write_lock_unlock_only` owner.
4. Compare correlation across repeated runs.

Best improvement direction:

- if the mutex reference moves with these cases, treat the issue as a shared
  host or toolchain cost before changing `Once`, `Barrier`, or `SeqLock`
  semantics.

### E. Medium-confidence benchmark-design issue: `barrier_phase_cycle_4` measures the wrong behavior for performance diagnosis

Why this is likely:

- it is single-threaded;
- it always includes the final-arrival condvar broadcast when parking waits are
  supported;
- it has no blocked waiters, so it is not exercising actual rendezvous cost.

How to prove:

1. Add:
   `barrier_arrive_close_no_waiters_4`,
   `barrier_arrive_and_wait_2`,
   `barrier_arrive_and_wait_4`.
2. Compare the tail behavior of no-waiter broadcast against true waiting
   rendezvous.
3. Run the same owners with and without OS backends.

Best improvement direction:

- keep the current synthetic closure owner only as a reference, not as the
  package’s main barrier-performance signal.

### F. Medium-confidence mixed issue: `SeqLock` stable-read regression is real enough to watch, but too small to trust from one microbenchmark alone

Why this is mixed:

- absolute cost is still tiny;
- the owner is extremely small and sensitive to sample noise;
- the write-path regression can be partially explained by the broader mutex
  story, but the stable-read path cannot.

How to prove:

1. Add:
   `seqlock_read_begin_only`,
   `seqlock_read_retry_stable_only`,
   `seqlock_read_begin_retry_persistent_lock`.
2. Re-run several times to see whether the stable-read median stays near
   `~3 ns/op` or snaps back near `~1.6 ns/op`.
3. Compare fresh-stack vs persistent-context owners.

Best improvement direction:

- do not change `SeqLock` semantics yet; first tighten the benchmark shape.

### G. Low-confidence implementation issue: `event_timed_wait_timeout_zero` is currently a tail-noise story, not a strong product bug signal

Why this is low confidence:

- `timedWait(0)` should return immediately through the zero-timeout fast exit;
- the median remained cheap;
- one outlier sample dominated the tail.

How to prove:

1. Re-run the owner several times.
2. Add a process benchmark for the zero-timeout path if we need stronger
   tail isolation.
3. If only the tail keeps jumping while the median stays flat, treat it as
   host variance rather than an event implementation problem.

## Priority proof order

1. Prove or falsify contention-watchdog contamination on the no-OS-backend
   path.
   Reason:
   the code path already strongly suggests benchmark contamination.
2. Decompose the `Grant` owners.
   Reason:
   this is the strongest likely implementation-side hotspot.
3. Decompose `cancel_fanout_4`.
   Reason:
   the current owner hides attribution.
4. Add a mutex reference owner and compare `Once`, `Barrier`, and `SeqLock`
   write-side movement against it.
5. Tighten the `Barrier` and `SeqLock` owners so they measure the intended
   behavior more directly.
6. Treat the zero-timeout event tail only as a secondary cleanup unless it
   reproduces repeatedly.

## Best current assessment

The current hotspot set is not one thing.

Most likely categories:

- real implementation-attribution work needed:
  `Grant`, and possibly parts of `Cancel`
- benchmark-design cleanup needed:
  default no-OS-backend contention, `Barrier`, and some of the `SeqLock`
  owners
- host-tail noise to watch but not overreact to yet:
  zero-timeout event and the smallest same-process microcases

The most important refined conclusion is this:

- the recent bounded-watchdog work improved safety and failure reporting, but
  it also likely changed the measurement contract for the in-process blocking
  contention owners.

That does not invalidate the hardening work. It does mean the next round
should treat benchmark-truthfulness as the first problem to solve before
interpreting every contention regression as a primitive bug.
