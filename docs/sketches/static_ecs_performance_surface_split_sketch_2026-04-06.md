# `static_ecs` performance surface split sketch - 2026-04-06

This sketch organizes the next exploration, research, and experiment paths for
`static_ecs` after the current benchmark and invariant-scan work. It also
separates the non-ideal benchmark domains into:

- items that should be improved inside the current API shape; and
- items that likely need a different API or calling structure so one workload
  does not permanently tax another.

This sketch is a design and experiment organizer, not an implementation plan.
Use it to decide which work should become active plans and which ideas should
stay as isolated throwaway experiments first.

## Inputs and current posture

The current shape should be read alongside:

- [static_ecs_performance_experiment_loop_2026-04-05.md](../plans/active/packages/static_ecs_performance_experiment_loop_2026-04-05.md)
- [static_ecs_production_benchmark_backlog_2026-04-05.md](./static_ecs_production_benchmark_backlog_2026-04-05.md)
- [static_ecs_shape_and_ownership_sketch_2026-04-04.md](./static_ecs_shape_and_ownership_sketch_2026-04-04.md)

The current benchmark posture says:

- micro hot paths are now mostly in a good state;
- dense typed query and simple pass workloads are already strong;
- scalar structural churn is still materially behind fused structural paths;
- mixed command-buffer apply and setup-heavy flows are still expensive;
- large fragmented, branch-heavy, and write-heavy workloads still have room;
- allocator choice is a first-class lever, but the ECS boundary should likely
  stay allocator-agnostic;
- some remaining non-ideal cases are not bugs in the current API, but a sign
  that one surface is trying to serve more than one workload shape.

## Working distinction

Use this distinction before opening any performance task:

### Category A: same API, better implementation

These are cases where the current public surface is still correct, but the
implementation likely leaves performance on the table.

Examples:

- scalar structural transition caching or batching improvements;
- apply-side archetype move optimization;
- chunk fill and empty-chunk reuse heuristics;
- codegen-shape or lower-package helper improvements that preserve semantics.

### Category B: mixed workloads on one surface

These are cases where the non-ideal result may be inherent to the fact that
one API is covering two different use cases at once.

Examples:

- hot typed queries versus dynamic tooling queries;
- immediate scalar structural mutation versus deferred or fused mutation;
- steady-state frame execution versus setup-heavy one-shot world construction;
- hot small components versus cold large components in one chunk residency
  policy.

Category B items should not default to "optimize the one API harder." They
should first be evaluated as candidates for separate surfaces, explicit modes,
or explicit caller-visible control flow.

## Domain map of current non-ideal items

### 1. Scalar structural churn

Observed posture:

- scalar insert/remove style paths remain materially slower than fused bundle
  paths in the current structural benchmarks;
- this is expected from repeated archetype transitions, but still expensive
  enough to matter.

Interpretation:

- some improvement should still come from implementation work inside the
  current API;
- beyond that, the real issue may be that repeated scalar structural mutation
  is being asked to serve a workload that actually wants a staged or fused
  batch mutation surface.

Likely split:

- keep immediate scalar mutation as a correctness-first control-plane API;
- treat fused bundle mutation and staged command-buffer mutation as the
  performance-first structural surfaces;
- consider explicit "transaction" or "mutation batch" APIs if callers need
  immediate-looking code with batched execution semantics.

### 2. Query fragmentation and branch-heavy frame workloads

Observed posture:

- dense typed queries are already strong;
- fragmented scans and branch-heavy multi-system workloads still cost
  materially more.

Interpretation:

- some overhead is fundamental to archetype fragmentation;
- some overhead may still be reducible;
- a fully dynamic or plan-cached query surface should not be forced into the
  hot typed path unless it proves a real win.

Likely split:

- keep the current typed query/view path as the hot-loop default;
- if tooling, editors, or runtime query composition become important, add a
  separate erased or planned query surface rather than burdening the typed hot
  path with dynamic machinery;
- if system scheduling later wants reusable query plans, that should likely be
  a scheduler-facing or planner-facing surface, not the default typed iterator.

### 3. Command-buffer staged apply versus setup-heavy control-plane use

Observed posture:

- stage-only command-buffer work is now cheap;
- setup-only and mixed apply cases still dominate the total cost in the phase
  and staged-apply owners.

Interpretation:

- command staging is no longer the main issue;
- callers that create fresh worlds, fresh buffers, or fresh target entity sets
  per operation are measuring a very different workload from steady-state
  mutation on a warm world.

Likely split:

- keep the current command buffer for steady-state deterministic staging;
- consider separate helper surfaces for one-shot setup-heavy workflows, such as
  benchmark fixtures, import pipelines, or bulk load paths;
- if pure apply throughput becomes important, expose an apply-only or
  prevalidated-command surface rather than conflating it with setup and stage.

### 4. Allocator strategy

Observed posture:

- slab-backed ECS usage is materially faster than page-allocator-backed usage
  in the allocator strategy benchmarks;
- the current ECS implementation is correctly allocator-agnostic.

