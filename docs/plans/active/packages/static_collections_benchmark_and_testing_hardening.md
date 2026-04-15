# `static_collections` benchmark and testing hardening plan

Scope: reopen `static_collections` to broaden benchmark coverage, strengthen
benchmark observability, and harden hostile-runtime proof across the exported
collection families until the package can explain likely performance cliffs and
reproduce the main allocator-failure, pressure, and reduced runtime-sequence
regression classes inside the current generic package boundary.

## Inputs

- `docs/sketches/static_collections_benchmark_and_testing_review_2026-04-11.md`
- `packages/static_collections/README.md`
- `packages/static_collections/AGENTS.md`
- `packages/static_collections/benchmarks/`
- `packages/static_collections/tests/`
- `packages/static_collections/src/collections/`
- `docs/plans/completed/static_collections_followup_closed_2026-04-03.md`
- `docs/plans/active/packages/static_collections.md`
- `docs/plans/active/workspace_operations.md`

## Scope guardrails

- Keep the package generic. Do not pull archetypes, chunks, entities, ECS row
  policy, or scheduler policy into this plan.
- Keep compile-contract failures in package-local compile fixtures rather than
  inventing a new shared harness for comptime rejection.
- Keep direct tests and current `testing.model` slices as the baseline proof
  surface.
- Use `static_testing` where it materially improves runtime-sequence
  reproducibility: retained replay, reduced-failure bundles, generated bounded
  campaigns, and shared benchmark artifacts are in scope.
- Keep benchmark owners deterministic, bounded, and review-only under
  `zig build bench` unless the shared benchmark workflow explicitly opts into
  gating later.

## Reopen trigger

The active review in
`docs/sketches/static_collections_benchmark_and_testing_review_2026-04-11.md`
identified concrete package-local gaps beyond the existing packed-storage
boundary plan:

- benchmark coverage is still too narrow for the exported family set;
- benchmark reports are too timing-only to explain regressions well;
- retained replay, reduced-failure, and broader hostile-runtime proof are much
  weaker than the current `testing.model` surface suggests;
- allocator-failure and budget-pressure proof is selective rather than
  systematic.

## Current decision note

Default recommendation:

- keep the packed-storage relocation boundary work on
  `docs/plans/active/packages/static_collections.md`;
- add this separate hardening plan so benchmark and testing depth can grow
  across the wider package without muddling the narrower API decision slice;
- keep the current model-backed families as the reopen baseline and expand from
  them rather than replacing them.

Pinned design direction:

- every admitted collection benchmark owner should emit the structural metadata
  needed to explain timing, not only elapsed time;
- retained reduced failures should correspond to real collection invariants or
  reduced runtime-sequence bugs, not only inline failing test state;
- allocator-failure proof should cover representative growth and rollback paths
  across the allocation-aware families, not just one or two hand-picked types.

Rejected shortcut:

- do not treat more hot-loop timings alone as enough. The durable goal is
  attribution, replayability, and pressure-aware proof.

## Ordered SMART tasks

1. `Benchmark observability contract and semantic preflight normalization`
   Freeze the benchmark metadata contract for collection owners and ensure each
   owner proves its intended workload semantics before timing.
   Exact surfaces:
   - `packages/static_collections/benchmarks/support.zig`
   - admitted owners under `packages/static_collections/benchmarks/*.zig`
   Required observability set:
   - explicit `environment_note` plus bounded `environment_tags`;
   - family name and workload mode;
   - capacity, occupancy, or survivor count where meaningful;
   - owner-specific counters such as collision density, spill count,
     swap-remove count, or mutation count when measurable outside the timed
     path.
   Done when:
   - each admitted owner uses one shared support helper;
   - each admitted owner runs a semantic preflight or records why a separate
     preflight would be meaningless;
   - package docs pin which metadata fields are package-wide.
   Validation:
   - `zig build flat_hash_map_lookup_insert_baselines`
   - `zig build collections_hotpaths`
   - `zig build bench`
   - `zig build docs-lint`

2. `Benchmark matrix expansion across unrepresented families`
   Add the missing canonical owners for collection families and workload modes
   that currently have no direct review surface.
   Exact surfaces:
   - `packages/static_collections/benchmarks/vec_small_vec_baselines.zig`
   - `packages/static_collections/benchmarks/dense_array_baselines.zig`
   - `packages/static_collections/benchmarks/map_capacity_edge_baselines.zig`
   - `packages/static_collections/benchmarks/allocator_pressure_baselines.zig`
   - `build.zig`
   Coverage targets:
   - `Vec` growth and exact-capacity fallback;
   - `SmallVec` inline-versus-spill crossover and post-spill steady state;
   - `DenseArray` append and swap-remove churn;
   - map or set capacity-edge and collision-heavy stories beyond one baseline;
   - allocator-sensitive setup or control-plane workloads where the current
     suite measures only steady-state hot loops.
   Done when:
   - each missing family above has an admitted owner or a recorded rejection
     reason;
   - direct named steps exist for the admitted owners;
   - package docs name the owners and the interpretation of each workload.
   Validation:
   - direct named steps for the new owners
   - `zig build bench`
   - `zig build docs-lint`

