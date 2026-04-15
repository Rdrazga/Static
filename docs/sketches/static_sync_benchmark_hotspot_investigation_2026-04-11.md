# `static_sync` Benchmark Hotspot Investigation

Date: 2026-04-11
Status: live working sketch
Owner: Codex

## Purpose

This sketch is the follow-on investigation surface after the broader
`static_sync` benchmark and testing review. It focuses on benchmark hotspots
and on separating three different classes of problems:

1. a real primitive regression;
2. a benchmark owner that is too composite to localize cost; and
3. a benchmark shape change that now measures watchdog or fallback machinery
   rather than the primitive the case name implies.

The goal is to iteratively build hypotheses, state how to prove or falsify
them, and turn the strongest signals into implementation work.

## Inputs

Benchmark rerun surface from 2026-04-11:

- `zig build static_sync_fast_paths`
- `zig build static_sync_contention`
- `zig build static_sync_cancel_lifecycle`
- `zig build static_sync_barrier_phase`
- `zig build static_sync_once_and_grant`
- `zig build static_sync_seqlock`
- `zig build static_sync_timeout_path`
- `zig build -Denable_os_backends=true static_sync_contention`

Observed results driving this sketch:

- `once_first_call_cycle`: `16.235 ns/op`, baseline fail.
- `grant_issue_validate_write`: `15.967 ns/op`, baseline fail.
- `grant_record_write_dedup`: `8.826 ns/op`, baseline fail.
- `cancel_fanout_4`: `195.850 ns/op`, baseline fail.
- `barrier_phase_cycle_4`: `46.216 ns/op`, baseline fail on tail.
- `seqlock_read_begin_retry_stable`: `2.954 ns/op`, baseline fail.
- `seqlock_write_cycle`: `32.202 ns/op`, baseline fail.
- `event_timed_wait_timeout_zero`: `1.807 ns/op`, baseline fail on tail.
- `static_sync_contention` without OS backends: baseline fail with very noisy
  tails.
- `static_sync_contention` with OS backends enabled: pass.

## Iteration 1: Raw Signal Triage

### Group A: likely real or at least actionable benchmark-attribution problems

- `once_and_grant`
- `cancel_fanout_4`

These cases show broad regression signals rather than one isolated outlier.
They also mix multiple operations into one benchmark callback, which means they
already need decomposition even if the primitive code itself is fine.

### Group B: likely mixed primitive cost plus shared-host jitter

- `barrier_phase_cycle_4`
- `seqlock_write_cycle`

Both exercise a `std.Thread.Mutex`-protected write or phase path:

- `Once.callSlow()` locks `self.mutex` in
  `packages/static_sync/src/sync/once.zig:27-29`.
- `SeqLock.writeLock()` and `writeUnlock()` use `writer_mutex` in
  `packages/static_sync/src/sync/seqlock.zig:23-35`.
- `Barrier.arrive()` locks `state_mutex` in
  `packages/static_sync/src/sync/barrier.zig:253-260`.

That creates a reasonable shared hypothesis around mutex fast-path drift or
host scheduling noise.

### Group C: likely benchmark-shape or host-noise artifact first

- `static_sync_contention` without OS backends
- `event_timed_wait_timeout_zero`
- `seqlock_read_begin_retry_stable`

These are either extremely tiny timing targets or cases whose measurement shape
changed materially when bounded watchdog logic was added.

## Iteration 2: Code-Path Inspection

### `once_first_call_cycle`

Current benchmark owner:
`packages/static_sync/benchmarks/once_and_grant_baselines.zig:31-41`

What the case actually measures:

- construct `Once`;
- first `once.call(noop)`;
- second `once.call(noop)` on the already-done fast path;
- two postcondition loads of `done`.

Relevant primitive code:

- fast path early return in `packages/static_sync/src/sync/once.zig:18-25`
- slow path mutex + store in `packages/static_sync/src/sync/once.zig:27-46`

Current hypothesis set:

