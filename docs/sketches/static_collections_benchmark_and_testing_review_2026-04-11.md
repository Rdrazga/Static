# `static_collections` benchmark and testing review

Date: 2026-04-11

Scope: audit `static_collections` against the same stricter standard used for
`static_ecs` and `static_sync`:

1. the benchmark suite should expose where collection performance is spent and
   which data shapes or control-plane choices are causing regressions;
2. the testing suite should stay robust under hostile-runtime assumptions,
   including allocator denial, memory pressure, malformed use, retained
   replay, and reproducible reduced failures.

This is a sketch review. It records the current package posture, concrete
gaps found during inspection, and the improvement backlog needed to reopen the
package cleanly for benchmark and testing hardening.

## Review method

- Read package guidance:
  `packages/static_collections/README.md`,
  `packages/static_collections/AGENTS.md`,
  `docs/plans/active/packages/static_collections.md`,
  and `docs/plans/completed/static_collections_followup_closed_2026-04-03.md`.
- Read the integration tests under
  `packages/static_collections/tests/integration/`.
- Read the admitted benchmark owners under
  `packages/static_collections/benchmarks/`.
- Inspect root wiring in `build.zig`.
- Run the direct benchmark owners
  `zig build flat_hash_map_lookup_insert_baselines` and
  `zig build collections_hotpaths`.

## Validation notes

- The package already uses `testing.model` broadly across several runtime
  sequence files.
- The review did not find package-owned replay, fuzz, failure-bundle,
  simulator, swarm, or temporal integration surfaces.
- The direct named benchmark owners exist and ran successfully on 2026-04-11.
- The `collections_hotpaths` run on 2026-04-11 reported one failed latest
  history comparison on `sparse_set_insert_remove` p95 while still lacking the
  workload-shape metadata needed to explain the signal cleanly.

## Current testing posture

Compared with `static_spatial`, `static_collections` already has broad
`testing.model` adoption.

Strengths:

- direct integration coverage spans most exported mutable families;
- `testing.model` is already used for `FlatHashMap`, `IndexPool`, `SlotMap`,
  `SortedVecMap`, `SparseSet`, and `Vec`;
- compile-contract failures are explicitly owned through package-level
  fixtures;
- several direct tests already cover `NoSpaceLeft`, invalid-input, stale-handle
  rejection, and budget accounting.

That is a strong deterministic base. The main weakness is different: the
package leans heavily on direct fixtures and bounded model tables, but it still
lacks retained adversarial exploration, replayable reduced failures, and a
systematic allocator-failure matrix.

## Testing findings

### 1. `testing.model` coverage is broad, but the package barely uses the rest of the hostile-testing toolbox

Evidence:

- the integration review found multiple `testing.model` targets;
- the same review did not find package-owned replay, fuzz, retained
  failure-bundle, simulation, swarm, or temporal surfaces;
- the package-owned hostile-runtime story is still mostly direct tests plus
  deterministic model action tables.

Impact:

- sequence-sensitive logic is covered better than average;
- retained reduced failures and broader adversarial input exploration are still
  largely absent.

### 2. Allocator-failure and memory-pressure coverage is uneven and too shallow for the package surface

Evidence:

- budget-aware proof exists for `Vec`, `DenseArray`, and `SmallVec`;
- direct capacity or `NoSpaceLeft` proof exists for several bounded families;
- the review did not find a systematic failing-allocator matrix across the
  allocation-aware surfaces;
- there is no package-owned matrix for partial-growth failure on
  `FlatHashMap`, `SortedVecMap`, `SlotMap`, `DenseArray`, or `SparseSet`
  beyond selective direct cases.

Impact:

- the package proves some budget and capacity contracts well;
- it still assumes allocator stability on many growth, clone, and rehash paths
  that matter under hostile-memory assumptions.

### 3. Retained failure posture is almost nonexistent

Evidence:

- unlike `static_spatial` and `static_sync`, the integration review did not
  find package-owned retained failure bundles or replay inputs;
- failures discovered by the existing model surfaces would not currently leave
  behind a package-owned reduced corpus.

Impact:

- the package can detect divergence during a test run;
- it is weak on preserving reduced reproducers for future regression defense.

### 4. Some important mutable families still rely only on direct fixtures

Evidence:

- the model-backed families are strong, but the review did not find comparable
  `testing.model` or retained-sequence ownership for `DenseArray`,
  `SmallVec`, `BitSet`, `FixedVec`, or `MinHeap`;
- those families still matter for ECS-adjacent packed storage, spill
  boundaries, boundary math, and tracked-ordering correctness.

Impact:

- the package is strong where it already chose model ownership;
- the remaining mutable families are still closer to direct contract fixtures
  than to bounded adversarial sequence proof.

### 5. The package does not yet model hostile allocator, OS, or runtime assumptions explicitly enough

Evidence:

