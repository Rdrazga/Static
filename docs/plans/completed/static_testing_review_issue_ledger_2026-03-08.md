# `static_testing` review issue ledger — 2026-03-08

## Purpose

This ledger is the Phase 0 working artifact for `docs/plans/active/static_testing_review_followup_plan_2026-03-08.md`.

It converts the review in `docs/sketches/static_testing_review_2026-03-08_second_pass.md` into an execution-ready issue list with:

- one tracked entry per review finding to be validated or disposed;
- explicit tags;
- an investigation class;
- an ordered execution lane;
- a planned validation method; and
- a place to record the final disposition.

## Status model

- [ ] Not yet validated.
- [~] Validation in progress.
- [x] Closed with disposition recorded.

## Disposition model

Each issue must end in one of:

- `confirmed/fixed`
- `confirmed/deferred`
- `narrowed`
- `rejected`

## Tag model

Allowed tags:

- `correctness`
- `error-handling`
- `docs`
- `tests`
- `examples`
- `performance`
- `benchmark`

## Investigation class

Each issue is classified as one of:

- `straightforward fix`
- `design decision`
- `needs investigation`

## Execution lanes

Work ordering for follow-up execution:

1. **L0 Critical correctness**
   - correctness bugs
   - binary-format contract bugs
   - invalid error semantics with runtime consequences
2. **L1 Package hygiene and I/O safety**
   - generated output placement
   - cleanup/error-handling hygiene
3. **L2 Public contract and semantics**
   - API boundary rules
   - replay/simulation semantic scope
4. **L3 Coverage and documentation**
   - missing tests
   - missing examples
   - generated-doc readiness
5. **L4 Performance and benchmark decisions**
   - performance validation
   - benchmark implementation or deferral

This ordering satisfies the Phase 0 requirement that correctness and contract issues land before docs/examples/benchmarks.

## Ledger

### L0 Critical correctness

#### ST-001

- [x] **Issue:** `bench/process.zig` uses `catch unreachable` for warmup child execution.
- **Source:** Review: highest-priority issue 1; file note for `packages/static_testing/src/bench/process.zig`.
- **Scope:** `packages/static_testing/src/bench/process.zig`
- **Tags:** `correctness`, `error-handling`, `tests`
- **Class:** `straightforward fix`
- **Validation:** Add or use a targeted failing process-benchmark warmup scenario and prove the path can fail with ordinary operating errors.
- **Planned lane:** `L0`
- **Disposition:** `confirmed/fixed` — warmup execution now propagates `ProcessBenchmarkError`, and regression coverage proves warmup child failures no longer crash through `unreachable`.

#### ST-002

- [x] **Issue:** `ReduceStep.reduced` and `.rejected` are defined but never returned; reducer result semantics are misleading.
- **Source:** Review: highest-priority issue 2; file note for `packages/static_testing/src/testing/reducer.zig`.
- **Scope:** `packages/static_testing/src/testing/reducer.zig`
- **Tags:** `correctness`, `docs`, `tests`
- **Class:** `straightforward fix`
- **Validation:** Source-level proof plus a targeted test that demonstrates only `.fixed_point` / `.budget_exhausted` are currently reachable.
- **Planned lane:** `L0`
- **Disposition:** `confirmed/fixed` — unreachable terminal states were removed from `ReduceStep`, dead state tracking was deleted, and tests now assert only the reachable terminal states remain.

#### ST-003

- [x] **Issue:** CSV export writes raw case names and can emit invalid CSV.
- **Source:** Review: highest-priority issue 3; file note for `packages/static_testing/src/bench/export.zig`.
- **Scope:** `packages/static_testing/src/bench/export.zig`
- **Tags:** `correctness`, `tests`
- **Class:** `straightforward fix`
- **Validation:** Add a reproducer using commas, quotes, and newlines in case names.
- **Planned lane:** `L0`
- **Disposition:** `confirmed/fixed` — CSV output now quotes/escapes case names when required, with regression coverage for commas, quotes, and newlines.

#### ST-004

- [x] **Issue:** Markdown export writes raw case names and can break table structure.
- **Source:** Review: highest-priority issue 3; file note for `packages/static_testing/src/bench/export.zig`.
- **Scope:** `packages/static_testing/src/bench/export.zig`
- **Tags:** `correctness`, `tests`
- **Class:** `straightforward fix`
- **Validation:** Add a reproducer using pipe and newline characters in case names.
- **Planned lane:** `L0`
- **Disposition:** `confirmed/fixed` — Markdown output now escapes pipes and normalizes embedded newlines, with regression coverage.

#### ST-005

- [x] **Issue:** `driver_protocol.zig` does not validate the reserved byte in decoded headers.
- **Source:** Review: highest-priority issue 4; file note for `packages/static_testing/src/testing/driver_protocol.zig`.
- **Scope:** `packages/static_testing/src/testing/driver_protocol.zig`
- **Tags:** `correctness`, `tests`
- **Class:** `straightforward fix`
- **Validation:** Corrupt the reserved byte in encoded request/response headers and confirm current acceptance.
- **Planned lane:** `L0`
- **Disposition:** `confirmed/fixed` — request and response decoders now reject non-zero reserved bytes, with dedicated decode tests.

#### ST-006

