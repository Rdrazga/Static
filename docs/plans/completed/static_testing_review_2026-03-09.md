# `static_testing` package review - 2026-03-09

## Scope

Package: `packages/static_testing`

This review checks:

- package structure and public surface;
- Zig and general best practices;
- conformance with `agents.md`;
- testing quality, assertion strategy, and error semantics;
- comments, doc comments, and generated-documentation readiness;
- performance posture, examples, and benchmark coverage.

## Status

- Review completed.
- Validation completed with package-local build steps.

## Findings

### Package hygiene and build

#### Strengths

- The package layout is easy to inspect: `src/bench`, `src/testing`, `src/testing/sim`, `examples`, `tests/integration`, and `benchmarks` all map cleanly to the public surface.
- `packages/static_testing/build.zig` wires unit tests, integration tests, examples, and benchmarks into explicit build steps instead of hiding behavior behind ad hoc scripts.
- The root module docs in `packages/static_testing/src/root.zig` clearly define the package boundary, phase scope, and invalid-input policy.

#### Findings

1. **Benchmark sources are omitted from the package manifest.**
   - `packages/static_testing/build.zig.zon` exports `build.zig`, `build.zig.zon`, `src`, `examples`, and `tests`, but not `benchmarks`.
   - Local `zig build bench` works inside this checkout because the sources are present, but a packaged dependency will omit the benchmark programs entirely.
   - This is a documentation and packaging mismatch because the package advertises a `bench` build step.

2. **`build.zig` special-cases example wiring by executable name instead of by explicit example metadata.**
   - `packages/static_testing/build.zig` injects `static_testing_example_options` only when the example name matches `static_testing_process_driver_roundtrip`.
   - This works today, but it is brittle: adding another example that needs options will silently require another string-comparison branch.
   - A `needs_driver_echo` flag in `ExampleSpec` would better match the package's explicit-configuration style.

3. **The package tree currently contains a local `packages/static_testing/.zig-cache/` directory.**
   - If this directory is committed or redistributed, it is a generated-artifact hygiene problem.
   - I cannot verify version-control state from this workspace because it is not a Git checkout, but the package layout should treat `.zig-cache/` as local-only.

### Package root

#### Strengths

- `packages/static_testing/src/root.zig` gives a clear package-level contract and keeps the public root surface intentionally small.
- `packages/static_testing/src/bench/root.zig` is well documented and re-exports the bench subsystem with per-item `///` comments.
- The root smoke test exercises both the testing and simulation re-exports in one place.

#### Findings

1. **Generated-doc readiness is inconsistent across root re-export files.**
   - `packages/static_testing/src/root.zig`, `packages/static_testing/src/testing/root.zig`, and `packages/static_testing/src/testing/sim/root.zig` re-export many public modules without per-item `///` docs.
   - `packages/static_testing/src/bench/root.zig` already does this correctly, so the package has an internal example of the stronger pattern.
   - If `zig doc` output matters, the root, testing, and sim re-export files should mirror the bench root style.

### Bench subsystem

#### Strengths

- The in-process benchmark surface is simple and bounded: caller-owned storage, explicit sample counts, explicit overflow handling, and no allocations in the measured path.
- `packages/static_testing/src/bench/export.zig` escapes JSON, CSV, and Markdown correctly and has strong regression coverage for delimiter-heavy case names.
- `packages/static_testing/src/bench/process.zig` maps OS and process errors into an explicit package error vocabulary and covers real subprocess behavior with both unit and integration tests.
- `packages/static_testing/src/bench/stats.zig` documents the fast-path versus fallback algorithm tradeoff clearly and exposes a scratch-buffer API for large runs.

#### Findings

1. **`bench/stats.zig` can overflow in its nearest-rank percentile helper.**
   - `packages/static_testing/src/bench/stats.zig` computes `rank_1based` as `@divFloor(numerator + 99, 100)` after a checked multiply.
   - The checked multiply does not protect the subsequent `+ 99`; for sufficiently large public slices this can still overflow before the division.
   - Because this path consumes caller-controlled slice lengths, it should use checked addition and return `error.Overflow` rather than relying on a safety trap.

2. **`bench/process.zig` can overflow the public `run_index` passed to `prepare_fn`.**
   - `runMeasuredSample()` computes `run_index = sample_index * measure_iterations + measure_index` as `u32`.
   - Config validation only proves that `measure_iterations * sample_count` fits `usize`, not `u32`, so large but representable benchmark configs can wrap `run_index`.
   - This is a semantic bug for deterministic prepare hooks even though the timing path itself stays bounded.