- there is no retained reduced failure flow for allocator instability;
- there is no package-owned misuse or fault-injection matrix that repeatedly
  forces near-capacity growth, rollback, clone failure, or borrow-heavy
  mutation under failing allocators;
- no package tests translate hostile-host assumptions into deterministic
  bounded substitutes such as failing allocators, budget denial, repeated
  saturation, or replayable reduced mutation traces beyond a few local cases.

Impact:

- the package behaves like a well-tested deterministic library;
- it does not yet meet the bar of assuming memory and runtime instability by
  default.

## Benchmark posture

`static_collections` currently has two admitted benchmark owners:

- `benchmarks/flat_hash_map_lookup_insert_baselines.zig`
- `benchmarks/collections_hotpaths.zig`

This is a better starting point than `static_spatial`, but the suite still
lags well behind the package breadth.

## Benchmark findings

### 6. Benchmark coverage is still too narrow for the exported collection families

Covered today:

- `FlatHashMap` lookup-hit and insert/remove churn;
- one hot-path owner for `IndexPool`, `MinHeap`, `SlotMap`, `SparseSet`, and
  `SortedVecMap`.

Missing:

- `Vec`, `SmallVec`, `DenseArray`, `BitSet`, and `FixedVec`;
- allocator-sensitive growth and exact-capacity fallback costs;
- inline-versus-spill crossover for `SmallVec`;
- swap-remove relocation churn for `DenseArray`;
- collision-shape and load-factor sweeps broader than one map family;
- clone, clear, reset, iterator scan, and removal-heavy workloads;
- budget and failing-allocator control-plane review.

Impact:

- the suite covers a few hot spots;
- a large portion of the package can still regress with no canonical owner.

### 7. Benchmark observability is too weak to explain benchmark history signals

Evidence:

- the support helper writes timing plus baseline history but not bounded
  environment tags or package-specific shape metadata;
- `collections_hotpaths.zig` does not run a semantic preflight like the
  `FlatHashMap` owner does;
- the reports do not emit:
  - capacity and occupancy;
  - load factor or collision density;
  - mutation count and survivor count;
  - swap-remove count, spill count, or comparator-path counts;
  - allocator or budget mode.

Impact:

- current owners can flag regressions;
- they cannot explain where the extra time is coming from well enough.

### 8. Existing benchmarks are biased toward friendly, already-initialized hot loops

Evidence:

- `collections_hotpaths` measures steady-state mutation loops on prefilled
  structures;
- `flat_hash_map_lookup_insert_baselines` focuses on one seeded lookup hot set
  and one bounded churn loop;
- there are no admitted cases for near-capacity growth, repeated reset or
  clear, partial-growth rollback, or allocator-sensitive setup cost.

Impact:

- the suite is useful for steady-state hot-path review;
- it is weak at surfacing control-plane or capacity-cliff costs.

### 9. Direct benchmark discoverability is already good and should stay that way

Evidence:

- `zig build -h` exposes
  `flat_hash_map_lookup_insert_baselines` and `collections_hotpaths`;
- both owners ran through direct named steps on 2026-04-11.

Impact:

- unlike `static_sync`, benchmark discoverability is not the bottleneck;
- the reopen should preserve this while broadening owner count and metadata.

## Overall assessment

`static_collections` has a stronger deterministic runtime-sequence suite than
either `static_spatial` or the original `static_ecs` review. It is notably
ahead on `testing.model` adoption.

Its weaknesses are different:

- hostile-runtime proof is still too dependent on direct fixtures and too thin
  on retained replay or reduced-failure workflows;
- allocator-failure coverage is selective instead of systematic;
- benchmark coverage and observability are too small for a package with this
  many exported families.

Short version:

- tests: broad and solid on direct contracts and several bounded model
  sequences, but weak on retained adversarial proof, replay, fuzz, and
  systematic failing-allocator coverage;
- benchmarks: directly runnable and useful, but too timing-only and too narrow
  to diagnose all likely performance hangups.

## Recommended improvement order

1. Freeze a benchmark observability contract shared by all collection owners.
   Priority:
   - capacity and occupancy;
   - mutation and survivor counts;
   - collision, spill, or relocation counters where relevant;
   - environment tags.
2. Add missing benchmark owners for the unrepresented collection families and
   allocator-sensitive control-plane stories.
3. Add a systematic failing-allocator and budget-pressure matrix across the
   allocation-aware structures.
4. Introduce retained replay or reduced-failure ownership for at least one real
   collection bug family instead of relying only on inline model failures.
5. Expand `testing.model` selectively into the remaining mutation-heavy
   families where direct fixtures are weakest.
6. Keep compile-contract fixtures local, but pair them with stronger runtime
   hostile-proof for the allocation-aware families.

## Bottom line

`static_collections` does not need a first-wave shared-harness adoption push.
It already uses `testing.model` well. It does need a real reopen for replay and
retained adversarial proof, systematic allocator-failure coverage, and a much
broader benchmark matrix with enough metadata to explain regressions rather
than merely detecting them.