Interpretation:

- this is not a signal to bake one allocator into ECS internals;
- it is a signal that performance-sensitive callers want a clearer "allocator
  profile" story than a raw `Allocator` alone communicates.

Likely split:

- keep the core ECS runtime allocator-agnostic;
- add documented allocator profiles, setup helpers, or example constructors for
  common modes such as benchmark mode, slab-backed steady-state worlds, and
  simple page-allocator bring-up;
- only move allocator specialization into ECS internals if the benchmark win
  cannot be expressed by caller-supplied allocators.

### 5. Hot versus cold component residency

Observed posture:

- write-heavy and larger fragmented frame workloads still have visible cost;
- current chunk policy treats all admitted component columns as one residency
  family.

Interpretation:

- a uniform chunk policy is good for simplicity and many hot-loop cases;
- some workloads likely want rarely-touched or large components off the hot
  chunk path.

Likely split:

- keep the current all-in-chunk model as the default typed ECS path;
- explore explicit cold-component or side-storage policies only as a separate,
  opt-in surface;
- do not let a cold-storage abstraction burden dense hot loops by default.

### 6. Persistent simulation worlds versus tooling/editor/import worlds

Observed posture:

- setup-heavy benchmark slices are materially slower than steady-state hot
  loops;
- some current benchmark gaps are really world construction and fixture
  preparation cost, not steady-state ECS execution cost.

Interpretation:

- this is a genuine use-case split, not one number needing one optimization;
- a world that lives for many frames has different needs than a short-lived
  import, editor, inspection, or test fixture world.

Likely split:

- keep steady-state simulation worlds optimized for reuse, chunk retention, and
  long-lived buffers;
- consider separate convenience or builder surfaces for short-lived worlds,
  test fixtures, imports, or replay setup;
- benchmark them separately rather than using one owner to imply one
  performance story.

## Exploration and research tracks

These tracks should stay distinct so measurements stay interpretable.

### Track 1: implementation-local ECS optimization

Goal:

- improve current hot and churn paths without changing public semantics.

Candidate areas:

- narrower scalar transition caching or bundle-width-aware transition helpers;
- apply-side command decode and dispatch tightening;
- archetype creation and append-path fast-path refinement;
- chunk reuse and fill-policy sweeps after the current invariant cleanup;
- targeted hot-path codegen shaping where Zig is leaving obvious overhead.

Promote from this track only if:

- the current API remains the right shape for the workload; and
- improvements hold across more than one relevant benchmark owner or produce a
  very large win in one important owner without collateral regressions.

### Track 2: API and calling-structure split research

Goal:

- identify where one API is hiding multiple incompatible performance stories.

Candidate questions:

- should there be an explicit batch mutation or transaction API between scalar
  immediate mutation and the current command buffer?;
- should hot typed queries and dynamic tooling queries be separate first-class
  surfaces?;
- should ECS setup-heavy workflows have a builder or import-oriented API that
  is benchmarked separately from frame execution?;
- should cold components or side indexes be admitted through explicit traits or
  separate storage families rather than default chunk residency?

Do not promote directly from this track into the main API unless:

- benchmarks show a clear split in workload needs; and
- the new surface can be documented without making the current hot path less
  obvious or less efficient.

### Track 3: lower-package and allocator research

Goal:

- probe whether the next meaningful win sits below `static_ecs`.

Candidate areas:

- `static_collections` helpers for bounded reserve-write or length-bump shapes;
- `static_memory` allocator profiles, pool/slab reuse policy, and setup-cost
  isolation;
- any archetype-key or map-lookup cost that would justify lower-package data
  structure work instead of more ECS-local caching.

Rule:

- only promote lower-package work if the package itself wants that capability
  on its own merits, not just because ECS can exploit it.

### Track 4: Zig/codegen and mode-sensitivity research

Goal:

- find hot paths where source shape or mode interaction still dominates
  outcomes.

Candidate areas:

- tiny helper layering in `hasComponent`, component lookup, query startup, and
  apply dispatch;
- branchy generic code that can be rewritten into simpler SSA forms;
- runtime-safety-only validation that still leaks expensive traversal into
  `ReleaseFast`.

Rule:

- keep these as narrow experiments;
- only promote source-shape changes that remain understandable and defensible.

### Track 5: observability expansion

Goal:

- make the remaining ambiguous benchmark stories attributable before tuning
  against them.

Candidate new owners or case groups:

- apply-only command-buffer benchmarks over prebuilt staged buffers;
- setup/reuse cadence benchmarks over persistent worlds and persistent command
  buffers;
- scalar width sweeps for `insert`, `remove`, `insertBundle`, and
  `removeBundle`;
- zero-match and sparse-match query startup cases;
- cold-start versus warmed-cache passes;
- hot-versus-cold component residency comparisons if that storage split becomes
  real;
- allocator-backed world setup, steady-state, and teardown separation.

## Experimental path ordering

Use this ordering unless a new benchmark result changes priority.