3. **`bench/process.zig` converts OS cleanup failures into panics in `terminateChildId()`.**
   - Timeout cleanup is an operating-error path, but unexpected `kill()` failures currently call `std.debug.panic`.
   - That conflicts with the package's own error-handling posture and with `agents.md`'s rule to avoid panicking on operating errors.
   - The function should either return a mapped error or explicitly document why every non-`ProcessNotFound` failure is impossible.

4. **Assertion density is weaker than `agents.md` expects in several control-plane helpers.**
   - `bench/config.zig`, `bench/compare.zig`, and `bench/runner.zig` generally use correct error unions for caller-controlled invalid inputs.
   - Even so, many functions fall short of the "two assertions per function" project rule and do not pair their positive and negative-space assertions consistently.
   - This is mostly a style-compliance issue rather than a correctness bug, but it is noticeable in the benchmark control plane.

### Testing subsystem

#### Strengths

- `seed.zig`, `identity.zig`, `corpus.zig`, and `replay_runner.zig` are small, explicit, and mostly align well with the package's deterministic control-plane goals.
- Error vocabularies are explicit at public boundaries. I found no `anyerror` usage and no swallowed `catch {}` blocks in the main package sources.
- `fuzz_runner.zig` keeps orchestration bounded, only invokes reduction after the first failure, and has both unit and integration coverage for persistence and replay.
- `driver_protocol.zig` is compact, fixed-width, and well covered for unsupported versions, reserved-byte corruption, and request/response kind separation.

#### Findings

1. **`trace.zig` can overflow `next_sequence_no` on a boundary-valid append.**
   - `TraceBuffer.init()` correctly accepts `max_events = 1` with `start_sequence_no = maxInt(u32)`.
   - `TraceBuffer.append()` then stores the event and unconditionally executes `self.next_sequence_no += 1`, which overflows immediately after the last valid boundary sequence number.
   - The existing test checks boundary initialization but not boundary append, so this bug is not currently covered.

2. **`replay_artifact.zig` accepts internally inconsistent trace metadata from untrusted bytes.**
   - `decodeReplayArtifact()` validates version, reserved bytes, lengths, and known flags, but it does not reject impossible combinations such as `event_count == 0` with `has_range == true`, or reversed sequence and timestamp ranges.
   - The package boundary says malformed external data should return an operating error, so these header inconsistencies should decode as `error.CorruptData`.
   - This is a correctness and error-semantics gap in the external binary-format boundary.

3. **`process_driver.zig` waits on a copied child struct during shutdown.**
   - `ProcessDriver.shutdown()` copies `self.child.?` into a local `child`, waits on the copy, and then sets `self.child = null`.
   - Because `std.process.Child` carries ownership-like state for pipes and process handles, waiting on a copy is risky: the waited copy and the stored original can diverge, and the original can then be dropped without synchronized cleanup.
   - This is the highest-risk resource-lifecycle issue I found in the package.

4. **`process_driver.zig` can desynchronize the stream when the caller's response buffer is too small.**
   - `recvResponse()` reads and validates the response header first, then returns `error.NoSpaceLeft` if `header.payload_len > payload_buffer.len`.
   - At that point the payload remains unread in the pipe, so the next `recvResponse()` will start from payload bytes instead of a header and the session is effectively corrupted.
   - The API does not document this error as terminal, and there is no regression test for the behavior.

5. **Generated-doc coverage is notably weak in `checker.zig` and several generic wrapper methods.**
   - `checker.zig` exports multiple public types and methods without `///` docs.
   - Similar per-method doc gaps exist in `clock.zig`, `fault_script.zig`, `mailbox.zig`, `scheduler.zig`, and `timer_queue.zig`.
   - The package already does this well in files like `bench/root.zig`, so the inconsistency stands out.

### Simulation subsystem

#### Strengths

- The simulation building blocks are composable and explicit: clock, timer queue, scheduler, fault script, and event loop are separate modules with clear roles.
- `timer_queue.zig` and `scheduler.zig` keep storage caller-owned or init-time allocated and avoid hidden allocations in steady-state stepping.
- The simulation tests cover deterministic ordering, replay, idle detection, observational fault handling, and the configured step-budget contract.

