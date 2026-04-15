# `static_testing` review follow-up plan — 2026-03-08

## Objective

Validate every issue raised in `docs/sketches/static_testing_review_2026-03-08_second_pass.md`, then address every confirmed issue with code, tests, docs, examples, benchmarks, or an explicit documented disposition.

This plan treats the review as an issue source, not as ground truth. Every item must be confirmed, narrowed, or rejected before implementation work starts for that item.

## Inputs

- Review source: `docs/sketches/static_testing_review_2026-03-08_second_pass.md`
- Review checklist: `docs/plans/completed/static_testing_review_checklist_2026-03-08_second_pass.md`
- Package under review: `packages/static_testing`
- Phase 0 ledger: `docs/plans/active/static_testing_review_issue_ledger_2026-03-08.md`

## Exit criteria

The follow-up is complete only when all of the following are true:

1. Every review issue has a disposition:
   - confirmed bug/gap,
   - confirmed but intentionally deferred,
   - narrowed/reframed, or
   - rejected as not an issue.
2. Every confirmed non-deferred issue has:
   - a root-cause fix or explicit design/documentation adjustment,
   - targeted regression coverage where applicable, and
   - updated docs/examples/comments where the public contract changed.
3. Benchmark-related items have a documented outcome:
   - implemented benchmark,
   - benchmark plan deferred with rationale, or
   - review item closed as unnecessary.
4. Final validation passes for the package.

## Validation workflow

Apply this workflow to each issue before closing it:

1. Re-read the relevant file and symbol.
2. Confirm the issue with one of:
   - a targeted failing test,
   - a small reproducer,
   - compile-time proof,
   - source-level proof with clear invariant analysis, or
   - an explicit design decision note when the issue is about policy/scope.
3. Classify the result:
   - **Confirmed:** needs a code/doc/test change.
   - **Confirmed but deferred:** valid, but intentionally postponed with rationale.
   - **Rejected:** review finding was too broad, stale, or incorrect.
4. Fix or document the issue at the root cause.
5. Add or update targeted tests.
6. Re-run local validation for the touched surface.

## Work sequence

### Phase 0 — Build the issue ledger

- [x] Create a working issue ledger section in this plan or a sibling checklist with one entry per review finding.
- [x] Tag each issue with one of: correctness, error-handling, docs, tests, examples, performance, or benchmark.
- [x] Mark each issue as one of: straightforward fix, design decision, or needs investigation.
- [x] Order the work so correctness and contract issues land before docs/examples/benchmarks.

### Phase 0 artifact

Phase 0 is implemented in `docs/plans/active/static_testing_review_issue_ledger_2026-03-08.md`.

That ledger is now the source of truth for:

- issue IDs,
- execution ordering,
- per-issue tags,
- investigation class,
- validation method, and
- eventual disposition.

### Phase 1 — Confirm and fix highest-risk correctness issues

- [x] `src/bench/process.zig`: prove that warmup child execution can fail through ordinary operating errors; replace `catch unreachable`; add regression coverage.
- [x] `src/testing/reducer.zig`: prove that `ReduceStep.reduced` / `.rejected` are unreachable today; redesign result semantics; update tests.
- [x] `src/bench/export.zig`: reproduce invalid CSV and Markdown output for names requiring escaping; implement escaping/quoting; add regression tests.
- [x] `src/testing/driver_protocol.zig`: prove non-zero reserved bytes are accepted today; reject malformed reserved-byte input; add decode tests.
- [x] `src/testing/replay_artifact.zig`: prove reserved-byte and unknown-flag acceptance behavior; decide exact v1 decode contract; implement and test it.
- [x] `src/testing/fuzz_runner.zig`: prove reducer-budget validation is late and inconsistent; validate reducer configuration eagerly; add tests.

### Phase 2 — Resolve package-root output and cleanup semantics

- [x] Confirm every path that writes generated files into the package root:
  - `src/testing/corpus.zig`
  - `tests/integration/fuzz_persistence.zig`
  - `tests/integration/replay_roundtrip.zig`
  - `examples/fuzz_seeded_runner.zig`
  - any related build/example execution path