- H1 medium confidence: the regression is mostly the mutex-backed first-call
  path, not the second-call done fast path.
- H2 medium confidence: the benchmark is too composite to isolate whether the
  extra time comes from lock/unlock, release-store publication, or the extra
  verification loads.
- H3 lower confidence: this is shared toolchain or host drift on tiny code, not
  a meaningful package-local regression.

How to prove:

1. Split the owner into:
   - first-call only;
   - done-fast-path only;
   - first-call plus publication readback.
2. Add a sibling benchmark that measures plain `std.Thread.Mutex` lock/unlock
   with the same config to see whether the drift is cross-cutting.
3. If the isolated done-fast-path remains stable while the first-call case
   regresses, treat `callSlow()` as the primary investigation target.

Improvement ideas:

- add benchmark decomposition before changing `once.zig`;
- only consider structural `Once` changes if the decomposed owner still points
  at `callSlow()` rather than generic mutex drift.

### `grant_issue_validate_write` and `grant_record_write_dedup`

Current benchmark owner:
`packages/static_sync/benchmarks/once_and_grant_baselines.zig:43-70`

Relevant primitive code:

- `issueToken()` in `packages/static_sync/src/sync/grant.zig:199-220`
- `validateToken()` in `packages/static_sync/src/sync/grant.zig:231-247`
- `recordWrite()` in `packages/static_sync/src/sync/grant.zig:255-268`
- `wasWritten()` in `packages/static_sync/src/sync/grant.zig:270-281`
- `hasAccess()` in `packages/static_sync/src/sync/grant.zig:321-328`
- `findResourceIndex()` in `packages/static_sync/src/sync/grant.zig:330-339`

Important code facts:

- `issueToken()` calls `hasAccess()`, which calls `findResourceIndex()`.
- `validateToken()` calls `hasAccess()` again and may also call
  `canConsume()`, which calls `findResourceIndex()` again.
- `recordWrite()` calls `canWrite()` then `wasWritten()`.
- `wasWritten()` linearly scans the write record list.

Current hypothesis set:

- H1 high confidence: the benchmark owners are too composite to localize cost.
- H2 medium confidence: the current grant implementation pays repeated tiny
  linear scans and repeated access checks even in the simple one-resource,
  one-write benchmark shape.
- H3 lower confidence: the recorded baseline is simply stale after assertions
  and safety checks were strengthened elsewhere.

How to prove:

1. Split grant benchmarking into:
   - `grant_issue_token_write`;
   - `grant_validate_token_read`;
   - `grant_validate_token_write`;
   - `grant_record_write_first`;
   - `grant_record_write_duplicate`;
   - `grant_was_written_hit`.
2. Add a parameter sweep over `resource_count` and `write_count` so cost growth
   from the linear scans becomes visible.
3. Inspect generated assembly only after the isolated cases show a stable
   regression.

Improvement ideas:

- keep the existing combined benchmark as an end-to-end semantic lifecycle case,
  but add decomposed cases for attribution;
- if grant remains hot after decomposition, consider caching the resource index
  within an issued token or providing a more index-oriented internal path.

### `cancel_fanout_4`

Current benchmark owner:
`packages/static_sync/benchmarks/cancel_lifecycle_baselines.zig:61-89`

Relevant primitive code:

- registration slot scan and install in
  `packages/static_sync/src/sync/cancel.zig:78-119`
- unregister path in `packages/static_sync/src/sync/cancel.zig:121-141`
- cancel fanout scan in `packages/static_sync/src/sync/cancel.zig:158-170`

Important code facts:

- The benchmark does not isolate `CancelSource.cancel()`.
- It includes:
  - four `register()` calls;
  - one `cancel()` call;
  - four callback atomic increments;
  - four `unregister()` calls;
  - callback total aggregation.

Current hypothesis set:

- H1 high confidence: the benchmark name overstates how much of the measured
  time belongs to the cancel fanout loop itself.
- H2 medium confidence: the fixed-capacity registration scan may dominate more
  than the actual fanout on small registration counts.