- [x] **Issue:** `replay_artifact.zig` does not validate the reserved byte after `build_mode`.
- **Source:** Review: highest-priority issue 4; file note for `packages/static_testing/src/testing/replay_artifact.zig`.
- **Scope:** `packages/static_testing/src/testing/replay_artifact.zig`
- **Tags:** `correctness`, `tests`
- **Class:** `straightforward fix`
- **Validation:** Corrupt the reserved byte in an encoded artifact and confirm current acceptance.
- **Planned lane:** `L0`
- **Disposition:** `confirmed/fixed` — artifact decode now rejects non-zero reserved bytes, with dedicated corruption coverage.

#### ST-007

- [x] **Issue:** `replay_artifact.zig` accepts unknown flags silently for v1 artifacts.
- **Source:** Review: highest-priority issue 4; file note for `packages/static_testing/src/testing/replay_artifact.zig`.
- **Scope:** `packages/static_testing/src/testing/replay_artifact.zig`
- **Tags:** `correctness`, `tests`, `docs`
- **Class:** `design decision`
- **Validation:** Corrupt flags in a valid artifact and decide whether v1 must reject unknown bits or document permissive behavior.
- **Planned lane:** `L0`
- **Disposition:** `confirmed/fixed` — v1 artifact decode now rejects unknown trace-flag bits, and tests cover corrupted-flag input.

#### ST-008

- [x] **Issue:** `fuzz_runner.zig` validates reduction budgets only after a failing case occurs.
- **Source:** Review: highest-priority issue 5; file note for `packages/static_testing/src/testing/fuzz_runner.zig`.
- **Scope:** `packages/static_testing/src/testing/fuzz_runner.zig`
- **Tags:** `correctness`, `error-handling`, `tests`
- **Class:** `straightforward fix`
- **Validation:** Configure an invalid reduction budget with a reducer and prove the error appears only after a failure path is reached.
- **Planned lane:** `L0`
- **Disposition:** `confirmed/fixed` — reducer-budget validation now happens before execution whenever a reducer is configured, with regression coverage for invalid budgets.

#### ST-009

- [x] **Issue:** `replay_runner.zig` ignores `checkpoint_digest`, allowing silent state divergence when trace metadata matches.
- **Source:** Review: medium-priority issue 1; file note for `packages/static_testing/src/testing/replay_runner.zig`.
- **Scope:** `packages/static_testing/src/testing/replay_runner.zig`
- **Tags:** `correctness`, `docs`, `tests`
- **Class:** `design decision`
- **Validation:** Decide whether checkpoint digests are part of the replay contract; if yes, construct a mismatch reproducer; if no, document that scope limit.
- **Planned lane:** `L0`
- **Disposition:** `narrowed` — checkpoint digests remain outside the replay contract for the current artifact format because replay artifacts persist trace metadata only. `runReplay()` now documents that the digest is observational-only, and tests lock in that scope.

#### ST-010

- [x] **Issue:** `sim/event_loop.zig` consumes and traces fault-script events but does not apply them to behavior.
- **Source:** Review: medium-priority issue 2; file notes for `packages/static_testing/src/testing/sim/fault_script.zig` and `packages/static_testing/src/testing/sim/event_loop.zig`.
- **Scope:** `packages/static_testing/src/testing/sim/event_loop.zig`, `packages/static_testing/src/testing/sim/fault_script.zig`
- **Tags:** `correctness`, `docs`, `tests`
- **Class:** `design decision`
- **Validation:** Determine intended phase scope from code and docs, then either implement behavior or explicitly document observational-only semantics.
- **Planned lane:** `L0`
- **Disposition:** `narrowed` — fault scripts are now documented as observational-only in this phase, and regression coverage proves due faults are counted/traced without altering scheduler behavior yet.

#### ST-011

- [x] **Issue:** `sim/event_loop.zig` applies `step_budget_max` in `runUntil()` but not in `runForSteps()`.
- **Source:** Review: medium-priority issue 3; file note for `packages/static_testing/src/testing/sim/event_loop.zig`.
- **Scope:** `packages/static_testing/src/testing/sim/event_loop.zig`
- **Tags:** `correctness`, `docs`, `tests`
- **Class:** `straightforward fix`
- **Validation:** Source-level proof and targeted test for contract inconsistency.
- **Planned lane:** `L0`
- **Disposition:** `confirmed/fixed` — `runForSteps()` now clamps to `EventLoopConfig.step_budget_max`, and tests cover the bounded behavior explicitly.

### L1 Package hygiene and I/O safety

#### ST-012

- [x] **Issue:** Generated corpus-style output is written into the package root.
- **Source:** Review: highest-priority issue 6; package metadata/build and corpus/integration/example notes.
- **Scope:** `packages/static_testing`, `packages/static_testing/src/testing/corpus.zig`, `packages/static_testing/tests/integration/fuzz_persistence.zig`, `packages/static_testing/tests/integration/replay_roundtrip.zig`, `packages/static_testing/examples/fuzz_seeded_runner.zig`, `packages/static_testing/build.zig`
- **Tags:** `correctness`, `error-handling`, `tests`, `examples`
- **Class:** `needs investigation`
- **Validation:** Trace all write paths and confirm whether the root write location is owned by library policy, example policy, integration-test policy, or all three.
- **Planned lane:** `L1`
- **Disposition:** `narrowed` — `corpus.writeCorpusEntry()` already honored a caller-provided directory; the root writes came from unit/integration/example call sites using `Dir.cwd()`. Tests now use `std.testing.tmpDir(.{})`, and the example now writes under `.zig-cache/static_testing/examples/fuzz_seeded_runner`.

