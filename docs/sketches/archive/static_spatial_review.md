# Sketch: `static_spatial` Package Review

Date: 2026-03-06 (America/Denver)  
Status: First review pass completed.

## Scope

Review `packages/static_spatial/` for:

- adherence to `AGENTS.md`;
- overlap with Zig standard facilities and whether the package adds enough value;
- correctness and completeness at file and package scope;
- duplicate, dead, or misplaced code;
- example and test coverage; and
- practical refactor paths.

## Package Inventory

- Source files: 8 spatial modules plus `root.zig`.
- Examples: 1 (`spatial_basic`).
- Benchmarks: 0.
- Inline unit/behavior tests: 68 plus root wiring coverage.
- Validation in this pass:
  - `zig build examples` passed.
  - `zig build docs-lint` passed.
  - `zig build test` passed.

Observed workspace usage in this pass:

- No external package usage was found under `packages/` or `docs/`.
- Current usage appears limited to `static_spatial`'s own example and tests.

## Package-Level Assessment

`static_spatial` has a solid core, but its package story is mixed.

The strongest parts are:

- `primitives.zig`
- `uniform_grid.zig`
- `uniform_grid_3d.zig`
- `bvh.zig`

Those modules fit the repository well:

- explicit geometry primitives;
- bounded broad-phase structures;
- iterative traversal;
- and clear query contracts.

The package gets weaker where it mixes in dynamic, allocator-on-mutation structures:

- `sparse_grid.zig`
- `incremental_bvh.zig`

Those modules are not automatically wrong, but they break the simple package narrative implied by the package name and root docs. The current root docs say the package allocates during build and not afterward. That is not true for the sparse grid family or for incremental BVH mutation paths.

So the package is technically useful, but its boundary needs to be cleaner:

- either it is the home for both static and dynamic spatial structures, with the distinction made explicit;
- or the dynamic pieces should move to a different package or sub-namespace.

## What Fits Well

### The primitives layer is strong and justified

`primitives.zig` is the package foundation and it is well done:

- constructors and `tryInit` variants make the programmer-error versus boundary-error split explicit;
- `AABB2.empty` and `AABB3.empty` are useful identity elements;
- ray, plane, frustum, and grid config helpers make the rest of the package readable.

This is the clearest package-local value outside the acceleration structures themselves.

### `UniformGrid`, `UniformGrid3D`, and `BVH` are the package's real identity

These are the modules that best match the repository's static/bounded goals:

- fixed-capacity storage after initialization;
- no recursion;
- predictable query semantics;
- and explicit error handling where capacity can fail.

If the package were trimmed to its most defensible core, these modules would clearly remain.

### The query contracts are mostly explicit

`BVH` does a good job documenting that returned hit counts can exceed `out.len`, while `IncrementalBVH` explicitly does not. That difference is important and the code states it.

That is a good fit with the repo's emphasis on explicit contracts.

## STD Overlap Review

### Primitive geometry has moderate std overlap, but the package composition is still justified

Closest std overlap:

- scalar arithmetic and comparisons in `std.math`
- raw structs and arrays for points, boxes, rays, and planes

Assessment:

- Zig std does not provide this exact package of geometry primitives and spatial-query helpers.
- The value is not any single formula; it is having a coherent set of interoperable primitive types and query semantics.

Recommendation:

- Keep `primitives.zig` as the package foundation.

### `morton.zig` has the highest standalone overlap risk

Closest std overlap:

- bit-twiddling utilities that callers could write locally

Assessment:

- `morton.zig` is small, correct-looking, and useful, but it is more of a utility than a package-defining feature.
- It is justified as support code for spatial indexing, not as a reason for the package to exist on its own.

Recommendation:

- Keep it, but keep it small and clearly subordinate to the spatial-indexing story.

### The spatial data structures themselves are justified

Closest std overlap:

- none directly

Assessment:

- Zig std does not ship bounded grids, BVHs, or frustum-query structures.
- This is the package's strongest justification.

Recommendation:

- Keep broad-phase structures as the package center.

## Correctness and Completeness Findings

## Finding 1: `root.zig` overstates the package's static allocation model

The package root says:

