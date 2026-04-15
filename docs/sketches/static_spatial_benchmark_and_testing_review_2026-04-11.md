# `static_spatial` benchmark and testing review

Date: 2026-04-11

Scope: audit `static_spatial` against the same stricter standard used for
`static_ecs` and `static_sync`:

1. the benchmark suite should make likely performance cliffs visible and
   explainable, including where time is going and why;
2. the testing suite should stay robust under hostile-runtime assumptions,
   including malformed geometry, allocator denial, memory pressure, retained
   replay, and reproducible reduced failures.

This is a sketch review. It records the current package posture, concrete
gaps found during inspection, and the improvement backlog needed to reopen the
package cleanly for benchmark and testing hardening.

## Review method

- Read package guidance:
  `packages/static_spatial/README.md`,
  `packages/static_spatial/AGENTS.md`,
  and `docs/plans/active/packages/static_spatial.md`.
- Read the integration tests under `packages/static_spatial/tests/integration/`.
- Read the admitted benchmark owner under `packages/static_spatial/benchmarks/`.
- Inspect benchmark and integration wiring in `build.zig`.
- Run the direct named benchmark owner `zig build bvh_query_baselines`.

## Validation notes

- The package-level integration root currently imports only BVH and
  `IncrementalBVH`-focused files.
- The shared-harness adoption that exists today is concentrated in
  `incremental_bvh_model_sequences.zig` and
  `replay_incremental_bvh_boundary_failures.zig`.
- The direct named benchmark owner exists and ran successfully on
  2026-04-11 through `zig build bvh_query_baselines`.
- The benchmark output reports elapsed time plus the shared baseline history
  record, but it does not emit the workload-shape facts needed to explain many
  regressions.

## Current testing posture

`static_spatial` is ahead of a pure direct-fixture package because it already
uses `testing.model` and retained failure bundles.

Strengths:

- integration coverage explicitly proves BVH inclusive boundary-touching
  semantics and truncation reporting across AABB, ray, sorted ray, and frustum
  queries;
- `IncrementalBVH` has direct lifecycle coverage for insert, refit, remove,
  drain, and reuse flows;
- `incremental_bvh_model_sequences.zig` uses `testing.model` for bounded
  mutation and query sequences;
- `replay_incremental_bvh_boundary_failures.zig` proves retained failure-bundle
  persistence and replay for one reduced `IncrementalBVH` failure family.

That is a real base. The main problem is not zero adoption. The problem is
that the adoption is narrow, highly `IncrementalBVH`-centric, and still weak
against hostile-memory and hostile-input assumptions.

## Testing findings

### 1. The package-level hostile-testing surface is too concentrated on `IncrementalBVH`

Evidence:

- `tests/integration/root.zig` imports BVH query-boundary and truncation tests,
  `incremental_bvh_lifecycle.zig`,
  `incremental_bvh_model_sequences.zig`,
  and `replay_incremental_bvh_boundary_failures.zig`.
- There is no comparable package-level integration ownership for
  `UniformGrid`, `UniformGrid3D`, `LooseGrid`, or `SparseGrid`.
- The bounded grid family still shows up in package docs and examples, but the
  integration surface does not treat it as a first-class hostile-input or
  pressure target.

Impact:

- the package-level proof is strong on one dynamic structure and one build-once
  structure family;
- the rest of the exported spatial index surface still leans on inline tests,
  examples, or assumptions rather than package-owned adversarial campaigns.

### 2. Shared-harness usage exists, but it is narrow and misses fuzz-style geometry exploration

Evidence:

- the only `static_testing` integration users are the `IncrementalBVH` model
  sequence target and the retained boundary-failure replay target;
- there is no package-owned fuzz or generated malformed-geometry campaign;
- there is no retained corpus for degenerate boxes, NaN or infinity
  coordinates, extreme overlap sets, or adversarial spatial distributions.

Impact:

- the package proves one reduced retained failure and one bounded action-table
  model;
- it does not yet exercise the broader geometry families likely to trigger
  spatial indexing edge cases.

### 3. Hostile allocator and pressure assumptions are barely exercised

Evidence:

- the integration tests overwhelmingly use `testing.allocator` or direct
  in-process allocators;
- the review did not find a failing-allocator matrix or low-budget matrix for
  `BVH.build()` or `IncrementalBVH.insert()` / growth paths;
- there is no package-owned proof that partial build or partial mutation
  failure leaves the structure reusable and cleanly deinitialized.

Impact:

- the package assumes allocator stability much more than your stated review bar
  allows;
- partial-failure cleanup bugs in build or dynamic mutation paths could still
  exist without a retained reproducer.

### 4. Retained failure posture is real, but still too narrow and too ephemeral

Evidence:

- `replay_incremental_bvh_boundary_failures.zig` uses the shared
  `failure_bundle` contract and `testing.tmpDir()` to prove bundle persistence,
  `actions.zon`, and replay mechanics;
- the package does not appear to ship a broader in-repo retained failure corpus
  for multiple bug families;
- the retained story is tied to one boundary-touching `IncrementalBVH`
  scenario rather than a broader geometry or allocator regression set.