- [x] Decide the target output policy: `.zig-cache`, caller-provided temp directory, or dedicated test temp subtree.
- [x] Move confirmed generated outputs away from the package root.
- [x] Replace bare cleanup `catch {}` sites with explicit handling or bounded/test-safe cleanup helpers.
- [x] Remove the checked-in or leftover generated artifact once the output policy is fixed.

### Phase 2 outcome

- Unit and integration tests now use `std.testing.tmpDir(.{})`, keeping generated artifacts under `.zig-cache/tmp`.
- The fuzz example now stages corpus output under `.zig-cache/static_testing/examples/fuzz_seeded_runner` and cleans that subtree explicitly.
- Validation confirmed that `src/testing/corpus.zig` itself was not imposing package-root output; the root writes came from test/example call sites using `Dir.cwd()`.
- `build.zig` smoke validation now includes `examples/replay_roundtrip.zig`.

### Phase 3 — Settle public contract and error-semantics issues

- [x] `src/bench/case.zig`: validate whether `BenchmarkCaseFn` should remain infallible or become fallible; either redesign or document the contract explicitly.
- [x] `src/bench/process.zig`: validate whether `ProcessPrepareFn` needs an error union; either redesign or document why `void` is intentional.
- [x] Cross-file invalid-input policy: audit where public APIs assert versus return `InvalidInput` / `InvalidConfig`; define the intended rule and align confirmed mismatches.
- [x] `src/testing/process_driver.zig`: validate whether `anyerror` in internal mappers can be narrowed cleanly; tighten if feasible.
- [x] Bare `catch {}` audit:
  - `src/bench/process.zig`
  - `src/testing/corpus.zig`
  - `tests/integration/fuzz_persistence.zig`
  - `tests/integration/replay_roundtrip.zig`
  - `tests/support/driver_echo.zig`
  - `examples/fuzz_seeded_runner.zig`

### Phase 3 outcome

- `BenchmarkCaseFn` and `ProcessPrepareFn` remain intentionally infallible; the contract is now documented explicitly at the callback boundary.
- The package root now documents the assertion-vs-error policy for trusted configuration versus malformed external/runtime inputs.
- `bench/case.zig` gained `blackBoxPointer()` for large values, `bench/compare.zig` now documents and tests zero-baseline saturation, and `bench/config.zig` removed the tautological assertion while documenting its generic-bounds-only policy.
- `bench/process.zig` now defaults `request_resource_usage_statistics` to `false`, making RSS sampling opt-in.
- `testing/checker.zig`, `testing/identity.zig`, `testing/process_driver.zig`, and `testing/replay_artifact.zig` now enforce or document the reviewed contract invariants directly in code.

### Phase 4 — Resolve replay/simulation design questions

- [x] `src/testing/replay_runner.zig`: decide whether `checkpoint_digest` is part of the replay contract.
- [x] If checkpoint digests are in scope, compare them during replay and add mismatch coverage.
- [x] If checkpoint digests are intentionally out of scope, document that explicitly and close the review item with rationale.
- [x] `src/testing/sim/event_loop.zig`: decide whether fault scripts are meant to be behavioral or observational in the current phase.
- [x] If behavioral, implement fault application and add tests.
- [x] If observational, document the limitation clearly in public docs and examples.
- [x] `src/testing/sim/event_loop.zig`: validate the `runForSteps()` vs `runUntil()` budget inconsistency; align the contract and add tests.

### Phase 4 outcome

- `replay_runner` now states explicitly that checkpoint digests are observational-only in the current artifact phase because replay artifacts do not persist them yet.
- `sim/event_loop.zig` now documents fault scripts as observational-only for this phase and has regression coverage proving faults are counted/traced without mutating scheduling behavior.
- `runForSteps()` now respects `EventLoopConfig.step_budget_max`, matching the configured boundedness already applied by `runUntil()`.

### Phase 5 — Close documentation and example gaps

- [x] Add `///` docs across the benchmark surface:
  - `src/bench/root.zig`
  - `src/bench/case.zig`
  - `src/bench/compare.zig`
  - `src/bench/config.zig`
  - `src/bench/export.zig`
  - `src/bench/group.zig`
  - `src/bench/process.zig`
  - `src/bench/runner.zig`
  - `src/bench/stats.zig`
  - `src/bench/timer.zig`