#### ST-013

- [x] **Issue:** Leftover generated artifact exists in the package root.
- **Source:** Review: package metadata/generated artifact section.
- **Scope:** `packages/static_testing/phase2_fuzz_test-0x00004a9eb8a72331-00000000-00000000-748763868a655dba.bin`
- **Tags:** `correctness`, `tests`, `examples`
- **Class:** `straightforward fix`
- **Validation:** Confirm it is a generated corpus/test artifact and remove it once the output policy is fixed.
- **Planned lane:** `L1`
- **Disposition:** `confirmed/fixed` — the stale fuzz corpus artifact was removed after moving the remaining writers off the package root.

#### ST-014

- [x] **Issue:** `build.zig` smoke validation omits `examples/replay_roundtrip.zig`.
- **Source:** Review: `packages/static_testing/build.zig`.
- **Scope:** `packages/static_testing/build.zig`
- **Tags:** `tests`, `examples`
- **Class:** `straightforward fix`
- **Validation:** Source-level proof from the build graph; then decide whether smoke should include all examples or only the current smoke subset.
- **Planned lane:** `L1`
- **Disposition:** `confirmed/fixed` — the smoke step now depends on `static_testing_replay_roundtrip` in addition to the prior smoke examples.

#### ST-015

- [x] **Issue:** Bare cleanup `catch {}` remains in `bench/process.zig`.
- **Source:** Review: `packages/static_testing/src/bench/process.zig`; cross-file error-handling section.
- **Scope:** `packages/static_testing/src/bench/process.zig`
- **Tags:** `error-handling`, `docs`
- **Class:** `straightforward fix`
- **Validation:** Source-level proof; determine whether best-effort cleanup needs explicit bounded handling.
- **Planned lane:** `L1`
- **Disposition:** `confirmed/fixed` — timeout termination now handles the POSIX race with `error.ProcessNotFound` explicitly and panics on any other unexpected kill failure instead of swallowing it.

#### ST-016

- [x] **Issue:** Bare cleanup `catch {}` remains in `testing/corpus.zig` tests.
- **Source:** Review: `packages/static_testing/src/testing/corpus.zig`; cross-file error-handling section.
- **Scope:** `packages/static_testing/src/testing/corpus.zig`
- **Tags:** `error-handling`, `tests`
- **Class:** `straightforward fix`
- **Validation:** Source-level proof; replace with explicit cleanup handling or helper.
- **Planned lane:** `L1`
- **Disposition:** `confirmed/fixed` — the unit test now writes into `std.testing.tmpDir(.{})`, so cleanup is handled by the temp-dir fixture instead of a swallowed file-delete error.

#### ST-017

- [x] **Issue:** Bare cleanup `catch {}` remains in `tests/integration/fuzz_persistence.zig`.
- **Source:** Review: `packages/static_testing/tests/integration/fuzz_persistence.zig`; cross-file error-handling section.
- **Scope:** `packages/static_testing/tests/integration/fuzz_persistence.zig`
- **Tags:** `error-handling`, `tests`
- **Class:** `straightforward fix`
- **Validation:** Source-level proof.
- **Planned lane:** `L1`
- **Disposition:** `confirmed/fixed` — the integration test now persists into `std.testing.tmpDir(.{})`, eliminating the package-root write and the swallowed cleanup delete.

#### ST-018

- [x] **Issue:** Bare cleanup `catch {}` remains in `tests/integration/replay_roundtrip.zig`.
- **Source:** Review: `packages/static_testing/tests/integration/replay_roundtrip.zig`; cross-file error-handling section.
- **Scope:** `packages/static_testing/tests/integration/replay_roundtrip.zig`
- **Tags:** `error-handling`, `tests`
- **Class:** `straightforward fix`
- **Validation:** Source-level proof.
- **Planned lane:** `L1`
- **Disposition:** `confirmed/fixed` — the integration test now uses `std.testing.tmpDir(.{})` for its file-boundary round-trip instead of writing into the working directory and best-effort deleting afterward.

#### ST-019

- [x] **Issue:** Bare cleanup `catch {}` remains in `tests/support/driver_echo.zig`.
- **Source:** Review: `packages/static_testing/tests/support/driver_echo.zig`; cross-file error-handling section.
- **Scope:** `packages/static_testing/tests/support/driver_echo.zig`
- **Tags:** `error-handling`, `tests`
- **Class:** `straightforward fix`
- **Validation:** Source-level proof.
- **Planned lane:** `L1`
- **Disposition:** `confirmed/fixed` — the helper now panics on deferred stdout flush failure instead of silently discarding the error.

#### ST-020