3. `Allocator-failure and budget-pressure matrix`
   Add systematic partial-failure proof across the allocation-aware structures.
   Exact surfaces:
   - `packages/static_collections/src/collections/dense_array.zig`
   - `packages/static_collections/src/collections/vec.zig`
   - `packages/static_collections/src/collections/small_vec.zig`
   - `packages/static_collections/src/collections/flat_hash_map.zig`
   - `packages/static_collections/src/collections/sorted_vec_map.zig`
   - `packages/static_collections/src/collections/slot_map.zig`
   - `packages/static_collections/src/collections/sparse_set.zig`
   - new integration fixtures under `packages/static_collections/tests/integration/`
   Coverage targets:
   - failing allocator or denied growth on append, reserve, clone, or rehash;
   - rollback proof after partial progress;
   - continued usability after failure where the API promises it;
   - budget-pressure coverage beyond the current `Vec` and selective direct
     tests.
   Done when:
   - each major allocation-aware family above has at least one package-owned
     failing-allocator or budget-denial proof;
   - tests prove cleanup, accounting, and continued usability after failure.
   Validation:
   - `zig build test`
   - `zig build docs-lint`

4. `Primitive-facing replay and retained reduced failures`
   Introduce retained reproduction for real collection-runtime failures instead
   of relying solely on inline model divergence.
   Exact surfaces:
   - new replay or retained-failure fixtures under
     `packages/static_collections/tests/integration/`
   - `packages/static_collections/tests/integration/root.zig`
   Coverage targets:
   - at least one real reduced failure family such as collision-heavy map
     mutation, packed swap-remove ambiguity, spill crossover regression, or
     stale-handle reuse divergence;
   - retained replay through the shared `failure_bundle` contract;
   - package docs describing the retained failure path.
   Done when:
   - the package owns at least one committed retained runtime failure bundle or
     reduced replay input;
   - package docs state why the retained case exists and what invariant it
     defends.
   Validation:
   - `zig build test`
   - `zig build harness`
   - `zig build docs-lint`

5. `Model expansion for remaining mutation-heavy families`
   Broaden bounded runtime-sequence proof selectively into the mutable families
   that still rely mostly on direct fixtures.
   Exact surfaces:
   - `packages/static_collections/tests/integration/dense_array_model_sequences.zig`
   - `packages/static_collections/tests/integration/min_heap_model_sequences.zig`
   - `packages/static_collections/tests/integration/small_vec_model_sequences.zig`
   - `packages/static_collections/tests/integration/root.zig`
   Coverage targets:
   - packed append and swap-remove plus reuse for `DenseArray`;
   - tracked-index or update ordering for `MinHeap`;
   - spill and post-spill lifecycle for `SmallVec`.
   Done when:
   - at least one additional non-map, non-slot model target is admitted;
   - the new target covers a sequence class the current direct fixtures cannot
     express compactly.
   Validation:
   - `zig build test`
   - `zig build harness`
   - `zig build docs-lint`

6. `Fault-injection and repeated saturation suites`
   Translate hostile-runtime assumptions into bounded deterministic collection
   proof instead of vague stress intent.
   Exact surfaces:
   - new integration fixtures under `packages/static_collections/tests/integration/`
   Coverage targets:
   - repeated near-capacity growth and rollback;
   - repeated `NoSpaceLeft` and retry after recovery;
   - stale-handle misuse after reuse;
   - borrow-heavy probe and mutation mixes that mimic hostile caller behavior;
   - deterministic allocator denial standing in for unstable-memory conditions.
   Done when:
   - the package owns direct proof for repeated saturation and recovery on the
     main allocation-aware families;
   - the docs record which hostile-runtime assumptions are modeled directly and
     which remain intentionally out of scope.
   Validation:
   - `zig build test`
   - `zig build docs-lint`

7. `Docs, admission, and closure criteria`
   Keep docs truthful as the benchmark and hostile-testing surfaces broaden.
   Exact surfaces:
   - `packages/static_collections/README.md`
   - `packages/static_collections/AGENTS.md`
   - root `README.md`
   - root `AGENTS.md`
   - `docs/architecture.md`
   - this plan and the eventual completion record
   Done when:
   - every admitted benchmark owner and every first-class retained, replay, or
     model surface added by this plan is named in package docs;
   - the completion record can close against explicit benchmark-observability,
     allocator-failure, retained-replay, and model-expansion criteria.
   Validation:
   - `zig build docs-lint`

## `static_testing` adoption map

### Primary coverage targets

- retained runtime-sequence reproducers;
- broader model coverage for remaining mutation-heavy families;
- benchmark history with workload-shape metadata;
- deterministic allocator-failure and repeated-pressure proof.

### Best-fit shared surfaces

- `testing.model` for mutation-heavy runtime sequences;
- replay and `failure_bundle` for reduced runtime failures;
- generated bounded campaigns only when direct tables become too narrow;
- shared benchmark workflow for canonical artifacts.

### Keep out of scope unless a new bug class appears

- compile-contract harness extraction into `static_testing`;
- scheduler, process, or time-driven orchestration;
- ECS vocabulary or relocation policy that belongs in higher layers.

## Work order

1. Freeze benchmark observability and semantic preflight expectations.
2. Add missing benchmark owners for the unrepresented families.
3. Add allocator-failure and budget-pressure matrix coverage.
4. Introduce retained replay for at least one real collection failure family.
5. Expand model coverage into the remaining mutation-heavy families.
6. Update docs and close only after the new surfaces are admitted and
   reproducible.

## Ideal state

- `static_collections` benchmark reports explain which structure shape or
  control-plane path caused a slowdown.
- The package keeps reduced retained reproducers for real runtime failures
  instead of relying only on one-off failing test runs.
- Allocation-aware collection families have systematic hostile-memory proof,
  not only selective budget or capacity checks.