- H3 lower confidence: the callback atomic increments are a larger share than
  expected at this scale.

How to prove:

1. Split into:
   - `cancel_register_4`;
   - `cancel_fanout_only_4` with preinstalled registrations in `prepare_fn`;
   - `cancel_unregister_4_after_fire`;
   - `cancel_callback_atomic_only_4` as a reference.
2. Add a count sweep over `1`, `4`, `8`, and `16` registrations to expose
   scaling of both registration and cancel scan paths.
3. Record slot occupancy shape in environment or case metadata so regressions
   can be tied to sparse versus dense registration arrays.

Improvement ideas:

- make `prepare_fn` set up the registration matrix outside the timed callback;
- keep one end-to-end lifecycle case, but treat it as a workflow metric, not
  the only attribution surface.

### `barrier_phase_cycle_4`

Current benchmark owner:
`packages/static_sync/benchmarks/barrier_phase_baselines.zig:37-55`

Relevant primitive code:

- `Barrier.arrive()` in `packages/static_sync/src/sync/barrier.zig:253-260`
- phase close path in `arriveInner()` at
  `packages/static_sync/src/sync/barrier.zig:373-394`

Important code fact:

- The benchmark does not measure `arriveAndWait()` with real parked or spinning
  waiters.
- It measures four sequential `arrive()` calls from one thread, then one
  `tryWait()` check.

Current hypothesis set:

- H1 high confidence: the current owner is a phase-close microbenchmark, not a
  representative cyclic barrier contention benchmark.
- H2 medium confidence: the tail regression comes from mutex or broadcast noise
  rather than barrier generation arithmetic.
- H3 lower confidence: repeated single-thread use is stressing a code path that
  package consumers do not care about as much as real multi-thread phase waits.

How to prove:

1. Add a true contention owner using `arriveAndWait()` with `2` and `4` parties.
2. Split the current owner into:
   - non-final arrival cost;
   - final arrival phase-close cost.
3. Compare the final-arrival owner against a mutex-only reference benchmark.

Improvement ideas:

- keep the current case, but rename it to make its semantics explicit;
- add real barrier wait/handoff benchmarks before treating this result as a
  user-facing hotspot.

### `seqlock_read_begin_retry_stable` and `seqlock_write_cycle`

Current benchmark owner:
`packages/static_sync/benchmarks/seqlock_baselines.zig:30-67`

Relevant primitive code:

- reader fast path in `packages/static_sync/src/sync/seqlock.zig:37-53`
- retry check in `packages/static_sync/src/sync/seqlock.zig:57-67`
- writer path in `packages/static_sync/src/sync/seqlock.zig:23-35`

Current hypothesis set:

- H1 medium confidence: `seqlock_write_cycle` is affected by the same
  mutex-backed drift hypothesis as `Once` and `Barrier`.
- H2 medium confidence: `seqlock_read_begin_retry_stable` is too tiny for a
  meaningful regression signal unless it repeats over many runs.
- H3 lower confidence: assertion density and the padded atomic layout are now a
  larger fraction of the cost than the actual sequence arithmetic.

How to prove:

1. Re-run the isolated seqlock owner several times and compare variance.
2. Split the benchmark into:
   - `read_begin_only_stable`;
   - `read_retry_only_stable`;
   - `write_lock_unlock_only`;
   - `write_cycle_plus_readback`.
3. Add a mutex lock/unlock reference case under the same config.

Improvement ideas:

- avoid code changes to `SeqLock` until the decomposed cases show whether the
  signal belongs to read load cost or writer mutex cost;
- if writer cost remains meaningfully elevated, inspect whether the writer mutex
  can be kept but made less entangled with benchmark verification logic.

### `event_timed_wait_timeout_zero`

Current benchmark owner:
`packages/static_sync/benchmarks/timeout_path_baselines.zig:31-45`

Relevant primitive code:

- immediate signaled return in `packages/static_sync/src/sync/event.zig:105-108`
- zero-budget timeout init in `packages/static_sync/src/sync/event.zig:109-112`