- [x] **Issue:** Bare cleanup `catch {}` remains in `examples/fuzz_seeded_runner.zig`.
- **Source:** Review: `packages/static_testing/examples/fuzz_seeded_runner.zig`; cross-file error-handling section.
- **Scope:** `packages/static_testing/examples/fuzz_seeded_runner.zig`
- **Tags:** `error-handling`, `examples`
- **Class:** `straightforward fix`
- **Validation:** Source-level proof.
- **Planned lane:** `L1`
- **Disposition:** `confirmed/fixed` — the example now stages outputs in a dedicated `.zig-cache` subtree, clears stale state before running, and deletes that subtree with explicit panic-on-failure cleanup.

### L2 Public contract and semantics

#### ST-021

- [x] **Issue:** `BenchmarkCaseFn` is infallible, forcing benchmark targets to hide or crash on operating errors.
- **Source:** Review: `packages/static_testing/src/bench/case.zig`.
- **Scope:** `packages/static_testing/src/bench/case.zig`, downstream benchmark APIs
- **Tags:** `error-handling`, `docs`, `tests`
- **Class:** `design decision`
- **Validation:** Audit benchmark call sites and determine whether fallible benchmark targets are a supported use case or intentionally excluded.
- **Planned lane:** `L2`
- **Disposition:** `narrowed` — the current in-process benchmark surface intentionally times infallible hot-loop callbacks only. The contract is now documented explicitly so operating-error setup stays outside the measured callback.

#### ST-022

- [x] **Issue:** `blackBox(value: anytype)` copies large values by value.
- **Source:** Review: `packages/static_testing/src/bench/case.zig`; performance review section.
- **Scope:** `packages/static_testing/src/bench/case.zig`
- **Tags:** `performance`, `docs`, `benchmark`
- **Class:** `needs investigation`
- **Validation:** Source analysis plus benchmark or compile-time reasoning for large-value usage patterns.
- **Planned lane:** `L2`
- **Disposition:** `confirmed/fixed` — `bench.case` now documents `blackBox()` as a by-value helper and provides `blackBoxPointer()` for large values that should not be copied.

#### ST-023

- [x] **Issue:** `bench/compare.zig` zero-baseline behavior saturates instead of erroring, but the contract is undocumented.
- **Source:** Review: `packages/static_testing/src/bench/compare.zig`.
- **Scope:** `packages/static_testing/src/bench/compare.zig`
- **Tags:** `docs`, `tests`
- **Class:** `design decision`
- **Validation:** Decide whether saturating semantics are intentional and document/test accordingly.
- **Planned lane:** `L2`
- **Disposition:** `confirmed/fixed` — zero-baseline comparison now documents its saturating `maxInt(i64)` behavior, and dedicated tests cover zero/zero and zero/non-zero cases.

#### ST-024

- [x] **Issue:** `bench/config.zig` has minimal domain-level limit policy and includes a tautological assertion.
- **Source:** Review: `packages/static_testing/src/bench/config.zig`; assertion review section.
- **Scope:** `packages/static_testing/src/bench/config.zig`
- **Tags:** `docs`, `tests`, `performance`
- **Class:** `design decision`
- **Validation:** Decide whether domain-level caps belong in the public contract or whether integer-width bounds are sufficient.
- **Planned lane:** `L2`
- **Disposition:** `narrowed` — the tautological assertion was removed, and `validateConfig()` now documents that this layer enforces only generic boundedness/representability while leaving stronger policy caps to higher-level runners.

#### ST-025

- [x] **Issue:** Public API invalid-input policy is inconsistent across assertion vs error-return boundaries.
- **Source:** Review: cross-file best-practices section; `bench/group.zig` note.
- **Scope:** Cross-file
- **Tags:** `error-handling`, `docs`, `tests`
- **Class:** `design decision`
- **Validation:** Audit representative APIs and write the intended policy before aligning mismatches.
- **Planned lane:** `L2`
- **Disposition:** `narrowed` — the package root now documents the intended split: malformed external/runtime inputs return `InvalidInput` / `InvalidConfig`, while trusted in-code invariants stay assertion-based. The representative reviewed APIs already fit that rule closely enough that no broader signature churn was needed.

#### ST-026

- [x] **Issue:** `ProcessPrepareFn` returns `void`, so per-run setup cannot report operating errors.
- **Source:** Review: `packages/static_testing/src/bench/process.zig`.
- **Scope:** `packages/static_testing/src/bench/process.zig`
- **Tags:** `error-handling`, `docs`, `tests`
- **Class:** `design decision`
- **Validation:** Determine whether prepare hooks are intentionally best-effort or should participate in the public error contract.
- **Planned lane:** `L2`
- **Disposition:** `narrowed` — prepare hooks remain intentionally infallible and are now documented as deterministic setup hooks. Setup that can fail must happen before benchmark execution or surface through the child command itself.

#### ST-027

- [x] **Issue:** `request_resource_usage_statistics` defaults to `true`, which may perturb process benchmark results.
- **Source:** Review: `packages/static_testing/src/bench/process.zig`; performance review section.
- **Scope:** `packages/static_testing/src/bench/process.zig`
- **Tags:** `performance`, `benchmark`, `docs`, `tests`
- **Class:** `needs investigation`
- **Validation:** Measure or reason about overhead and decide whether the default should change or be documented.
- **Planned lane:** `L2`
- **Disposition:** `confirmed/fixed` — process benchmarks now default `request_resource_usage_statistics` to `false`, making extra resource-stat collection an explicit opt-in instead of part of the default timing path.