Impact:

- retained reproduction mechanics are validated;
- repository memory for future reduced failures is still thin.

### 5. The current suite does not model hostile geometry families aggressively enough

Evidence:

- the direct BVH tests use hand-authored items and query shapes;
- the benchmark geometry is one deterministic 4x4x4-style layout with one
  fixed query set;
- the review did not find package-owned campaigns for:
  - heavy overlap or near-identical boxes;
  - degenerate zero-volume or near-zero-volume boxes;
  - coordinates large enough to stress float precision assumptions;
  - adversarial insertion orders or clustered update families for
    `IncrementalBVH`;
  - sparse-grid churn or grid cell explosion near configuration limits.

Impact:

- the current tests prove intended semantics on representative shapes;
- they do not yet cover enough adversarial distributions to justify a
  hostile-runtime claim.

## Benchmark posture

`static_spatial` currently has one admitted benchmark owner:

- `benchmarks/bvh_query_baselines.zig`

That owner is deterministic, directly runnable, and has semantic preflight.
The problem is not truthlessness. The problem is that one owner is nowhere near
enough for a package with multiple index families and both build-once and
dynamic mutation-heavy structures.

## Benchmark findings

### 6. Benchmark coverage is far too narrow for the package surface

Covered today:

- one deterministic non-incremental BVH geometry set;
- build cost;
- `queryAABB`, `queryRay`, `queryRaySorted`, and `queryFrustum`.

Missing:

- `IncrementalBVH` insert, remove, refit, and mixed update/query churn;
- bounded grid query workloads for `UniformGrid`, `UniformGrid3D`, and
  `LooseGrid`;
- `SparseGrid` mutation and query workloads;
- config sweeps over `max_leaf_items`, overlap density, query selectivity, and
  geometry count;
- truncation-heavy query cases and worst-case overlap scans;
- cases that separate tree-build cost from query cost under different spatial
  distributions.

Impact:

- most exported spatial structures have no canonical performance owner;
- likely performance hangups in update-heavy or overlap-heavy workloads remain
  invisible.

### 7. Benchmark observability is too timing-only to explain regressions

Evidence:

- `bvh_query_baselines.zig` prints elapsed timings and baseline comparisons;
- `support.zig` provides only `environment_note`, not bounded environment tags
  or package-specific shape metadata;
- the benchmark report does not emit:
  - item count;
  - node count or leaf count;
  - max leaf size;
  - query hit count or truncation count;
  - overlap density or average hits per query;
  - tree depth or distribution shape notes.

Impact:

- a regression can be detected, but not explained well;
- compatibility filtering and cross-host interpretation are weaker than they
  should be.

### 8. The current benchmark matrix is too friendly to expose likely worst cases

Evidence:

- the benchmark geometry is one compact deterministic layout;
- the query set is one fixed AABB, one fixed ray, one fixed sorted ray, and
  one fixed frustum;
- there is no admitted owner for overlap explosion, clustered distributions,
  or low-selectivity versus high-selectivity query contrasts.

Impact:

- the benchmark suite is good at checking one representative happy-path shape;
- it is not built to reveal all likely hotspots or cliff edges.

### 9. Direct benchmark discoverability is already good and should be preserved

Evidence:

- `zig build -h` exposes `bvh_query_baselines`;
- the owner ran successfully through the direct named step on 2026-04-11.

Impact:

- unlike `static_sync`, discoverability is not the main issue here;
- the durable improvement should preserve direct named-step ergonomics while
  broadening coverage and observability.

## Overall assessment

`static_spatial` has a credible first shared-harness foothold, but it is still
closer to a focused proof-of-correctness suite than to the hostile-runtime and
performance-inspection suite you asked for.

Short version:

- tests: good on BVH semantics and `IncrementalBVH` lifecycle, weak on grids,
  sparse-grid, allocator failure, geometry fuzzing, and broader retained
  adversarial proof;
- benchmarks: truthful and directly runnable, but dramatically too narrow and
  too timing-only for full performance diagnosis.

## Recommended improvement order

1. Freeze a package-wide benchmark observability contract.
   Priority:
   - item, node, and leaf counts;
   - query hit and truncation counts;
   - environment tags and workload-shape metadata.
2. Add benchmark owners for `IncrementalBVH`, the bounded grid family, and at
   least one overlap-heavy or clustered worst-case distribution.
3. Add allocator-failure and reduced-memory proof for BVH build and
   `IncrementalBVH` mutation.
4. Expand package-level integration ownership beyond BVH and `IncrementalBVH`.
   Priority:
   - bounded grids;
   - `SparseGrid`;
   - hostile geometry families.
5. Add generated geometry replay or fuzz campaigns where hand-authored fixtures
   are too narrow.
6. Broaden retained failure coverage so the package keeps reduced reproducers
   for more than one geometry bug family.

## Bottom line

`static_spatial` does not need a foundational shift away from direct tests. It
does need a real reopen for benchmark breadth and observability, allocator and
hostile-geometry fault injection, and broader package-level ownership of the
non-BVH spatial structures.