Important code fact:

- `timedWait(0)` on an unsignaled event should fail during
  `TimeoutBudget.init(timeout_ns)` before any blocking or timed condvar path.

Current hypothesis set:

- H1 high confidence: the median cost is still healthy and the failure is a tail
  outlier from host noise.
- H2 lower confidence: the timeout-budget helper itself is more variable on this
  host than expected.

How to prove:

1. Re-run the timeout owner multiple times and compare only the event zero-path.
2. Add a direct `TimeoutBudget.init(0)` reference benchmark under the same config.
3. If the event case still tails more than the raw timeout-budget case, inspect
   whether any early event loads are causing extra noise.

Improvement ideas:

- likely no primitive change needed;
- improve attribution by adding timeout-budget reference cases.

### `static_sync_contention` without OS backends

Current benchmark owner:
`packages/static_sync/benchmarks/contention_baselines.zig`

Relevant benchmark support:

- contention config in `packages/static_sync/benchmarks/support.zig:17-22`
- timed wait slice in `packages/static_sync/benchmarks/support.zig:76`
- watchdog timeout in `packages/static_sync/benchmarks/support.zig:77`

Relevant primitive behavior:

- `Event.timedWait()` falls back to timeout-budget plus spin-backoff when
  parking waits are unavailable in `packages/static_sync/src/sync/event.zig:144-152`.
- `Latch.timedWait()` does the same in
  `packages/static_sync/src/sync/barrier.zig:165-173`.

Current hypothesis set:

- H1 high confidence: the no-OS-backend contention owner now measures repeated
  `timedWait(contention_wait_slice_ns)` loop overhead plus spin fallback, not a
  clean primitive handoff baseline comparable to the old results.
- H2 high confidence: the very large `p95` spike on `event_ping_pong_256` is
  host scheduler noise interacting with the bounded watchdog wait-slice design.
- H3 lower confidence: there is a real regression in the non-parking fallback
  path itself, but current attribution is too weak to prove it.

How to prove:

1. Split contention reporting by capability class and keep doing so; do not
   compare non-parking fallback runs with parking-enabled history.
2. Add an explicit benchmark note that the threads-only owner is measuring
   bounded cooperative polling under watchdog control.
3. Add separate cases for:
   - pure spin/yield handoff reference;
   - `timedWait(5 ms)` loop reference with no cross-thread handoff;
   - actual event and semaphore ping-pong with OS parking enabled.

Improvement ideas:

- treat the no-OS-backend owner as a fallback-mode diagnostic, not as a direct
  replacement for the OS-backed blocking benchmark;
- consider a shorter wait slice or a different bounded strategy only after
  gathering the reference cases above.

## Cross-Cutting Hypothesis

There is a plausible shared factor around `std.Thread.Mutex` cost or host jitter
affecting several regressed cases:

- `Once.callSlow()` locks a mutex.
- `Barrier.arrive()` locks a mutex.
- `SeqLock.writeLock()` and `writeUnlock()` lock or unlock a mutex.
- `condvar` and `contention` owners also build on mutex-backed wait protocols.

This is not yet evidence of a `static_sync` bug. It is evidence that benchmark
owners need a small set of primitive-neutral reference cases:

- mutex lock/unlock;
- condvar signal round-trip;
- timeout-budget zero init;
- spin/yield handoff loop.

Those references would let future reports distinguish a package regression from
host or toolchain drift much faster.

## Iteration 3: Attribution Slice Results

The first attribution-hardening slice is now implemented in:

- `packages/static_sync/benchmarks/once_and_grant_baselines.zig`
- `packages/static_sync/benchmarks/cancel_lifecycle_baselines.zig`
- `packages/static_sync/benchmarks/benchmark_references.zig`

New isolated results from the current host:

- `once_first_call_only`: `12.109 ns/op`
- `once_done_fastpath_only`: `1.257 ns/op`
- `mutex_lock_unlock_uncontended`: `13.733 ns/op`
- `grant_issue_token_write`: `1.465 ns/op`
- `grant_validate_token_write`: `2.917 ns/op`
- `grant_record_write_first`: `2.087 ns/op`
- `grant_record_write_duplicate`: `2.087 ns/op`
- `grant_was_written_hit`: `1.257 ns/op`
- `cancel_register_4`: `252.441 ns/op`
- `cancel_fanout_only_4`: `8.191 ns/op`
- `cancel_unregister_4_after_fire`: `1.904 ns/op`
- `timeout_budget_init_zero`: `1.025 ns/op`

### Revised `Once` conclusion

The isolated `Once` result now points strongly at the first-call slow path
rather than the done fast path:

- `once_done_fastpath_only` is in the same tiny band as the cheaper reference
  cases.
- `once_first_call_only` is very close to the uncontended mutex reference.

Revised confidence:

- H1 high confidence: the dominant cost in `Once` is the expected mutex-backed
  first-call path.
- H2 lower confidence now: the old suspicion around the done fast path is not
  supported by the isolated data.

Updated action:

- do not treat `Once` as a primitive bug right now;
- keep it as a mutex-attributed reference point while moving investigation
  effort to barrier and seqlock, which still need the same decomposition.

### Revised `Grant` conclusion

The grant family no longer looks like the strongest product hotspot:

- issue-only, validate-only, first-write, duplicate-write, and written-hit
  cases are all low-single-digit nanoseconds;
- the older combined `grant_issue_validate_write` case is now much easier to
  interpret because the component operations are visible directly.

Revised confidence:

- H1 still high confidence: the older owner was too composite.
- H2 lower confidence now: repeated tiny scans exist in code, but they are not
  currently showing up as a meaningful microbenchmark problem at this scale.

Updated action:

- deprioritize `Grant` implementation changes;
- keep the decomposed cases and only reopen grant optimization if larger
  resource-count or write-count sweeps show nonlinear growth that matters.

### Revised `Cancel` conclusion

The cancel attribution split clearly changed the diagnosis:

- `cancel_fanout_only_4` is cheap at about `8.2 ns/op`;
- `cancel_unregister_4_after_fire` is cheaper still at about `1.9 ns/op`;
- `cancel_register_4` is the expensive isolated step at about `252 ns/op`;
- the older `cancel_fanout_4` combined lifecycle case is therefore dominated by
  registration work much more than by the cancel fanout loop itself.

Revised confidence:

- H1 high confidence: the old combined case was misleading as a "cancel cost"
  label.
- H2 high confidence: small-fanout lifecycle cost is driven primarily by
  registration-slot installation, not by `CancelSource.cancel()`.

Updated action:

- if cancel performance work is needed, inspect registration-slot scan and
  registration install first;
- do not spend time on `CancelSource.cancel()` itself until higher-count sweeps
  show a separate cancel-scan problem.

### Revised timeout-path conclusion

The zero-timeout reference helps explain the earlier event timeout-path signal:

- `timeout_budget_init_zero` is about `1.0 ns/op`;
- the earlier `event_timed_wait_timeout_zero` reading at about `1.8 ns/op`
  therefore looks like "timeout budget plus a very small event wrapper cost",
  not like a structural event-path hotspot.

Revised confidence:

- H1 high confidence: the event zero-timeout tail issue was almost certainly
  host noise rather than a real product regression.

Updated action:

- move event timeout-path investigation down the queue.

## Revised Ranking

After the attribution slice, the priority order changes:

1. replace or supplement `barrier_phase_cycle_4` with true `arriveAndWait()`
   contention owners;
2. split `seqlock` read and writer attribution further, using the mutex
   reference as the comparison point;
3. inspect `cancel_reset_reregister_cycle` tail behavior, because the new
   isolated cancel cases make that tail stand out more clearly;
4. keep `Grant`, `Once`, and zero-timeout `Event` in observation mode rather
   than active optimization mode unless later sweeps reopen them.

## Iteration 4: Barrier And SeqLock Attribution Results