- [x] Add item-level docs to `src/testing/identity.zig`, `src/testing/seed.zig`, `src/testing/replay_artifact.zig`, and `src/testing/trace.zig`.
- [x] Validate which tests need top-of-test rationale comments to meet the local testing-comment standard; add them where the setup/method is non-obvious.
- [x] Validate example coverage gaps from the review.
- [x] Add or defer examples for:
  - `process_driver`
  - `bench.process`
  - high-level `replay_runner.runReplay()`
- [x] Revisit whether `build.zig` smoke validation should include `examples/replay_roundtrip.zig`.

### Phase 5 outcome

- The benchmark surface and key testing files now carry `///` item docs suitable for generated reference output.
- Non-obvious tests now include rationale comments where the setup/method was carrying more context than the test name alone.
- Added dedicated examples for `process_driver`, `bench.process`, and high-level `replay_runner.runReplay()`.
- The example step now runs those new examples, and the earlier replay-roundtrip smoke inclusion remains in place from Phase 2.

### Phase 6 — Fill targeted test gaps from the review

- [x] `src/bench/compare.zig`: add zero-baseline and overflow-path coverage if the current behavior stands.
- [x] `src/bench/config.zig`: add overflow-path coverage and decide whether domain-level caps belong in validation.
- [x] `src/bench/runner.zig`: add `NoSpaceLeft` / `InvalidConfig` coverage and remove dead helper state if still unused.
- [x] `src/testing/corpus.zig`: add invalid extension, small-buffer, and artifact-buffer-too-small coverage.
- [x] `src/testing/fuzz_runner.zig`: add invalid-reduction-budget, persistence-disabled, and persistence-buffer coverage.
- [x] `src/testing/identity.zig`: add remaining field-delta coverage if still warranted after contract review.
- [x] `src/testing/seed.zig`: add uppercase-hex, max-width, and overflow boundary tests.
- [x] `src/testing/trace.zig`: add multi-event JSON and sequence-boundary coverage.
- [x] `src/testing/sim/mailbox.zig`: add invalid-capacity and `peek()` coverage.
- [x] `src/testing/sim/scheduler.zig`: add trace-related failure/overflow coverage if trace contract stays as-is.
- [x] `src/testing/sim/event_loop.zig`: add idle, backward-target, fault, and trace coverage according to the finalized event-loop contract.
- [x] `tests/integration/process_driver_roundtrip.zig`: add payload-limit and pending-request misuse coverage if the API contract warrants it.
- [x] `tests/integration/process_bench_smoke.zig`: add resource-statistics and timeout-related coverage if those behaviors remain configurable/public.

### Phase 6 outcome

- `bench/compare.zig`, `bench/config.zig`, and `bench/runner.zig` now cover overflow, invalid-config, and storage-boundary paths directly, and `bench/runner.zig` no longer carries the dead `mapTimerError()` helper.
- `testing/corpus.zig`, `testing/fuzz_runner.zig`, `testing/identity.zig`, `testing/seed.zig`, and `testing/trace.zig` now cover the missing negative and boundary cases identified in the review.
- `sim/mailbox.zig`, `sim/scheduler.zig`, and `sim/event_loop.zig` now cover invalid-capacity, trace semantics, trace append failure, idle behavior, backward targets, and jump/fault tracing.
- Phase 6 validation exposed a real scheduler-state bug: trace append failure was mutating decision state before returning. `sim/scheduler.zig` now appends trace before committing scheduler state, and tests lock in the no-partial-mutation contract.
- Integration coverage now includes `process_driver` payload/pending-request misuse and `bench.process` opt-in RSS/timeout behavior.
- Validation passed with `zig build test` and `zig build smoke`.

### Phase 7 — Review and handle performance-focused findings

- [x] `src/bench/stats.zig`: validate whether the O(n²) percentile algorithm is acceptable for supported sample counts; either keep and document it or replace it.
- [x] `src/bench/process.zig`: validate the `request_resource_usage_statistics` default; keep it opt-in with rationale and tests.
- [x] `src/bench/case.zig`: validate whether `blackBox()` needs a pointer-oriented companion for large values.
- [x] Cross-file: audit large-by-value public/generic arguments identified in the review; fix the clear wins and explicitly defer the rest if churn is too high.
- [x] Cross-file: validate whether the duplicated timeout/wait logic in `bench/process.zig` and `testing/process_driver.zig` should be consolidated.