#### Findings

1. **`scheduler.applyRecordedDecision()` does not validate `recorded.step_index`.**
   - The replay path checks `ready_len`, `chosen_index`, `chosen_id`, and `chosen_value`, but it never proves that the recorded step index matches `self.decision_count`.
   - That means a structurally compatible decision from the wrong logical step can still be accepted and re-recorded.
   - Since `ScheduleDecision.step_index` is part of the public replay contract, this should be validated explicitly.

2. **`event_loop.zig` is not state-atomic on error paths.**
   - `step()` advances the fault-script cursor before trace append succeeds.
   - `jumpToNextDue()` advances logical time before it knows that jump tracing can succeed.
   - `step()` also drains timers before it knows that the scheduler has enough capacity to enqueue them all.
   - In all three cases, a returned error can still leave the simulation partially mutated, which is a serious determinism and debuggability problem.

3. **`event_loop.zig` can lose ready items when scheduler capacity is smaller than the drained timer batch.**
   - `timer_queue.drainDue()` removes due timers from the queue into `timer_buffer`.
   - `step()` then enqueues them one by one; a later `scheduler.enqueueReady()` failure returns an error after earlier timers have already been consumed from the queue.
   - There is no preflight capacity check or rollback path, and current tests do not cover this partial-delivery case.

4. **The simulation API copies values by value in several generic surfaces.**
   - `Mailbox(T).recv()` and `peek()`, and `TimerQueue(T)` scheduling, all move `T` by value.
   - This is fine for small ids and handles, but it becomes a performance footgun for large structs under the project's "avoid large copies" rule.
   - The docs should explicitly steer callers toward small handle types or pointer-like wrappers for large payloads.

### Benchmarks

#### Strengths

- The existing benchmarks are focused and useful: `benchmarks/stats.zig` measures the algorithmic fast path versus fallback, and `benchmarks/timer_queue.zig` compares the wrapper cost against the underlying timer wheel.
- Both benchmark programs reuse the package's own benchmark harness instead of inventing a second benchmark framework.

#### Findings

1. **The benchmark binaries do not assert enough semantic postconditions.**
   - `benchmarks/stats.zig` panics on outright errors, but it does not verify that derived stats still match expected sample counts or percentile values.
   - `benchmarks/timer_queue.zig` does not assert that `drained == schedule_count`, that all entries were delivered, or that the structures return to an expected steady state between iterations.
   - Benchmarks should prove correctness first, then measure speed.

2. **Benchmark coverage is still narrow relative to the package surface.**
   - The current suite does not measure replay artifact encode/decode, process-driver request/response overhead, scheduler decision/replay cost, or event-loop stepping overhead.
   - Those are all public surfaces where users may care about fixed overhead and determinism cost.

### Examples

#### Strengths

- The example set exercises the highest-level workflows: in-process benchmarks, process benchmarks, replay artifacts, replay execution, process drivers, deterministic fuzzing, and simulation handoff through a mailbox.
- Most examples are short and usable as smoke programs rather than pseudo-code snippets.

#### Findings

1. **Example coverage still misses some important public surfaces.**
   - There is no direct example for `trace.writeChromeTraceJson()`, `corpus.writeCorpusEntry()` and `readCorpusEntry()`, `driver_protocol` raw header encode/decode, or scheduler replay without the full event loop.
   - There is also no example showing `bench.exports.writeJson()`, `writeCsv()`, or `writeMarkdown()`, even though export correctness is a key part of the benchmark surface.

2. **`examples/fuzz_seeded_runner.zig` treats cleanup errors as panics and does not clearly separate "best effort" from "required" cleanup.**
   - That is reasonable for an example, but it does not model the package's preferred operating-error posture as well as it could.

### Integration tests and support

#### Strengths

- The integration suite exercises the most important real boundaries: filesystem round-trips, subprocess benchmarks, subprocess drivers, persisted fuzz failures, and scheduler replay across independent simulator instances.
- `tests/support/driver_echo.zig` is small enough to understand by inspection and keeps the protocol test harness honest.

#### Findings

1. **Several of the most important file-level bugs above do not yet have regression tests.**
   - Missing targeted coverage includes:
     - `TraceBuffer.append()` at the `u32` sequence boundary.
     - `decodeReplayArtifact()` rejecting inconsistent trace-range metadata.
     - `Scheduler.applyRecordedDecision()` rejecting mismatched `step_index`.
     - `EventLoop.step()` rollback behavior on trace-buffer exhaustion and scheduler-capacity overflow.
     - `ProcessDriver.recvResponse()` behavior when `payload_buffer` is too small.
     - `bench.stats` percentile-rank overflow handling at extreme slice lengths.