- acceleration structures allocate during `build`;
- and after build completes, no further allocation occurs.

That does not match the current package:

- `SparseGrid` and `SparseGrid3D` allocate on `insertPoint`;
- `IncrementalBVH` allocates on `insert`;
- and `IncrementalBVH.remove` can also allocate through the free-list append path.

This is the most concrete package-level completeness issue from this pass because it affects how readers reason about the package's safety and runtime behavior.

Recommendation:

- Fix the package root docs immediately.
- Separate the package into clearly named static-versus-dynamic sections, or move the dynamic structures elsewhere.

## Finding 2: `IncrementalBVH.remove` turns an operating OOM into `unreachable`

`incremental_bvh.zig` reclaims nodes by appending their indexes to `free_list`:

- `self.free_list.append(self.allocator, idx) catch unreachable`

That is not a proof-backed `unreachable`. It is an allocator call on a mutation path.

If the append needs to grow, OOM is an operating failure, not a programmer bug. Under the current design, `remove` can panic on memory pressure.

That conflicts with the repo's error-handling rules and is the clearest implementation-level defect in this package review.

Recommendation:

- Either pre-reserve free-list capacity so `remove` is truly allocation-free and the proof becomes real;
- or make `remove` fallible and propagate OOM explicitly.

## Finding 3: `BVHError` contains dead public error variants

`bvh.zig` exposes:

- `ScratchTooSmall`
- `OutputTooSmall`

I did not find reviewed code paths that return either of those errors.

That makes them dead contract surface:

- they broaden the public API without implemented behavior;
- they imply alternate APIs or scratch-buffer workflows that are not present;
- and they increase review cost for no current gain.

Recommendation:

- Remove unused error variants until there is an implemented path that needs them.

## Finding 4: `UniformGrid3D` contains a justified `catch unreachable`, but it should stay tightly justified

`UniformGrid3D.insertAABB` does:

- pre-check all targeted cells for capacity;
- then calls `insertCell(... ) catch unreachable`.

This use is much better justified than the incremental BVH free-list case, because:

- `insertCell` only fails with `CellFull`;
- `cellsHaveSpace` has already ruled that out for the full target range;
- and there is no allocator call inside `insertCell`.

I do not consider this a defect in the current review. It is a valid divergence, but it depends on that proof staying local and obvious.

Recommendation:

- Keep it only if the proof remains this direct.
- If `insertCell` ever gains another error source, this must be revisited immediately.

## Finding 5: Example coverage is too small for the package scope

One example is not enough for a package with:

- geometry primitives;
- Morton encoding;
- 2D and 3D uniform grids;
- sparse grids;
- loose grids;
- static BVH;
- incremental BVH;
- and frustum queries.

The current example only demonstrates:

- simple AABB overlap;
- a ray/AABB hit;
- and Morton encoding.

It does not teach the package's main value.

Recommendation:

- Add examples before adding any new API surface.
- Highest-value additions are:
  - `uniform_grid_3d_basic`;
  - `bvh_ray_aabb_frustum_basic`;
  - `incremental_bvh_insert_remove_refit`.

## Finding 6: The package is still self-validated

I found no external consumers of `static_spatial` in this pass.

That means:

- current surface breadth is still mostly self-justified;
- no downstream usage yet validates whether dynamic structures belong beside static ones;
- and example/test quality matters even more because there is no adoption pressure shaping the package.

Recommendation:

- Keep the surface stable and resist expansion until real consumers exist.

## Duplicate / Dead / Misplaced Code Review

### `SparseGrid` and `SparseGrid3D` duplicate each other in predictable ways

The 2D and 3D sparse grids repeat:

- cell-key logic;
- hash-map management;
- clear/deinit flow;
- and query semantics.

This is acceptable duplication. Generic abstraction would likely make the code harder to audit.

Recommendation:

- Keep the duplication unless bug-fix churn starts hitting both files repeatedly.

### `UniformGrid` and `UniformGrid3D` also mirror each other in healthy ways

This duplication is similarly acceptable because the domains are close but not identical.

The bigger issue is not duplication. It is keeping contracts aligned between the two versions.

### `BVHError` is dead surface today

