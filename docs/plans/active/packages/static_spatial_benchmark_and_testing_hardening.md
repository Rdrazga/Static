# `static_spatial` benchmark and testing hardening plan

Scope: reopen `static_spatial` to broaden package-owned benchmark coverage,
improve benchmark observability, and harden hostile-runtime proof across the
spatial index families until the package can explain likely performance cliffs
and reproduce the main malformed-geometry, partial-allocation-failure, and
pressure-driven regression classes inside the current package boundary.

## Inputs

- `docs/sketches/static_spatial_benchmark_and_testing_review_2026-04-11.md`
- `packages/static_spatial/README.md`
- `packages/static_spatial/AGENTS.md`
- `packages/static_spatial/benchmarks/`
- `packages/static_spatial/tests/`
- `packages/static_spatial/src/spatial/`
- `docs/plans/active/packages/static_spatial.md`
- `docs/plans/active/workspace_operations.md`

## Scope guardrails

- Keep the package boundary on geometry primitives and spatial indexing
  structures. Do not pull ECS ownership, scheduler policy, renderer policy, or
  transport policy into this plan.
- Keep direct integration tests as the first proof surface for small explicit
  geometric contracts.
- Use `static_testing` where it materially improves reproducibility:
  `testing.model`, replay, retained failure bundles, generated deterministic
  geometry campaigns, and benchmark workflow artifacts are in scope.
- Keep benchmark owners deterministic, bounded, and review-only under
  `zig build bench` unless the shared benchmark workflow explicitly opts into
  gating later.
- Treat hostile-host assumptions through deterministic geometry generation,
  failing allocators, reduced-memory budgets where possible, retained replay,
  and bounded worst-case spatial distributions. Do not broaden into flaky
  wall-clock stress.

## Reopen trigger

The active review in
`docs/sketches/static_spatial_benchmark_and_testing_review_2026-04-11.md`
identified concrete package-local gaps beyond the already-open bounded-grid
contract plan:

- benchmark coverage is limited to one BVH owner and misses dynamic or
  non-BVH structures;
- benchmark reports are too timing-only to explain likely regressions;
- package-level hostile-testing ownership is too concentrated on BVH and
  `IncrementalBVH`;
- allocator-failure, malformed-geometry, and retained adversarial proof are
  too narrow for the current package surface.

## Current decision note

Default recommendation:

- keep the bounded-grid total-hit contract work on
  `docs/plans/active/packages/static_spatial.md`;
- add this separate hardening plan so benchmark and hostile-testing depth can
  grow without muddling the narrower API-alignment slice;
- keep the current BVH and `IncrementalBVH` surfaces as the reopen baseline
  rather than replacing them.

Pinned design direction:

- every admitted spatial benchmark owner should report enough shape metadata to
  explain timing, not only elapsed time;
- dynamic and bounded spatial structures both need package-level hostile-proof;
- retained failures should cover real geometric or allocator regression
  families, not only one boundary-touching story.

Rejected shortcut:

- do not treat one larger geometry set or one more direct query test as enough.
  The durable goal is workload attribution and reproducible adversarial proof.

## Ordered SMART tasks

1. `Benchmark observability contract`
   Record the package-wide benchmark metadata that every admitted spatial owner
   should emit when relevant, and route it outside the timed path.
   Exact surfaces:
   - `packages/static_spatial/benchmarks/support.zig`
   - admitted owners under `packages/static_spatial/benchmarks/*.zig`
   Required observability set:
   - item count;
   - node count and leaf count when the structure has them;
   - query hit count and truncation count when the workload is query-driven;
   - workload family and geometry distribution note;
   - explicit `environment_note` plus bounded `environment_tags`;
   - owner-specific counters such as overlap ratio, `max_leaf_items`, or
     mutation count when those facts can be measured without polluting timing.
   Done when:
   - the support helper pins the package-wide required fields;
   - the existing admitted BVH owner emits its relevant metadata;
   - the docs say which fields are package-wide versus owner-specific.
   Validation:
   - `zig build bvh_query_baselines`
   - `zig build bench`
   - `zig build docs-lint`

2. `Benchmark matrix expansion across spatial families`
   Add the missing canonical benchmark owners for dynamic and non-BVH
   structures plus at least one adversarial geometry family.
   Exact surfaces:
   - `packages/static_spatial/benchmarks/incremental_bvh_mutation_baselines.zig`
   - `packages/static_spatial/benchmarks/grid_query_baselines.zig`
   - `packages/static_spatial/benchmarks/sparse_grid_baselines.zig`
   - `packages/static_spatial/benchmarks/bvh_distribution_sweeps.zig`
   - `build.zig`
   Coverage targets:
   - `IncrementalBVH` insert, refit, remove, and mixed query churn;
   - bounded grid query workloads for `UniformGrid`, `UniformGrid3D`, and
     `LooseGrid`;
   - `SparseGrid` mutation and query workloads;
   - at least one overlap-heavy, clustered, or low-selectivity distribution
     family that stresses a likely worst case;
   - config sweeps over geometry count or `max_leaf_items` where meaningful.
   Done when:
   - each named family has an admitted owner or a recorded rejection reason;
   - direct named benchmark steps exist for the admitted owners;
   - package docs name the owners and how to interpret them.
   Validation:
   - direct named steps for the new owners
   - `zig build bench`
   - `zig build docs-lint`