2. **Test rationale comments are uneven.**
   - Some tests have strong top-of-test `Method:` comments, but many others do not.
   - Given the project guidance to explain why and how tests work, the suite would benefit from more consistent rationale coverage.

### Cross-file synthesis

#### Overall assessment

- The package is structurally strong: bounded storage is the default, public error sets are explicit, and the major workflows already have unit, integration, example, and benchmark coverage.
- The main remaining weaknesses are contract-hardening issues at important boundaries:
  - external binary decode validation;
  - process-boundary lifecycle ownership;
  - event-loop atomicity under error;
  - integer-boundary handling; and
  - generated-doc completeness.

#### `agents.md` alignment

- **Aligned well:**
  - explicit fixed-width integers (`u32`, `u64`, `u128`) dominate the package;
  - loops are bounded by caller-provided capacities and counts;
  - hot-path APIs are largely allocation-free after setup;
  - public boundaries mostly use named error sets instead of `anyerror`.
- **Partially aligned or weaker than requested:**
  - assertion density falls short of the "two assertions per function" target in many control-plane helpers;
  - some operating-error paths still escalate to `std.debug.panic` (`terminateChildId()` in two files);
  - public doc coverage is inconsistent across re-export modules and generic wrappers;
  - some public decode and validation surfaces still accept malformed states that should be rejected.

#### Error-handling review

- The error vocabulary is generally disciplined and explicit.
- The biggest semantic issues are:
  1. `bench/process.zig` and `testing/process_driver.zig` still panic on some timeout-cleanup failures.
  2. `testing/replay_artifact.zig` under-validates corrupt external metadata.
  3. `testing/process_driver.zig` has terminal-but-undocumented session-corruption cases.
  4. `testing/sim/event_loop.zig` returns errors after partial mutation, which makes recovery semantics unclear.

#### Assertion review

- Assertions are used for many programmer-invariant boundaries and some compile-time integrity checks.
- The strongest assertion usage appears in `bench/case.zig`, `trace.zig`, `identity.zig`, and `timer_queue.zig`.
- The weakest area is consistency: many public helpers use the right error unions but still do not encode the extra positive and negative-space assertions required by the project rules.

#### Testing review

- Coverage is good at the happy-path and boundary-path level for:
  - benchmark config and export;
  - seed parsing and formatting;
  - replay round-trips;
  - fuzz persistence;
  - subprocess benchmarking;
  - subprocess driver round-trips; and
  - basic scheduler and event-loop behavior.
- Coverage is weak or missing for the highest-value regressions found in this review:
  - `TraceBuffer` sequence-boundary append overflow.
  - Corrupt replay-artifact range metadata.
  - `ProcessDriver.recvResponse()` undersized payload buffers.
  - `Scheduler.applyRecordedDecision()` step-index mismatches.
  - `EventLoop.step()` rollback and atomicity under trace or enqueue failure.
  - `bench.stats` percentile-rank overflow handling at extreme slice lengths.

#### Comment and doc review

- Module-level `//!` coverage is strong across the package.
- Public-item `///` coverage is inconsistent:
  - strong in the bench modules and several binary-format files;
  - weak in `checker.zig`, the re-export roots, and several simulation methods.
- Test-comment quality is mixed: some excellent `Method:` comments exist, but the style is not applied consistently.

#### Performance review

- The package generally respects its control-plane and data-plane split:
  - steady-state benchmark and simulation paths mostly avoid allocation;
  - init-time allocation is explicit in `Mailbox` and `TimerQueue`;
  - fixed-capacity slices dominate hot-path storage.
- The main performance footguns are:
  1. generic by-value movement of `T` in mailbox and timer surfaces for large payload types;
  2. O(n) metadata scans in `TimerQueue.nextDueTime()` and `countDueUpTo()`, which are acceptable only because `timers_max` is bounded;
  3. the O(n^2) stats fallback, which is documented but should remain benchmarked and intentionally bounded.

#### Example coverage review