This is the clearest dead-code/API item from the package:

- `ScratchTooSmall`
- `OutputTooSmall`

They should not be public until they are real.

### The dynamic structures may be boundary-misaligned

`SparseGrid` and `IncrementalBVH` are spatially relevant, so they are not obviously misplaced by topic.

But they are different in runtime philosophy from the bounded/static core. That is the package-boundary question:

- topic alignment says they belong;
- runtime-policy alignment says they may not.

Recommendation:

- Decide explicitly whether `static_spatial` is a topic package or a bounded-runtime package.
- Right now it tries to be both.

## Example Coverage

Current example coverage:

- basic AABB overlap;
- basic ray/AABB query;
- basic Morton encode/decode.

Missing example coverage:

- bounded 2D/3D uniform grid workflows;
- query truncation semantics for BVH;
- frustum query usage;
- incremental BVH mutation lifecycle;
- sparse-grid tradeoffs and non-hot-path usage.

Recommendation:

- Add examples that teach the package's actual design boundaries, not just primitive math.

## Test Coverage

Coverage is solid overall.

Strengths:

- `primitives.zig` is heavily tested across valid and invalid construction paths;
- grids have capacity and out-of-bounds tests;
- BVH has ray, AABB, sorted-ray, and frustum coverage;
- incremental BVH covers insert, remove, refit, and empty queries.

Gaps:

- no tests appear to target the `IncrementalBVH.remove` OOM path because it is currently not representable without allocator injection;
- example coverage does not reinforce the main package contracts;
- there is no stronger package-level test around the static-versus-dynamic allocation split.

The highest-value next test is not another overlap query. It is a deterministic test or design change that removes the `free_list.append(... ) catch unreachable` hazard in `IncrementalBVH`.

## Adherence to `AGENTS.md`

Overall assessment:

- the bounded structures fit the repo rules well;
- control flow is explicit and iterative;
- assertions are common and useful;
- comments usually explain why, not just what;
- and the core broad-phase structures are well aligned with the repo's style.

Good fits with the repo rules:

- iterative BVH build and traversal;
- bounded fixed-capacity grids;
- explicit error unions for capacity failure;
- strong negative-path tests around invalid inputs and overflow.

Meaningful divergences:

- `SparseGrid` and `IncrementalBVH` allocate after initialization;
- `uniform_grid_3d.zig` says "Production-ready", which is exactly the kind of completeness/performance claim the repo guidance says to avoid;
- `IncrementalBVH.remove` currently treats a potential OOM like a bug.

Some of those divergences are acceptable if the package explicitly intends to host dynamic structures. The OOM handling issue is not.

## Refactor Paths

### Path 1: Clean up the package identity first

Decide whether `static_spatial` means:

- spatial algorithms broadly;
- or bounded/static spatial structures specifically.

If it is the latter, `SparseGrid` and `IncrementalBVH` need sharper isolation or relocation.

### Path 2: Fix the root docs and dynamic-mutation contracts

Highest-value immediate fixes:

- correct `root.zig` so allocation behavior is described truthfully;
- remove "Production-ready" language from `uniform_grid_3d.zig`;
- fix `IncrementalBVH.remove` so OOM is either impossible by construction or explicit in the type.

### Path 3: Trim dead BVH error surface

Remove unused `BVHError` variants until there is implemented behavior that actually uses them.

### Path 4: Add examples for the package core, not the primitives edge

The next examples should focus on:

- fixed-capacity 3D grid usage;
- BVH truncation and query modes;
- incremental BVH mutation and refit behavior.

## Bottom Line

`static_spatial` has a strong core and a blurry boundary.

The bounded primitives, uniform grids, and static BVH are good fits for the repository and appear technically solid. The main issues are package-level clarity and one concrete error-handling defect:

1. `root.zig` overstates the package's no-allocation-after-build model;
2. `IncrementalBVH.remove` can panic on allocator failure through `catch unreachable`;
3. `BVHError` contains dead public variants;
4. example coverage is too thin for the package size; and
5. the package still has no downstream consumers.

The best next step is not more API. It is to tighten the package boundary, fix the mutation-path OOM handling, and document the bounded-versus-dynamic split honestly.
