# `static_testing` feature-gap analysis - 2026-03-09

## Scope

Package: `packages/static_testing`

This note is not another benchmark pass. It is a research and comparison pass to identify plausible missing features by comparing the current package surface against adjacent official tooling.

Current package strengths already in place:

- deterministic seeds, identities, traces, replay metadata, and corpus persistence;
- deterministic fuzz orchestration plus seed reduction;
- deterministic simulation primitives plus replayable scheduler decisions; and
- in-process and process benchmark execution, comparison, export, and process-driver support.

The comparison set below uses official documentation from:

- Proptest;
- Rust Fuzz Book / `cargo fuzz`;
- Criterion.rs;
- Loom;
- Shuttle;
- Playwright; and
- Jest.

## Summary table

| Feature | Why it fits `static_testing` | Why it may be scope creep | Difficulty | Recommendation |
| --- | --- | --- | --- | --- |
| Persisted benchmark baselines and gating | Extends `bench.compare`, `bench.stats`, `bench.export` naturally | Full Criterion-style statistics and reporting can bloat the package | Medium | Strong near-term candidate |
| State-machine/property harness | Reuses `checker`, `replay_runner`, `sim`, and deterministic seeds well | A generic DSL can become a second framework inside the package | Medium-High | Strong candidate |
| Rich replay failure bundles | Builds directly on `trace`, `replay_artifact`, `corpus`, and `checker` | Stable bundle formats and viewer tooling add long-term maintenance | Medium-High | Strong candidate if debugging UX matters |
| Schedule-exploration portfolio | Reuses replayable `ScheduleDecision` and deterministic event-loop stepping | Full Loom-style concurrency instrumentation is much larger than this package | Medium for package-local; Very High for general concurrency | Good only as a narrow package-local feature |
| Strategy-based generators and shrink trees | Fits the seeded fuzz runner and reducer story | A Proptest-grade strategy engine is a major surface-area increase | High | Only if property testing becomes a primary goal |
| Snapshot/golden helper | Stable exports and replay artifacts make this easy to layer in | Snapshot churn can create noisy tests and weak review signal | Low-Medium | Reasonable opt-in helper |
| Coverage-guided fuzzing interop | Corpus and fuzz persistence give it a natural integration point | External toolchains, nightly/instrumentation, and non-deterministic feedback loops clash with package goals | High | Keep out of core; consider docs/integration only |

## Candidate features

### 1. Persisted benchmark baselines and gating

Comparable tools:

- Criterion.rs stores previous benchmark data and compares new runs against saved baselines.
- Criterion.rs also exposes a configurable noise threshold and custom baselines.

Why it might work here:

- `packages/static_testing/src/bench/compare.zig` already has the beginnings of a regression-comparison vocabulary.
- `packages/static_testing/src/bench/stats.zig` already derives the summary values that a baseline file would need.
- `packages/static_testing/src/bench/export.zig` already serializes stable results, so a baseline format could stay simple and explicit.
- This fits the package's current control-plane style: bounded data, explicit errors, caller-controlled storage, deterministic comparison.

Why it might not, or might become scope creep:

- Criterion.rs spends a lot of complexity on bootstrap statistics, noise handling, and richer comparison output. Copying that whole model would overshoot the current package philosophy.
- If baseline persistence grows into charts, HTML reports, or CI dashboards, it becomes a benchmarking product instead of a focused deterministic testing library.
- The package must decide whether it wants "simple threshold gate" semantics or "statistical confidence" semantics. Mixing both would muddy the API.

Difficulty:

- **Medium** for a narrow feature: save one baseline artifact, reload it, compare via existing stats, and optionally fail on configured thresholds.
- **High** if it tries to replicate Criterion.rs-style full statistical reporting.

Recommendation:

- Good next feature if benchmark workflows matter in CI.
- Keep the first version narrow: persisted baseline artifact, explicit threshold config, and machine-readable diff output.

### 2. State-machine / model-based test harness

Comparable tools:

- Proptest's state-machine testing support drives a system under test from a reference state machine and shrinks failing transition sequences.

Why it might work here:

- `packages/static_testing/src/testing/checker.zig` already has a clear pass/fail vocabulary.
- `packages/static_testing/src/testing/replay_runner.zig` already treats deterministic replay as a first-class concept.
- `packages/static_testing/src/testing/sim/` already provides explicit logical time, scheduling, and fault injection primitives.
- `static_testing` already thinks in terms of deterministic executions and replayable traces, which is exactly the right substrate for model-based tests.

Why it might not, or might become scope creep:

- A generic state-machine DSL can grow quickly: transition generation, preconditions, invariants, reference-model APIs, shrinking, reporting, and replay serialization.
- This could duplicate some of the package's simulation layer if it becomes "yet another way" to model transitions and state.
- If the design chases Proptest-level generality, it will likely pull in more dynamic strategy machinery than this package currently wants.

Difficulty:

- **Medium-High** for a narrow sequential harness over deterministic transitions.
- **High** if it also adds automatic shrinking and rich transition generation in the same phase.

Recommendation:

- Strong candidate, but only if scoped to sequential deterministic models first.
- The most credible first step is not a full DSL; it is a typed harness that runs reference transitions, checks invariants, and persists failing sequences for replay.

### 3. Rich replay failure bundles

Comparable tools:

- Playwright traces bundle actions and debugging context specifically to inspect failed tests after the fact.
- Playwright recommends traces because they capture more useful failure context than simpler artifacts.

Why it might work here:

- `packages/static_testing/src/testing/replay_artifact.zig` is explicitly phase-1 and currently stores only identity plus trace metadata.
- `packages/static_testing/src/testing/trace.zig` already supports bounded event storage and Chrome-trace JSON export.
- `packages/static_testing/src/testing/corpus.zig` already persists deterministic failure artifacts.
- `packages/static_testing/src/testing/checker.zig` already has structured violations that could be recorded alongside trace data.

Why it might not, or might become scope creep:

- Stable binary bundle formats are expensive to maintain once external users depend on them.
- Full traces, checkpoints, or per-step payloads increase artifact size, privacy sensitivity, and storage churn.
- A viewer story can easily snowball into web tooling, HTML rendering, or trace-browser work that is outside the package's current scope.

Difficulty:

- **Medium-High** for a bundle that stores full trace events, checker violations, and optional checkpoint summaries.
- **High** if paired with a dedicated GUI or interactive viewer.

Recommendation:

- Good feature if post-mortem debugging is a priority.
- The narrow version should stop at "artifact bundle + Chrome trace companion + stable decode API", not "build a trace UI."

### 4. Schedule-exploration portfolio

Comparable tools:

- Loom explores scheduler permutations exhaustively within its modeled world.
- Shuttle offers random, PCT, DFS, replay, and multi-scheduler portfolio execution.

Why it might work here:

- `packages/static_testing/src/testing/sim/scheduler.zig` already has replayable `ScheduleDecision`.
- `packages/static_testing/src/testing/sim/event_loop.zig` already steps deterministically and now has stronger rollback behavior.
- A package-local exploration runner could stay bounded: vary scheduler strategy, preemption/fault budgets, or replay schedules over the simulation layer.

Why it might not, or might become scope creep:

- Loom-style exploration is intrusive by design: it requires code to use Loom-aware primitives, and that is not this package's current model.
- A general concurrency-testing framework would require replacement synchronization types, model-aware threads/tasks, and much deeper integration than `static_testing` currently exposes.
- State explosion is real. A shallow portfolio is plausible; an exhaustive general model checker is not.

Difficulty:

- **Medium** for a package-local exploration portfolio over `sim.scheduler` and `sim.event_loop`.
- **Very High** for a general concurrency-testing system comparable to Loom or Shuttle.

Recommendation:

- Worth considering only as a narrow simulation feature.
- Avoid framing it as "generic concurrency model checking." Frame it as "bounded schedule exploration for `static_testing.sim`."

### 5. Strategy-based generators and shrink trees

Comparable tools:

- Proptest builds tests around composable strategies and shrinking.
- `cargo fuzz` structure-aware fuzzing uses `Arbitrary`-driven typed inputs instead of raw bytes.

Why it might work here:

- `packages/static_testing/src/testing/fuzz_runner.zig` already provides deterministic orchestration and failure persistence.
- `packages/static_testing/src/testing/reducer.zig` already shows the package is willing to invest in deterministic shrinking/minimization concepts.
- Typed strategies would make it easier to test APIs that are awkward to drive from a raw `case_index` split-seed model.

Why it might not, or might become scope creep:

- A real strategy algebra is a large feature surface: generator composition, shrink trees, recursion limits, distributions, filtering, diagnostics, and reproducibility semantics.
- It risks importing property-testing complexity into a package that is currently more explicit and lower ceremony.
- If it depends on dynamic allocation or recursive generator trees, it may cut against the package's safety and boundedness rules.

Difficulty:

- **High** even for a reduced feature set.
- **Very High** if the goal is to approach Proptest-level expressiveness.

Recommendation:

- Do not build this unless property testing becomes a package pillar.
- If pursued, start with a tiny fixed-capacity typed generator layer, not a full Proptest analogue.

### 6. Snapshot / golden assertion helper

Comparable tools:

- Jest snapshot testing stores approved output artifacts and compares future runs against them.

Why it might work here:

- `static_testing` already produces stable text/JSON/CSV/Markdown exports and deterministic replay artifacts.
- This package already values deterministic, reviewable artifacts; that aligns naturally with golden-file workflows.
- A small helper around "render -> compare -> write/update artifact" would fit many current examples and tests.

Why it might not, or might become scope creep:

- Snapshot-heavy suites can devolve into approving noise rather than checking semantics.
- The package may not want to own update flows, diff output, artifact naming, and CI ergonomics.
- Snapshot helpers become opinionated quickly: inline vs external, update flags, directory layout, normalization rules, and diff formatting.

Difficulty:

- **Low-Medium** for a narrow helper that compares caller-rendered bytes against a file.
- **Medium** if it adds update modes, pretty diffs, and built-in normalization.

Recommendation:

- Plausible as a small optional helper, especially for export and artifact tests.
- Keep it deliberately dumb if added.

### 7. Coverage-guided fuzzing interop

Comparable tools:

- `cargo fuzz` supports structure-aware fuzzing, coverage generation, and CI integration around fuzz targets and corpora.

Why it might work here:

- `packages/static_testing/src/testing/corpus.zig` already gives the package a concrete failure-artifact vocabulary.
- `packages/static_testing/src/testing/fuzz_runner.zig` already has a deterministic regression loop that could consume or export corpora.
- A thin adapter layer could make `static_testing` easier to use alongside external fuzzers without turning it into one.

Why it might not, or might become scope creep:

- Coverage-guided fuzzing depends on compiler instrumentation, external engines, and toolchain setup that sit outside this package's clean deterministic model.
- The feedback loop is intentionally non-deterministic and heuristic-driven; that is philosophically different from the package's seed-and-replay story.
- Supporting nightly, sanitizer, and LLVM coverage workflows directly would create a large maintenance burden.

Difficulty:

- **High** for a serious integration surface.
- **Very High** if the package tries to subsume external fuzzing workflows instead of interoperating with them.

Recommendation:

- Keep this out of the core library.
- At most, add documentation or import/export adapters so users can connect `static_testing` artifacts to external fuzzers.

## Best-fit ordering

If the goal is to add the highest-value missing features without losing the package's current shape, the best order is:

1. persisted benchmark baselines and gating;
2. state-machine / model-based harness;
3. richer replay bundles;
4. narrow schedule-exploration modes for the existing simulation layer;
5. optional snapshot helper;
6. typed strategy/shrinker layer only if property testing becomes central; and
7. coverage-guided fuzzing only as external interop, not as a core feature.

## Recommendation

The most promising missing features are the ones that extend existing package ideas instead of importing a second ecosystem whole:

- **Best fit now:** persisted benchmark baselines, state-machine harness, richer replay bundles.
- **Good but tightly scoped only:** simulation schedule exploration, snapshot helpers.
- **High risk of scope creep:** Proptest-style strategies and shrink trees, or direct coverage-guided fuzzing support.

The package is already strongest when it stays deterministic, bounded, explicit, and artifact-oriented. The next features should continue that pattern.

## Sources

- Proptest introduction: https://proptest-rs.github.io/proptest/
- Proptest state-machine testing: https://proptest-rs.github.io/proptest/proptest/state-machine.html
- Rust Fuzz Book, structure-aware fuzzing: https://rust-fuzz.github.io/book/cargo-fuzz/structure-aware-fuzzing.html
- Rust Fuzz Book, coverage: https://rust-fuzz.github.io/book/cargo-fuzz/coverage.html
- Rust Fuzz Book, CI integration: https://rust-fuzz.github.io/book/cargo-fuzz/ci.html
- Criterion.rs analysis process: https://bheisler.github.io/criterion.rs/book/analysis.html
- Criterion.rs baselines / CLI comparison behavior: https://bheisler.github.io/criterion.rs/book/user_guide/command_line_options.html
- Loom docs: https://docs.rs/loom/latest/loom/
- Shuttle docs: https://docs.rs/shuttle/latest/shuttle/
- Shuttle schedulers: https://docs.rs/shuttle/latest/shuttle/scheduler/
- Playwright tracing API: https://playwright.dev/docs/api/class-tracing
- Playwright trace viewer: https://playwright.dev/docs/trace-viewer
- Jest snapshot testing: https://jestjs.io/docs/snapshot-testing
