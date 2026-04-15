# `static_spatial` active plan

Scope: spatial indexing, BVH, and uniform-grid structures.

## Review focus

- `static_spatial` now has a package `tests/` directory with lifecycle-focused
  `IncrementalBVH` integration coverage plus a bounded deterministic
  action-table harness for mutation/query sequences, plus a retained
  replay/failure roundtrip for inclusive boundary-touching query semantics.
- The package is a good fit for `testing.model`, retained replay/failure
  bundles, and stable build/query/update benchmarks.
- Review work should focus on insert/remove/query state transitions,
  degenerates, overlap boundaries, and keeping geometry helpers separate from
  indexing structures.
- The temp tech-debt sweep found one concrete contract issue, now resolved:
  `IncrementalBVH` queries report total hit count like `BVH` while still
  writing up to the output buffer length.

## Current state

- Source modules still carry inline tests across BVH, incremental BVH, grids,
  morton helpers, and primitives.
- The package now also has `tests/integration/` coverage for
  `IncrementalBVH` insert/query/refit/remove/reuse lifecycle flows and a
  bounded deterministic sequence slice that exercises insert/query
  membership, refit movement, removal, reinsertion after drain, and stable
  empty behavior after draining.
- Examples still cover BVH queries, incremental insert/remove/refit, and
  uniform-grid flows.
- The package now also has a retained replay/failure roundtrip for
  `IncrementalBVH` boundary-touching query semantics, and further
  `static_testing` adoption is still open for replay/failure follow-on work if
  the package grows more retained failure needs.
- The first package-owned deterministic proof for non-incremental `BVH`
  inclusive boundary-touching query semantics now exists in the integration
  surface, so the next deterministic geometry slice can stay focused on the
  remaining named gaps instead of reopening the broad-phase boundary story.
- `tests/integration/bvh_query_aabb_truncation.zig` now proves that
  non-incremental `BVH` still reports the total hit count when `queryAABB`
  truncates the output buffer.
- `tests/integration/bvh_query_ray_sorted_truncation.zig` now proves that
  non-incremental `BVH` still reports the total hit count when
  `queryRaySorted` truncates the output buffer.
- `tests/integration/bvh_query_frustum_truncation.zig` now proves that
  non-incremental `BVH` still reports the total hit count when `queryFrustum`
  truncates the output buffer.
- `tests/integration/bvh_query_ray_truncation.zig` now proves that
  non-incremental `BVH` still reports the total hit count when `queryRay`
  truncates the output buffer.
- `benchmarks/bvh_query_baselines.zig` now owns the first admitted
  non-incremental `BVH` benchmark surface, covering build time plus the
  canonical `queryAABB`, `queryRay`, `queryRaySorted`, and `queryFrustum`
  workloads under `zig build bench`.
- `IncrementalBVH` query semantics now match `BVH` for total-hit reporting,
  with explicit truncation coverage in lifecycle tests, model/replay slices,
  and the package example.
- The ECS / DoD audit found one remaining production-grade contract mismatch in
  the bounded grid family: `UniformGrid`, `UniformGrid3D`, and `LooseGrid`
  currently return only the number written from `queryAABB`, while `BVH` and
  `IncrementalBVH` return total hits under truncation.

## Current decision note

Default recommendation: accept alignment of the bounded grid family to the BVH
total-hit truncation contract while preserving existing duplicate behavior.

Pinned contract meaning:

- "total hit count" means the total number of stored matches the grid would
  enumerate under its current semantics;
- it does not deduplicate values inserted into multiple cells;
- it does not collapse repeated identical values already stored in one or more
  cells;
- truncation detection remains `returned_count > out.len`.

Rejected alternative:

- deduplicating logical items as part of the contract-alignment work.
  Current recommendation: reject.
  Reason:
  - deduplication would change the grid-family data contract, not just its
    truncation-reporting contract;
  - that would be a silent semantic rewrite rather than a truthful alignment to
    the BVH-style "total hits under truncation" rule.

## Approval status

Approved direction for the current queue:

- approve task 5 for implementation exactly as written in the pinned
  duplicate-preserving contract above;
- keep the rest of the active plan as proof-surface and workload-ownership
  guidance unless a new bug class reopens it.

## Ordered SMART tasks

1. `Naming and boundary review`
   Record how static versus dynamic spatial structures, geometry helpers, and
   indexing structures are split across modules and whether any exported names
   or doc comments need tightening.
   Outcome:
   - keep `BVH`, `UniformGrid`, `UniformGrid3D`, and `LooseGrid` as the
     bounded/build-once family;
   - keep `SparseGrid`, `SparseGrid3D`, and `IncrementalBVH` as the explicit
     dynamic family whose mutation paths may allocate;
   - keep the current root names and package-root docs: the bounded versus
     dynamic split is already explicit enough for downstream users and does not
     need alias churn today.
   Done when the plan lists the reviewed modules and any required naming or
   doc-comment follow-up.