#### ST-028

- [x] **Issue:** Timeout/wait logic is duplicated between `bench/process.zig` and `testing/process_driver.zig`.
- **Source:** Review: `packages/static_testing/src/bench/process.zig`; `packages/static_testing/src/testing/process_driver.zig`; performance review section.
- **Scope:** `packages/static_testing/src/bench/process.zig`, `packages/static_testing/src/testing/process_driver.zig`
- **Tags:** `performance`, `docs`
- **Class:** `needs investigation`
- **Validation:** Compare both implementations and determine whether shared helper extraction improves correctness/maintainability without harming clarity.
- **Planned lane:** `L2`
- **Disposition:** `narrowed` — both sites now share the same explicit termination behavior, but the wait loops still carry distinct error contracts and lifecycle state. Extracting a helper now would increase generic plumbing more than it would reduce risk, so the duplication remains intentional for clarity.

#### ST-029

- [x] **Issue:** `Violation` does not enforce non-empty code/message fields.
- **Source:** Review: `packages/static_testing/src/testing/checker.zig`.
- **Scope:** `packages/static_testing/src/testing/checker.zig`
- **Tags:** `correctness`, `docs`, `tests`
- **Class:** `straightforward fix`
- **Validation:** Decide whether these are public-data invariants and add enforcement/tests if so.
- **Planned lane:** `L2`
- **Disposition:** `confirmed/fixed` — failure results now assert that every violation carries a non-empty code and message, both at `CheckResult.fail()` construction and when running a checker.

#### ST-030

- [x] **Issue:** `identityHash()` is a practical hash, but the contract/docs do not state its intended use limits clearly.
- **Source:** Review: `packages/static_testing/src/testing/identity.zig`.
- **Scope:** `packages/static_testing/src/testing/identity.zig`
- **Tags:** `docs`
- **Class:** `straightforward fix`
- **Validation:** Source-level proof plus docs update.
- **Planned lane:** `L2`
- **Disposition:** `confirmed/fixed` — `identityHash()` now documents that it is a stable non-cryptographic correlation hash, not a collision-proof or security boundary.

#### ST-031

- [x] **Issue:** `process_driver.zig` uses `anyerror` in internal read/write error mappers.
- **Source:** Review: `packages/static_testing/src/testing/process_driver.zig`; cross-file error-handling section.
- **Scope:** `packages/static_testing/src/testing/process_driver.zig`
- **Tags:** `error-handling`, `docs`
- **Class:** `needs investigation`
- **Validation:** Determine the narrowest practical internal error surface reachable from the current std I/O APIs in this Zig version.
- **Planned lane:** `L2`
- **Disposition:** `confirmed/fixed` — the internal mappers now derive their concrete read/write error sets from `std.Io.File.readStreaming()` and `std.Io.File.writeStreamingAll()` instead of accepting `anyerror`.

#### ST-032

- [x] **Issue:** `replay_artifact.zig` uses a hard-coded `header_fixed_size_bytes` without a stronger compile-time derivation/assertion.
- **Source:** Review: `packages/static_testing/src/testing/replay_artifact.zig`; assertion review section.
- **Scope:** `packages/static_testing/src/testing/replay_artifact.zig`
- **Tags:** `correctness`, `docs`, `tests`
- **Class:** `straightforward fix`
- **Validation:** Add a compile-time proof or serialization-size assertion matching the encoded field layout.
- **Planned lane:** `L2`
- **Disposition:** `confirmed/fixed` — the fixed header size is now computed from the encoded field layout and guarded by a compile-time assertion.

### L3 Coverage and documentation

#### ST-033

- [x] **Issue:** `src/bench/` has 53 public declarations and zero `///` comments.
- **Source:** Review metrics and comments/doc-generation section.
- **Scope:** `packages/static_testing/src/bench/*`
- **Tags:** `docs`
- **Class:** `straightforward fix`
- **Validation:** Public API doc audit against generated-doc needs.
- **Planned lane:** `L3`
- **Disposition:** `confirmed/fixed` — the benchmark surface now carries item-level `///` docs across root, configuration, cases, grouping, execution, statistics, comparison, process benchmarking, exports, and timers.

#### ST-034

- [x] **Issue:** Important public files lack item-level docs: `identity.zig`, `seed.zig`, `replay_artifact.zig`, and `trace.zig`.
- **Source:** Review comments/doc-generation section.
- **Scope:** `packages/static_testing/src/testing/identity.zig`, `packages/static_testing/src/testing/seed.zig`, `packages/static_testing/src/testing/replay_artifact.zig`, `packages/static_testing/src/testing/trace.zig`
- **Tags:** `docs`
- **Class:** `straightforward fix`
- **Validation:** Public API doc audit.
- **Planned lane:** `L3`
- **Disposition:** `confirmed/fixed` — the key testing surfaces now include item-level `///` docs for their public types and helpers.

#### ST-035