### Phase 1: finish measuring what the current API shape is already telling us

- add missing attribution benchmarks before opening broad implementation work;
- close the gap between setup-heavy, stage-only, apply-only, and steady-state
  frame measurements;
- add scalar-width structural churn cases and zero-match query startup cases.

### Phase 2: continue narrow implementation experiments inside the current API

- command apply-side decode/dispatch;
- scalar churn and archetype transition refinements;
- targeted allocator and chunk reuse experiments;
- tightly scoped codegen-shape rewrites.

### Phase 3: open explicit API-split research only where Phase 2 stalls

- batch mutation or transaction surface;
- hot typed query versus dynamic planned query separation;
- cold component or side-storage split;
- setup-heavy world builder or import-oriented surface.

### Phase 4: only then consider radical storage-model changes

- archetype transition graphs;
- persistent query plans as first-class objects;
- split residency or multi-family storage policies;
- more dramatic world-family specialization.

Radical storage changes should not start while simpler attribution gaps remain.

## Candidate API and calling-structure splits

These are the most likely places where one current surface is trying to serve
too many workloads.

### Split A: immediate mutation versus batched mutation

Current tension:

- immediate scalar calls are easy to use;
- they are not the best shape for repeated structural churn.

Candidate directions:

- explicit batch mutation object;
- world-local structural transaction;
- bundle-first mutation helpers with stronger width-oriented ergonomics.

Risk:

- avoid making the simple control-plane surface awkward for callers who do not
  need maximum throughput.

### Split B: typed hot queries versus dynamic queries

Current tension:

- typed queries are the correct hot path;
- dynamic query machinery is attractive for tooling and editors but not for the
  hot loop.

Candidate directions:

- keep the typed path as the default ECS surface;
- add an erased query-plan surface later for tooling, editors, diagnostics, or
  runtime-composed systems;
- keep shared matching semantics, but not shared hot-path machinery.

Risk:

- avoid infecting the typed path with dynamic plan allocation or maintenance.

### Split C: steady-state runtime versus builder/import runtime

Current tension:

- one-shot setup-heavy workflows and persistent worlds have different
  performance levers.

Candidate directions:

- explicit world builder or fixture/import helper;
- explicit reusable command-buffer and world-setup helpers;
- benchmark labels that clearly distinguish setup, warm steady-state, and
  teardown.

Risk:

- avoid polluting steady-state world APIs with builder-only bookkeeping.

### Split D: default chunk residency versus opt-in cold storage

Current tension:

- dense in-chunk storage is best for hot small components;
- cold or large components may want a different path.

Candidate directions:

- opt-in cold component trait;
- side-store handle columns;
- explicit "hot world" versus "mixed residency" world configuration if the
  split becomes real enough.

Risk:

- avoid universal abstraction layers that burden the simple hot-world path.

### Split E: raw allocator entry versus allocator profile entry

Current tension:

- a raw allocator is flexible and correct;
- it does not communicate the intended steady-state allocation strategy.

Candidate directions:

- documented setup helpers for slab-backed worlds and buffers;
- benchmark-backed allocator profile guidance;
- optional convenience constructors that still preserve allocator ownership at
  the caller boundary.

Risk:

- avoid hard-wiring lower-package policy into the ECS core.

## Evidence thresholds before opening new API work

Open a new API or calling-structure plan only when at least one of these is
true:

- the current benchmark gap persists after at least one narrow implementation
  experiment;
- the benchmark gap is caused by setup or usage-shape differences rather than
  one hot implementation detail;
- the likely fix would add persistent overhead or complexity to the current hot
  path;
- two user-facing workload families are asking for contradictory tuning.

If those thresholds are not met, keep the work as an implementation experiment
first.

## Concrete next experiments worth planning

These are the best next additions to the current loop from this sketch.

### Near-term benchmark additions

- apply-only command-buffer benchmarks over pre-staged payloads;
- zero-match and sparse-match typed query startup;
- scalar width sweep benchmarks for structural mutation;
- persistent frame cadence benchmarks that reuse one world and one command
  buffer across many iterations;
- allocator-backed setup versus steady-state separation.

### Near-term implementation experiments

- apply-side command dispatch tightening;
- scalar width-aware or bundle-width-aware transition helpers;
- setup-path allocator reuse probes for world and command-buffer fixtures;
- narrow codegen-shape probes on query startup and scalar mutation helpers.

### Near-term API-split research notes

- transaction-style structural batch surface;
- erased query plan surface for tools and runtime composition;
- opt-in cold component or side-store policy;
- setup/builder surface for imports, fixtures, and short-lived worlds.

## Decision rule

The ECS should not chase one universal API that is equally good at:

- hot frame iteration;
- dynamic tooling queries;
- one-shot setup-heavy import flows;
- repeated scalar structural churn; and
- memory-profile-specific runtime setup.

Where those workloads diverge materially, the right answer is likely:

- one hot default path;
- one or more explicit secondary surfaces; and
- benchmark owners that measure them separately instead of averaging them into
  one misleading number.