2. `Deterministic geometry proof gaps`
   Add or tighten retained deterministic coverage for the remaining named
   insert, remove, refit, overlap, degeneracy, and query-boundary scenarios
   where direct fixtures are currently weak.
   Done when each named scenario is either covered under `zig build test` or
   ruled out in the plan with a reason.
   Current smallest bounded slice: record the concrete `static_spatial`
   workload ownership split in this plan, since the direct non-incremental
   `BVH` query-boundary contract is now fully covered under `zig build test`
   and the remaining work is doc-level fit review under `zig build docs-lint`.
3. `Shared-surface fit review`
   Record which mutation-sequence or generated-geometry workloads should stay
   on direct tests and which should move onto `testing.model`,
   `testing.fuzz_runner`, replay artifacts, or failure bundles.
   Outcome:
   - direct integration owns `incremental_bvh_lifecycle.zig` for lifecycle
     and truncation contracts, plus the non-incremental `BVH` boundary /
     truncation proofs in `bvh_boundary_touching_queries.zig`,
     `bvh_query_aabb_truncation.zig`, `bvh_query_ray_sorted_truncation.zig`,
     `bvh_query_frustum_truncation.zig`, and `bvh_query_ray_truncation.zig`.
   - `testing.model` owns `incremental_bvh_model_sequences.zig` for
     mutation-heavy structural sequences.
   - replay/failure artifacts own `replay_incremental_bvh_boundary_failures.zig`
     for retained boundary-touching failures.
   - non-incremental `BVH` generated-geometry or retained-failure expansion is
     deferred unless a concrete reduced failure family appears.
   Done when each candidate workload has an assigned proof surface.
4. `Benchmark admission decision`
    Decide whether build, update, and query benchmarks are needed now for the
    major spatial structures, and name the exact workloads if the answer is yes.
    Outcome:
    - `benchmarks/bvh_query_baselines.zig` owns the first admitted
      non-incremental `BVH` benchmark surface under `zig build bench`.
    - The admitted workload set is build time plus the canonical query
      workloads (`queryAABB`, `queryRay`, `queryRaySorted`, and `queryFrustum`)
      on one deterministic geometry set.
    - The next benchmark follow-on is `IncrementalBVH` build/query comparison
      only if a concrete regression signal or comparison need appears.
    Done when the plan records the benchmark owner surface and follow-on
    trigger.
5. `Bounded-grid query contract alignment`
   Align `UniformGrid`, `UniformGrid3D`, and `LooseGrid` with the `BVH`
   total-hit truncation contract so downstream spatial adapters can treat the
   bounded index families consistently.
   Outcome:
   - `queryAABB` on the bounded grid family writes up to `out.len` results and
     returns the total hit count under truncation, matching `BVH` and
     `IncrementalBVH`;
   - "total hit count" is pinned to mean total stored matches under the
     existing grid semantics, including duplicates caused by multi-cell storage
     or repeated cell occupancy, not deduplicated logical items;
   - package docs and examples describe truncation detection consistently
     across the bounded index families;
   - direct proof covers truncation on every bounded grid query surface.
   Current smallest bounded slice:
   - rewrite the bounded-grid docs to name the total-hit contract explicitly
     using the pinned duplicate-preserving meaning above;
   - implement the total-hit return path in `UniformGrid`, `UniformGrid3D`, and
     `LooseGrid`;
   - add or tighten matching direct proof under `zig build test`, including one
     duplicate-preservation case for the grid family.
   Done when every bounded grid query surface reports total hits, matching
   package docs and direct proof coverage.

## Testing cleanup focus

- Stop treating example scenes as the canonical proof for query correctness.
- Keep any generated geometry workloads deterministic and retained rather than
  relying on untracked scenario churn.

## `static_testing` adoption plan

### Primary coverage targets

- Insert/remove/query state transitions and handle validity.
- Degenerate and overlap edge cases for grids and BVH structures.
- Stable build/query/update benchmark artifacts if the package later needs
  them for stable performance regression tracking.

### Best-fit `static_testing` surfaces

- `testing.model` for mutation-heavy structural sequences.
- `testing.fuzz_runner`, replay artifacts, and `testing.failure_bundle` for
  deterministic geometry/input families and retained failures.
- `bench.workflow`, `bench.baseline`, and `bench.history` for spatial
  performance review artifacts.

### Keep out of scope

- `testing.process_driver` and broad process-boundary harnessing are not
  current fits.
- `testing.sim` remains secondary unless a downstream subsystem adds time or
  scheduler-driven spatial behavior.

## Work order

1. Map the most failure-prone mutation/query flows onto explicit invariants
   now that the `IncrementalBVH` truncation contract is explicit.
2. Add replayable reduced geometry workloads where they beat simple fixtures.
3. Normalize build/query/update benchmarks onto the shared workflow if the
   package later needs stable performance regression tracking.

## Ideal state

- Structural regressions replay through bounded retained artifacts.
- Mutation-heavy spatial behavior uses shared model/replay helpers instead of
  bespoke harness churn.
- Performance review uses stable artifacts rather than manual workload timing
  when it becomes necessary.