- [x] **Issue:** Several tests rely only on test names rather than rationale/method comments for non-obvious setups.
- **Source:** Review comments/doc-generation section.
- **Scope:** Cross-file tests
- **Tags:** `docs`, `tests`
- **Class:** `needs investigation`
- **Validation:** Identify only the non-obvious tests where rationale materially improves reviewability.
- **Planned lane:** `L3`
- **Disposition:** `narrowed` — only the non-obvious tests were updated with rationale comments, including JSON export ordering, benchmark warmup accounting, replay artifact round-trip coverage, deterministic fuzz persistence, and process-driver edge cases.

#### ST-036

- [x] **Issue:** `examples/fuzz_seeded_runner.zig` uses `orelse unreachable` for expected failure discovery.
- **Source:** Review: `packages/static_testing/examples/fuzz_seeded_runner.zig`.
- **Scope:** `packages/static_testing/examples/fuzz_seeded_runner.zig`
- **Tags:** `error-handling`, `examples`
- **Class:** `straightforward fix`
- **Validation:** Source-level proof.
- **Planned lane:** `L3`
- **Disposition:** `confirmed/fixed` — the example now asserts the deterministic precondition explicitly instead of using `orelse unreachable`.

#### ST-037

- [x] **Issue:** `tests/integration/fuzz_persistence.zig` uses `orelse unreachable`.
- **Source:** Review: `packages/static_testing/tests/integration/fuzz_persistence.zig`.
- **Scope:** `packages/static_testing/tests/integration/fuzz_persistence.zig`
- **Tags:** `error-handling`, `tests`
- **Class:** `straightforward fix`
- **Validation:** Source-level proof.
- **Planned lane:** `L3`
- **Disposition:** `confirmed/fixed` — the test now asserts the deterministic failing-seed precondition explicitly instead of using `orelse unreachable`.

#### ST-038

- [x] **Issue:** Example coverage is missing for `process_driver`.
- **Source:** Review example coverage section.
- **Scope:** Example surface
- **Tags:** `examples`, `docs`
- **Class:** `straightforward fix`
- **Validation:** Public API/example audit.
- **Planned lane:** `L3`
- **Disposition:** `confirmed/fixed` — added `examples/process_driver_roundtrip.zig` and wired it into the package example step with the driver-echo support binary.

#### ST-039

- [x] **Issue:** Example coverage is missing for `bench.process`.
- **Source:** Review example coverage section.
- **Scope:** Example surface
- **Tags:** `examples`, `docs`
- **Class:** `straightforward fix`
- **Validation:** Public API/example audit.
- **Planned lane:** `L3`
- **Disposition:** `confirmed/fixed` — added `examples/process_bench_smoke.zig` to demonstrate child-process benchmarking plus derived statistics.

#### ST-040

- [x] **Issue:** Example coverage is missing for high-level `replay_runner.runReplay()`.
- **Source:** Review: `packages/static_testing/examples/replay_roundtrip.zig`; example coverage section.
- **Scope:** Example surface
- **Tags:** `examples`, `docs`
- **Class:** `straightforward fix`
- **Validation:** Public API/example audit.
- **Planned lane:** `L3`
- **Disposition:** `confirmed/fixed` — added `examples/replay_runner_roundtrip.zig` to demonstrate high-level replay execution and classification.

#### ST-041

- [x] **Issue:** `replay_roundtrip.zig` example demonstrates artifact round-trip but not high-level replay behavior.
- **Source:** Review: `packages/static_testing/examples/replay_roundtrip.zig`.
- **Scope:** `packages/static_testing/examples/replay_roundtrip.zig`
- **Tags:** `examples`, `docs`
- **Class:** `straightforward fix`
- **Validation:** Determine whether to extend this example or add a dedicated replay-runner example.
- **Planned lane:** `L3`
- **Disposition:** `confirmed/fixed` — kept `replay_roundtrip.zig` focused on artifact encode/decode and added a dedicated `replay_runner_roundtrip.zig` example for the higher-level replay path.

### L4 Performance and benchmark decisions

#### ST-042

- [x] **Issue:** `bench/stats.zig` uses an O(n²) nth-selection algorithm with no explicit benchmark or contract note.
- **Source:** Review: `packages/static_testing/src/bench/stats.zig`; benchmark review section.
- **Scope:** `packages/static_testing/src/bench/stats.zig`
- **Tags:** `performance`, `benchmark`, `docs`
- **Class:** `needs investigation`
- **Validation:** Benchmark or bounded-cost analysis for supported sample counts, plus decision on keep/document/replace.
- **Planned lane:** `L4`
- **Disposition:** `confirmed/fixed` â€” stats now include a sorted fast path plus `computeStatsWithScratch()` for large sample sets, and public docs describe the remaining O(n²) fallback selection behavior explicitly.

#### ST-043

- [x] **Issue:** `bench/compare.zig` lacks zero-baseline and overflow-path tests.
- **Source:** Review testing-gap section.
- **Scope:** `packages/static_testing/src/bench/compare.zig`
- **Tags:** `tests`
- **Class:** `straightforward fix`
- **Validation:** Add targeted tests after contract decision for ST-023.
- **Planned lane:** `L4`
- **Disposition:** `confirmed/fixed` â€” `compareStats()` now has explicit overflow coverage in addition to the earlier zero-baseline saturation test, locking in both ends of the current comparison contract.

#### ST-044