3. `Malformed-geometry replay and generated campaign hardening`
   Move beyond hand-authored geometry-only fixtures by adding deterministic
   generated geometry campaigns and retained reduced failures for real spatial
   bug families.
   Exact surfaces:
   - `packages/static_spatial/tests/integration/replay_incremental_bvh_boundary_failures.zig`
   - `packages/static_spatial/tests/integration/spatial_geometry_replay_runtime.zig`
   - `packages/static_spatial/tests/integration/spatial_geometry_fuzz_runtime.zig`
   - `packages/static_spatial/tests/integration/root.zig`
   Coverage targets:
   - degenerate or near-degenerate boxes;
   - clustered overlap sets and boundary-touching layouts;
   - large-coordinate or precision-sensitive layouts within the package's valid
     float contract;
   - reduced retained reproducers for any discovered divergence.
   Done when:
   - the package owns at least one new retained geometry-failure family beyond
     the existing `IncrementalBVH` boundary story;
   - generated geometry coverage exists on a bounded deterministic path;
   - package docs describe the retained replay surface.
   Validation:
   - `zig build test`
   - `zig build harness`
   - `zig build docs-lint`

4. `Allocator-failure and partial-progress proof`
   Add failing-allocator and partial-progress coverage for build and dynamic
   mutation paths.
   Exact surfaces:
   - `packages/static_spatial/src/spatial/bvh.zig`
   - `packages/static_spatial/src/spatial/incremental_bvh.zig`
   - new integration fixtures under `packages/static_spatial/tests/integration/`
   Coverage targets:
   - `BVH.build()` failure after partial node or storage progress;
   - `IncrementalBVH.insert()` or growth failure after partial work;
   - post-failure reuse and deinit proof;
   - lower-memory or denial stories that mimic hostile-memory assumptions in a
     deterministic bounded way.
   Done when:
   - both build-once and dynamic mutation paths have at least one package-owned
     partial-failure proof;
   - the tests show cleanup and continued usability after failure where the API
     promises it.
   Validation:
   - `zig build test`
   - `zig build docs-lint`

5. `Grid and sparse-grid integration ownership`
   Give the non-BVH spatial families first-class package-level hostile-proof
   instead of leaving them mostly on inline tests and docs.
   Exact surfaces:
   - `packages/static_spatial/tests/integration/uniform_grid_runtime.zig`
   - `packages/static_spatial/tests/integration/uniform_grid_3d_runtime.zig`
   - `packages/static_spatial/tests/integration/loose_grid_runtime.zig`
   - `packages/static_spatial/tests/integration/sparse_grid_runtime.zig`
   - `packages/static_spatial/tests/integration/root.zig`
   Coverage targets:
   - total-hit truncation reporting for the bounded grids;
   - duplicate-preserving semantics where documented;
   - insertion, removal, and query churn for `SparseGrid`;
   - boundary-touching, overlap, and empty-result paths.
   Done when:
   - each exported non-BVH index family has package-level integration ownership;
   - the package docs no longer rely on examples or inline tests alone to
     represent those structures.
   Validation:
   - `zig build test`
   - `zig build docs-lint`

6. `Model expansion for dynamic mutation families`
   Broaden sequence-sensitive proof beyond the current `IncrementalBVH` action
   table where bounded mutation exploration can still find bugs direct tests may
   miss.
   Exact surfaces:
   - `packages/static_spatial/tests/integration/incremental_bvh_model_sequences.zig`
   - `packages/static_spatial/tests/integration/sparse_grid_model_sequences.zig`
   - `packages/static_spatial/tests/integration/root.zig`
   Coverage targets:
   - `SparseGrid` insert, remove, query, and reuse cycles;
   - an expanded `IncrementalBVH` sequence set that covers more than the current
     three short scenarios when reduced cases justify it;
   - retained replay for model-found divergences.
   Done when:
   - the package owns at least one additional model target beyond
     `IncrementalBVH`;
   - retained replay exists for reduced model failures when found.
   Validation:
   - `zig build test`
   - `zig build harness`
   - `zig build docs-lint`

7. `Docs, admission, and closure criteria`
   Keep docs truthful as benchmark and hostile-testing surfaces broaden.
   Exact surfaces:
   - `packages/static_spatial/README.md`
   - `packages/static_spatial/AGENTS.md`
   - root `README.md`
   - root `AGENTS.md`
   - `docs/architecture.md`
   - this plan and the eventual completion record
   Done when:
   - every admitted benchmark owner and every first-class testing surface added
     by this plan is named in package docs;
   - the completion record can close against explicit observability,
     allocator-failure, geometry-replay, and family-coverage criteria.
   Validation:
   - `zig build docs-lint`

## `static_testing` adoption map

### Primary coverage targets

- retained geometry and partial-failure reproducers;
- bounded mutation-sequence exploration for dynamic structures;
- benchmark history with workload-shape metadata;
- deterministic generated geometry campaigns.

### Best-fit shared surfaces

- `testing.model` for dynamic mutation sequences;
- replay and `failure_bundle` for reduced geometry failures;
- generated bounded campaigns for geometry families;
- shared benchmark workflow for baseline and history artifacts.

### Keep out of scope unless a new bug class appears

- broad process-boundary orchestration;
- scheduler or time-driven simulation;
- downstream ECS ownership or rendering policy.

## Work order

1. Freeze benchmark observability so new owners share one reporting contract.
2. Add the missing benchmark owners across dynamic and non-BVH structures.
3. Add allocator-failure and malformed-geometry retained proof.
4. Expand package-level integration ownership to the grid and sparse-grid
   families.
5. Broaden model coverage where dynamic mutation still benefits from bounded
   sequence exploration.
6. Update docs and close only after the surfaces are admitted and reproducible.

## Ideal state

- `static_spatial` benchmark output explains not only that a case slowed down,
  but what spatial shape changed.
- The package-level hostile suite covers more than BVH and `IncrementalBVH`.
- Reduced geometry and allocator regressions replay through retained shared
  artifacts instead of disappearing after one failing run.