### Phase 7 outcome

- `bench/stats.zig` now has an O(n log n) fast path (`stats_inline_samples_max`) and a scratch-based API (`computeStatsWithScratch()`) for large sample sets, plus explicit docs about the remaining O(n²) fallback selection behavior.
- `bench/process.zig` internal helpers now pass `ProcessBenchmarkCase` by pointer to avoid repeated by-value copies in the control plane.
- `testing/reducer.zig` now documents the intended pattern for large candidates: use pointer/handle types as `Candidate` to avoid repeated large copies in callback-heavy paths.
- The previously raised performance items remain closed as documented: `request_resource_usage_statistics` is opt-in by default (ST-027), `blackBoxPointer()` exists (ST-022), and timeout/wait duplication remains intentional for clarity (ST-028).

### Phase 8 — Benchmark decisions and implementation

- [x] Decide which of the review’s proposed benchmarks are in scope for this follow-up versus a later pass.
- [x] For in-scope benchmarks, define the exact baseline for each:
  - `bench/stats.zig` vs alternative selection/sort strategy
  - `testing/replay_artifact.zig` vs simpler serializer or JSON baseline
  - `testing/driver_protocol.zig` vs direct manual little-endian encode/decode
  - `testing/sim/timer_queue.zig` vs raw `static_scheduling.timer_wheel`
  - `testing/trace.zig` vs no-trace baseline
  - `bench/process.zig` with resource stats on/off and timeout on/off
  - `testing/process_driver.zig` vs direct stdin/stdout messaging
- [x] Add only benchmarks that are well-scoped and useful now.
- [x] For deferred benchmarks, document why they are deferred and what they should compare against later.

### Phase 8 outcome

- Implemented `zig build bench` with two benchmarks: `benchmarks/stats.zig` (stats selection vs sort) and `benchmarks/timer_queue.zig` (timer-queue wrapper vs raw timer wheel).
- Bench baselines:
  - `bench/stats.zig`: `computeStats()` fallback path (O(n²) selection at n=1025) vs `computeStatsWithScratch()` (heap sort on caller scratch at n=1025), plus `computeStats()` fast path at n=1024.
  - `testing/sim/timer_queue.zig`: `TimerQueue.scheduleAfter()+drainDue()` vs `static_scheduling.timer_wheel.TimerWheel.schedule()+tick()` for equivalent “due next tick” workloads.
- Deferred benchmark targets (documented, not implemented yet): replay artifacts, driver protocol headers, trace append/export, process benchmark overhead (timeout/RSS), and process driver round-trip overhead; these need more stable baselines (and, for process-boundary cases, better OS/noise control) than this follow-up should introduce.

### Phase 9 — Final validation and closure

- [x] Run the smallest targeted tests after each fix area.
- [x] Run package-wide validation once all confirmed fixes land.
- [x] Update the review doc or create a follow-up closure note summarizing:
  - fixed issues,
  - rejected findings,
  - deferred findings,
  - benchmark decisions.
- [x] Move this plan to `docs/plans/completed/` only after all issue entries are closed or explicitly deferred.

### Phase 9 outcome

- Final package validation passed with `zig build test`, `zig build smoke`, `zig build examples`, and `zig build bench`.
- The Phase 0 issue ledger is fully closed: all review items now have an explicit disposition, with confirmed fixes landed, narrowed items documented in code, and no unresolved active entries remaining.
- Benchmark closure is now explicit: `zig build bench` covers the in-scope `bench.stats` and `sim.timer_queue` targets, while the remaining review-suggested benchmarks stay deferred with recorded rationale and future baselines.
- This follow-up plan and its issue ledger are ready to move from `docs/plans/active/` to `docs/plans/completed/`.

## Issue register

Use the sibling ledger at `docs/plans/active/static_testing_review_issue_ledger_2026-03-08.md` as the execution-ready issue register.

It replaces the coarse category list that originally lived in this plan because the ledger now provides:

- one tracked entry per review finding,
- normalized tags,
- execution lanes,
- validation methods, and
- a disposition field for closure.