- [x] **Issue:** `bench/config.zig` lacks overflow-path tests.
- **Source:** Review testing-gap section.
- **Scope:** `packages/static_testing/src/bench/config.zig`
- **Tags:** `tests`
- **Class:** `straightforward fix`
- **Validation:** Add targeted overflow reproducer.
- **Planned lane:** `L4`
- **Disposition:** `confirmed/fixed` â€” overflow coverage now documents both target-width outcomes: 32-bit targets reject the maximal `u32 * u32` product, while 64-bit targets keep accepting it with a compile-time proof that the product still fits `usize`.

#### ST-045

- [x] **Issue:** `bench/runner.zig` lacks `NoSpaceLeft` / `InvalidConfig` coverage and still carries a dead helper.
- **Source:** Review file note and testing-gap section.
- **Scope:** `packages/static_testing/src/bench/runner.zig`
- **Tags:** `tests`, `docs`
- **Class:** `straightforward fix`
- **Validation:** Add negative tests and confirm whether `mapTimerError()` remains dead.
- **Planned lane:** `L4`
- **Disposition:** `confirmed/fixed` â€” added direct invalid-config and undersized-storage tests for `runCase()` / `runGroup()`, and removed the dead `mapTimerError()` helper.

#### ST-046

- [x] **Issue:** `testing/corpus.zig` lacks invalid extension, small-buffer, and artifact-buffer-too-small coverage.
- **Source:** Review file note and testing-gap section.
- **Scope:** `packages/static_testing/src/testing/corpus.zig`
- **Tags:** `tests`
- **Class:** `straightforward fix`
- **Validation:** Add targeted negative tests.
- **Planned lane:** `L4`
- **Disposition:** `confirmed/fixed` â€” corpus tests now cover invalid extensions, undersized entry-name buffers, and undersized artifact buffers during persistence.

#### ST-047

- [x] **Issue:** `testing/driver_protocol.zig` lacks invalid magic, truncated-buffer, and reserved-byte tests.
- **Source:** Review file note and testing-gap section.
- **Scope:** `packages/static_testing/src/testing/driver_protocol.zig`
- **Tags:** `tests`
- **Class:** `straightforward fix`
- **Validation:** Add targeted decode-failure tests.
- **Planned lane:** `L4`
- **Disposition:** `confirmed/fixed` â€” decode coverage now includes invalid magic and truncated headers, complementing the earlier reserved-byte regression tests.

#### ST-048

- [x] **Issue:** `testing/fuzz_runner.zig` lacks invalid-reduction-budget, persistence-disabled, and persistence-buffer coverage.
- **Source:** Review file note and testing-gap section.
- **Scope:** `packages/static_testing/src/testing/fuzz_runner.zig`
- **Tags:** `tests`
- **Class:** `straightforward fix`
- **Validation:** Add targeted tests once ST-008 is resolved.
- **Planned lane:** `L4`
- **Disposition:** `confirmed/fixed` â€” fuzz-runner tests now cover both invalid reduction-budget fields, failing-case behavior with persistence disabled, and persistence-buffer exhaustion.

#### ST-049

- [x] **Issue:** `testing/identity.zig` lacks coverage for all identity-field deltas.
- **Source:** Review: `packages/static_testing/src/testing/identity.zig`; testing-gap section.
- **Scope:** `packages/static_testing/src/testing/identity.zig`
- **Tags:** `tests`
- **Class:** `straightforward fix`
- **Validation:** Add remaining delta tests if the current contract stands.
- **Planned lane:** `L4`
- **Disposition:** `confirmed/fixed` â€” identity-hash coverage now includes package name, build mode, case index, and run index deltas in addition to the earlier seed and run-name checks.

#### ST-050

- [x] **Issue:** `testing/seed.zig` lacks uppercase-hex, max-width, and overflow boundary coverage.
- **Source:** Review: `packages/static_testing/src/testing/seed.zig`; testing-gap section.
- **Scope:** `packages/static_testing/src/testing/seed.zig`
- **Tags:** `tests`
- **Class:** `straightforward fix`
- **Validation:** Add boundary tests.
- **Planned lane:** `L4`
- **Disposition:** `confirmed/fixed` â€” seed parsing now has explicit tests for uppercase hex input, maximum-width hexadecimal values, and decimal/hexadecimal overflow boundaries.

#### ST-051

- [x] **Issue:** `testing/trace.zig` lacks multi-event JSON and sequence-boundary coverage.
- **Source:** Review: `packages/static_testing/src/testing/trace.zig`; testing-gap section.
- **Scope:** `packages/static_testing/src/testing/trace.zig`
- **Tags:** `tests`
- **Class:** `straightforward fix`
- **Validation:** Add targeted tests.
- **Planned lane:** `L4`
- **Disposition:** `confirmed/fixed` â€” trace tests now lock in multi-event Chrome JSON ordering and the valid/invalid sequence-range boundaries for `TraceBuffer.init()`.

#### ST-052

- [x] **Issue:** `sim/mailbox.zig` lacks invalid-capacity and `peek()` coverage.
- **Source:** Review: `packages/static_testing/src/testing/sim/mailbox.zig`; testing-gap section.
- **Scope:** `packages/static_testing/src/testing/sim/mailbox.zig`
- **Tags:** `tests`
- **Class:** `straightforward fix`
- **Validation:** Add targeted tests.
- **Planned lane:** `L4`
- **Disposition:** `confirmed/fixed` â€” mailbox tests now cover invalid zero capacity, empty peek behavior, and the invariant that `peek()` does not dequeue the head element.