- The examples are enough to teach the top-level flows.
- The missing "how do I use this directly?" examples are for:
  - direct corpus persistence;
  - trace JSON export;
  - raw protocol encode and decode;
  - scheduler replay;
  - benchmark JSON, CSV, and Markdown export; and
  - large-run stats with caller scratch.

#### Benchmark assessment

- **Should this package have benchmarks?** Yes.
  - The package is infrastructure-heavy, and fixed overhead is part of its value proposition.
  - Benchmarks are especially justified for `bench.stats`, `sim.timer_queue`, `sim.scheduler`, `sim.event_loop`, `replay_artifact`, and `process_driver`.
- **What should it benchmark against?**
  - `bench.stats`:
    - current `computeStats()` fast path;
    - current `computeStats()` fallback;
    - `computeStatsWithScratch()`;
    - and optionally a direct `std.sort`-based scratch baseline.
  - `sim.timer_queue`:
    - current wrapper versus raw `static_scheduling.timer_wheel` (already present).
  - `sim.scheduler`:
    - `.seeded` versus `.first`;
    - recorded replay via `applyRecordedDecision()` versus fresh choice generation.
  - `testing.replay_artifact`:
    - encode and decode throughput against a minimal direct `static_serial` baseline.
  - `testing.process_driver`:
    - end-to-end request and response round-trip against a raw child-process pipe echo baseline.
  - `bench.process`:
    - framework overhead versus direct `std.process.spawn` plus `wait` loops for the same trivial child.
- **How should the benchmarks stay honest?**
  - Assert semantic postconditions outside or around the timed loop.
  - Keep allocator choice explicit and stable.
  - Compare like-for-like scopes. For wrapper benchmarks, state exactly which overhead is intentionally included.

#### Highest-priority follow-up items

1. Fix `ProcessDriver.shutdown()` child ownership and wait semantics.
2. Make `EventLoop.step()` state-atomic or explicitly terminal on trace and enqueue failure.
3. Fix `TraceBuffer.append()` sequence overflow at the `u32` boundary.
4. Harden `decodeReplayArtifact()` against inconsistent trace metadata.
5. Validate `ScheduleDecision.step_index` during replay.
6. Fix `runMeasuredSample()` `run_index` overflow handling.
7. Document or redesign terminal error semantics for `ProcessDriver.recvResponse()`.
8. Close the public-doc gaps in root, checker, and simulation wrappers.

## Remediation updates

- 2026-03-09 tier 1 remediation completed:
  - fixed `ProcessDriver.shutdown()` ownership and undersized-response handling;
  - made `EventLoop.step()` state-safe on trace and scheduler-capacity failures;
  - fixed `TraceBuffer.append()` boundary overflow;
  - hardened replay-artifact trace-metadata validation;
  - validated replay `step_index`;
  - fixed benchmark `run_index` and percentile boundary overflows; and
  - closed the root and `checker.zig` public-doc gaps.
- 2026-03-09 tier 2 remediation completed:
  - exported `benchmarks` from `packages/static_testing/build.zig.zon`;
  - replaced example-option name matching in `packages/static_testing/build.zig` with explicit metadata;
  - removed panic-on-timeout-cleanup behavior from `bench/process.zig` and `testing/process_driver.zig`;
  - added `///` coverage to the main simulation wrapper methods and documented by-value payload guidance for mailbox and timer queue surfaces;
  - made benchmark programs verify semantic postconditions before timing; and
  - changed `examples/fuzz_seeded_runner.zig` cleanup to explicit best-effort logging instead of panic-on-cleanup.
- 2026-03-09 tier 3 remediation completed:
  - strengthened benchmark control-plane validation and result-shape assertions in `bench/config.zig`, `bench/compare.zig`, and `bench/runner.zig`;
  - added direct examples for corpus persistence, trace JSON export, raw driver-protocol headers, scheduler replay, benchmark export formats, and large-run scratch stats; and
  - removed the local `packages/static_testing/.zig-cache/` build artifacts after validation.
- 2026-03-09 tier 4 remediation completed:
  - added benchmark coverage for replay-artifact encode/decode and scheduler record/replay workflows;
  - wired the new benchmarks into the package `bench` step with semantic preflight assertions; and
  - added top-of-test rationale comments in the main benchmark control-plane, replay-artifact, and scheduler test files.

## Validation

- `zig build test` - passed.
- `zig build integration` - passed.
- `zig build examples` - passed.
- `zig build bench -Doptimize=ReleaseFast` - passed.