The next attribution slice is now implemented in:

- `packages/static_sync/benchmarks/barrier_phase_baselines.zig`
- `packages/static_sync/benchmarks/barrier_wait_baselines.zig`
- `packages/static_sync/benchmarks/seqlock_baselines.zig`

New results from the current host:

- `barrier_arrive_nonfinal_4`: `11.389 ns/op`
- `barrier_arrive_final_4`: `12.622 ns/op`
- `barrier_phase_cycle_4`: `43.945 ns/op`
- `barrier_arrive_and_wait_2`: `261,057.813 ns/op`
- `seqlock_read_begin_only_stable`: `1.062 ns/op`
- `seqlock_read_retry_only_stable`: `1.025 ns/op`
- `seqlock_read_begin_retry_stable`: `1.648 ns/op`
- `seqlock_write_lock_unlock_only`: `21.948 ns/op`
- `seqlock_write_cycle`: `23.328 ns/op`
- `seqlock_write_invalidates_old_token`: `23.608 ns/op`

### Revised `Barrier` conclusion

The barrier surface is now much easier to interpret:

- the non-final arrival cost is about `11.4 ns/op`;
- the final arrival phase-close cost is only modestly higher at about
  `12.6 ns/op`;
- the older `barrier_phase_cycle_4` result at about `43.9 ns/op` is therefore
  the sum of four arrivals plus one `tryWait()` check, not evidence of an
  unexplained tail-heavy barrier primitive problem;
- the real two-party `arriveAndWait()` handoff path is much slower, at about
  `261 us/op`, which is the number that matters for actual blocking use.

Revised confidence:

- high confidence: the earlier barrier hotspot was a benchmark-shape ambiguity,
  not a localized primitive regression;
- medium confidence: the `arriveAndWait()` owner is now the correct barrier
  operational benchmark to watch for real handoff regressions.

Updated action:

- keep `barrier_phase_cycle_4` as a continuity case;
- treat `barrier_arrive_and_wait_2` as the main user-facing barrier benchmark;
- if barrier work is revisited later, compare the `arriveAndWait()` owner
  against condvar and event/semaphore contention owners rather than against the
  phase-close microbenchmarks.

### Revised `SeqLock` conclusion

The seqlock split also narrows the diagnosis:

- stable read-begin and read-retry are both about `1.0 ns/op`;
- the combined stable read case at about `1.65 ns/op` is consistent with those
  two tiny pieces together;
- writer lock/unlock alone is about `21.95 ns/op`;
- adding readback or invalidation checks only adds about `1.4-1.7 ns/op`.

Revised confidence:

- high confidence: the writer-side cost is the main seqlock cost center;
- high confidence: the reader-side fast path is healthy and no longer looks
  like a meaningful hotspot;
- medium confidence: writer cost is still basically in line with the mutex
  reference plus sequence-counter publication.

Updated action:

- keep seqlock in observation mode unless a later toolchain or host change
  moves `seqlock_write_lock_unlock_only` materially above the mutex reference;
- avoid primitive changes to the reader path, because the isolated read cases
  now look healthy.

## Revised Ranking After Barrier And SeqLock

1. inspect `cancel_reset_reregister_cycle` tail behavior, because the isolated
   cancel cases make that remaining tail signal stand out more clearly;
2. keep the no-OS-backend contention suite treated as a fallback polling
   diagnostic rather than a parking-equivalent baseline;
3. leave `Once`, `Grant`, `Barrier`, `SeqLock`, and zero-timeout `Event` in
   observation mode unless later sweeps reopen them.

## Iteration 5: Cancel Reset Tail And Fallback Metadata

The next follow-up slice landed in:

- `packages/static_sync/benchmarks/cancel_lifecycle_baselines.zig`
- `packages/static_sync/benchmarks/contention_baselines.zig`
- `packages/static_sync/benchmarks/support.zig`

New cancel reset attribution results from the current host:

- `cancel_single_registered`: `8.398 ns/op`
- `cancel_reset_only`: `1.501 ns/op`
- `cancel_reregister_after_reset`: `11.047 ns/op`
- `cancel_reset_reregister_cycle`: `95.435 ns/op`

Revised `Cancel` reset conclusion:

- `reset()` itself is cheap and stable.
- Post-reset re-registration is in the same general band as the existing
  register/unregister path.
- The earlier tail concern around `cancel_reset_reregister_cycle` does not
  currently point to `reset()` as a product hotspot.
- The combined lifecycle still costs much more than the isolated pieces because
  it includes multiple lifecycle operations plus verification in one callback,
  but the current rerun no longer shows the earlier alarming tail shape.

Updated action:

- move cancel reset off the hotspot list;
- if cancel is revisited later, the primary performance question is still
  registration install scaling, not reset behavior.

Fallback contention metadata result:

- the threads-only contention owner now records
  `environment_tags=host_threads,polling_fallback`;
- parking-backed contention runs keep the `parking_wait` lineage; and
- wait-queue-capable runs keep `parking_wait,wait_queue`.

That change matters because the fallback polling run now starts a fresh history
line instead of pretending to be comparable to the parking-backed lineage. The
latest rerun of `static_sync_contention` under the polling-fallback tags passed
baseline comparison with:

- `thread_spawn_join_noop`: `153,893.750 ns/op`
- `event_ping_pong_256`: `269,248.438 ns/op`
- `semaphore_ping_pong_256`: `257,898.438 ns/op`

The main unresolved issue is therefore no longer benchmark metadata hygiene. It
is whether later fallback-mode reference owners are still worth adding for
deeper diagnosis, which is now a lower-priority refinement rather than a
blocking interpretation gap.

## Ranked Next Proof Steps

1. Add count sweeps where the isolated owners are now good enough to support
   scaling analysis, especially for cancel registration and barrier waits.
2. Keep the no-OS-backend contention suite in observation mode under its new
   polling-fallback metadata lineage.
3. Shift the next substantial package work back toward task 5 of the active
   plan: primitive-facing replay, fuzz, and retained-failure hardening.

## Current Conclusion

The strongest current evidence still does not point to a single clear primitive
bug in `static_sync`, but it now points more narrowly at specific benchmark
shape problems:

- the no-OS-backend contention owner still needs careful interpretation as a
  fallback-mode diagnostic; and
- the bounded fallback contention benchmark shape now measures watchdog and
  timeout-slice behavior strongly enough that it should not be interpreted the
  same way as the OS-backed contention suite.

The once, grant, barrier, seqlock, cancel fanout, cancel reset, and
timeout-path slices are now much better localized. The remaining benchmark work
is mostly refinement and scaling analysis rather than hotspot triage, which
means the active plan can safely shift its center of gravity back toward the
unfinished replay/fuzz/retained-failure task.

## Iteration 6: Primitive-Facing Retained Replay Hardening

The next package slice landed in:

- `packages/static_sync/tests/integration/replay_fuzz_sync_primitives.zig`
- `packages/static_sync/tests/integration/fuzz_persistence_sync.zig`
- `packages/static_testing/src/testing/failure_bundle.zig`

New retained-proof outcome:

- persisted replay artifacts from the event, semaphore, and cancel campaigns
  are now re-executed when a campaign fails, so future retained regressions
  immediately prove replayability instead of only checking that a corpus entry
  exists;
- the old threshold-triggered retained-failure proof is gone;
- the retained persistence surface now uses primitive-facing misuse traces for
  cancel registration-after-cancel and zero-timeout pending waits; and
- the shared failure-bundle contract now correctly preserves full-width
  checkpoint digests during bundle serialization.

Revised conclusion:

- the active plan no longer needs to treat retained replay as an unfinished
  benchmark-adjacent blocker;
- the next package work can move to lifecycle and ordering model growth rather
  than more benchmark hotspot isolation; and
- the retained-failure story is now aligned with the package direction:
  bounded, replayable, primitive-facing failures on the canonical shared
  artifact contract.