#### ST-053

- [x] **Issue:** `sim/scheduler.zig` traces only `chosen_id`, limiting diagnostics.
- **Source:** Review: `packages/static_testing/src/testing/sim/scheduler.zig`.
- **Scope:** `packages/static_testing/src/testing/sim/scheduler.zig`
- **Tags:** `docs`, `performance`, `tests`
- **Class:** `design decision`
- **Validation:** Decide whether trace payload should expand or remain intentionally small.
- **Planned lane:** `L4`
- **Disposition:** `narrowed` â€” the scheduler trace remains intentionally minimal. Module docs now state that only `chosen_id` is traced because full replay fidelity already comes from persisted `ScheduleDecision` values, and tests lock in the current trace payload.

#### ST-054

- [x] **Issue:** `sim/scheduler.zig` lacks trace overflow / append-failure coverage.
- **Source:** Review: `packages/static_testing/src/testing/sim/scheduler.zig`; testing-gap section.
- **Scope:** `packages/static_testing/src/testing/sim/scheduler.zig`
- **Tags:** `tests`
- **Class:** `straightforward fix`
- **Validation:** Add targeted tests once the trace contract is finalized.
- **Planned lane:** `L4`
- **Disposition:** `confirmed/fixed` â€” added trace overflow coverage and fixed the underlying state-ordering bug so trace append failure no longer partially commits recorded decisions or consumes ready items.

#### ST-055

- [x] **Issue:** `sim/timer_queue.zig` is a benchmark candidate, but no benchmark currently justifies wrapper overhead.
- **Source:** Review: `packages/static_testing/src/testing/sim/timer_queue.zig`; benchmark review section.
- **Scope:** `packages/static_testing/src/testing/sim/timer_queue.zig`
- **Tags:** `benchmark`, `performance`
- **Class:** `needs investigation`
- **Validation:** Decide whether benchmark implementation is in scope now and what baseline to use against `static_scheduling.timer_wheel`.
- **Planned lane:** `L4`
- **Disposition:** `confirmed/fixed` â€” `zig build bench` now includes a timer-queue benchmark comparing `TimerQueue.scheduleAfter()+drainDue()` against raw `static_scheduling.timer_wheel.TimerWheel.schedule()+tick()` for equivalent next-tick workloads.

#### ST-056

- [x] **Issue:** `sim/event_loop.zig` lacks idle, backward-target, fault, and trace coverage.
- **Source:** Review file note and testing-gap section.
- **Scope:** `packages/static_testing/src/testing/sim/event_loop.zig`
- **Tags:** `tests`
- **Class:** `straightforward fix`
- **Validation:** Add targeted tests after ST-010 and ST-011 are resolved.
- **Planned lane:** `L4`
- **Disposition:** `confirmed/fixed` â€” event-loop tests now cover idle termination, backward-target rejection, and the finalized fault/jump trace behavior.

#### ST-057

- [x] **Issue:** `tests/integration/process_driver_roundtrip.zig` lacks payload-limit and pending-request misuse coverage.
- **Source:** Review testing-gap section.
- **Scope:** `packages/static_testing/tests/integration/process_driver_roundtrip.zig`
- **Tags:** `tests`
- **Class:** `straightforward fix`
- **Validation:** Add integration or unit-level misuse coverage after process-driver contract review.
- **Planned lane:** `L4`
- **Disposition:** `confirmed/fixed` â€” integration coverage now exercises max-payload rejection and the single-in-flight request contract.

#### ST-058

- [x] **Issue:** `tests/integration/process_bench_smoke.zig` lacks resource-statistics and timeout-related coverage.
- **Source:** Review file note and testing-gap section.
- **Scope:** `packages/static_testing/tests/integration/process_bench_smoke.zig`
- **Tags:** `tests`, `benchmark`
- **Class:** `needs investigation`
- **Validation:** Add targeted coverage if those behaviors remain public and configurable after ST-027.
- **Planned lane:** `L4`
- **Disposition:** `confirmed/fixed` â€” integration tests now cover explicit RSS opt-in behavior and timeout propagation across the public process-benchmark API.

#### ST-059

- [x] **Issue:** The package lacks implemented benchmark decisions for the review’s proposed targets.
- **Source:** Review benchmark section.
- **Scope:** Benchmark surfaces across `bench/stats.zig`, `testing/replay_artifact.zig`, `testing/driver_protocol.zig`, `testing/sim/timer_queue.zig`, `testing/trace.zig`, `bench/process.zig`, `testing/process_driver.zig`
- **Tags:** `benchmark`, `performance`, `docs`
- **Class:** `needs investigation`
- **Validation:** Decide which benchmarks are in scope now, define baselines, and explicitly defer the rest if needed.
- **Planned lane:** `L4`
- **Disposition:** `confirmed/fixed` â€” Phase 8 implemented a scoped benchmark step (`zig build bench`) covering `bench.stats` and `sim.timer_queue` with explicit baselines, and documented the remaining benchmark targets as deferred with rationale and future comparison baselines.
