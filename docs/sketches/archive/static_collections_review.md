# Sketch: `static_collections` Package Review

Date: 2026-03-06 (America/Denver)  
Status: First review pass completed.

## Scope

Review `packages/static_collections/` for:

- adherence to `agents.md`;
- overlap with Zig standard library facilities and whether the package adds enough value;
- correctness and completeness at file and package scope;
- duplicate, dead, or misplaced code;
- example and test coverage; and
- practical refactor paths.

## Package Inventory

- Source files: 12 (`vec`, `fixed_vec`, `small_vec`, `bit_set`, `dense_array`, `handle`, `index_pool`, `slot_map`, `flat_hash_map`, `sorted_vec_map`, `sparse_set`, `min_heap`).
- Examples: 4 (`vec_basic`, `flat_hash_map_seeded`, `slot_map_handles`, `min_heap_basic`).
- Benchmarks: 0.
- Inline unit tests: 58.
- Validation in this pass:
  - `zig build examples` passed.
  - `zig build test` failed outside this package because `static_queues` has a failing stress test at `packages/static_queues/src/testing/lock_free_stress.zig:105`.

Workspace usage observed in this pass:

- `index_pool` is used by `static_io` and `static_scheduling`.
- The other public `static_collections` types appear unused outside their own package examples/tests right now.

## Package-Level Assessment

`static_collections` is useful, but it is the least cohesive package reviewed so far.

The biggest design issue is that it mixes two different families under one name:

- genuinely bounded/static or capacity-first containers (`fixed_vec`, `index_pool`, `min_heap`, parts of `bit_set`);
- allocator-backed, potentially unbounded convenience containers (`vec`, `small_vec`, `slot_map`, `flat_hash_map`, `sorted_vec_map`, `dense_array`).

That is not automatically wrong, but it creates tension with the workspace's static-first design goals. Several APIs only become "bounded" if the caller separately enforces allocator policy or budgets.

## What Fits Well

### `index_pool` is the clearest win

`index_pool` is the strongest module in the package:

- it has a crisp purpose;
- it is explicitly bounded;
- it uses generation-protected handles;
- it is already adopted by `static_io` and `static_scheduling`; and
- it has little std overlap.

This is the sort of collection primitive that clearly belongs in the workspace.

### `fixed_vec` and `min_heap` match the repository goals

These two types align well with the repo's design rules:

- no hidden growth;
- explicit capacity;
- deterministic failure on exhaustion; and
- simple operational semantics.

`min_heap` in particular adds value over std because it chooses bounded capacity and `error.NoSpaceLeft` instead of allocator-driven growth.

### `Vec` is thin but still justified by budget integration

`vec.Vec` is mostly a wrapper around `std.ArrayListUnmanaged`, but the optional `static_memory` budget wiring is a real workspace-specific feature. That makes it more than a cosmetic alias.

## STD Overlap Review

### `vec`, `fixed_vec`, and `small_vec`

Closest std overlap:

- `std.ArrayList` / `std.ArrayListUnmanaged`
- caller-written fixed arrays for bounded vectors

Assessment:

- `Vec` is justified mainly by budget integration and uniform error vocabulary.
- `FixedVec` is justified because it gives a tiny bounded vector with no allocation.
- `SmallVec` is the least justified of the three. The pattern is valid, but it is not currently proven by external usage, and it increases surface area considerably.

Recommendation:

- Keep `Vec` and `FixedVec`.
- Keep `SmallVec` only if a real consumer needs the spill transition behavior; otherwise it is a likely candidate for later pruning.

### `bit_set`

Closest std overlap:

- `std.bit_set`

Assessment:

- This module overlaps std heavily and currently exposes only a very small subset of the standard feature surface.
- Its current value over std is limited unless the project wants a tiny, intentionally constrained bitset API.

Recommendation:

- Re-evaluate whether this should remain a standalone package primitive or become a thin wrapper policy around std bit sets.
- If kept, document why the intentionally smaller API is the correct constraint.

### `flat_hash_map`

Closest std overlap:

- `std.hash_map`
- `std.array_hash_map`

Assessment:

- The seeded hashing path and explicit context hooks are useful.
- But the implementation overlaps std heavily while offering a narrower feature set and no current external adoption.

Recommendation:

- Keep only if stable seeded hashing and fixed package semantics are important enough to justify owning an open-addressing map implementation.
- Otherwise consider whether a narrower wrapper over std would meet the same need more cheaply.

### `sorted_vec_map`

Closest std overlap:

- sorted slices plus binary search
- `std.ArrayListUnmanaged` as the backing store

Assessment:

- This is a reasonable container for small ordered maps and has a clear performance/story tradeoff.
- It has less direct std overlap than `flat_hash_map`, but it is still currently unproven by usage.

Recommendation:

- Keep as a small-map primitive if later packages actually depend on ordered iteration with small cardinalities.

### `min_heap`

Closest std overlap:

- `std.priority_queue`
- `std.priority_dequeue`

Assessment:

- This module has real value because it is capacity-first and explicit about `NoSpaceLeft`.
- That is a meaningful semantic difference, not just a wrapper.

Recommendation:

- Keep `min_heap`.
- It is one of the package's best fits.

### `handle`, `index_pool`, `slot_map`, and `dense_array`

Closest std overlap:

- little to none directly in std for generation-protected handles and slot allocators

Assessment:

- `handle` and `index_pool` are strong primitives.
- `slot_map` is a valid higher-level container, but it duplicates generation/free-list machinery that `index_pool` already encapsulates.
- `dense_array` currently does not match its own documentation and is the weakest member of this family.

Recommendation:

- Keep `handle` and `index_pool`.
- Revisit whether `slot_map` should build on `index_pool` or a shared lower-level slot allocator instead of duplicating handle lifecycle logic.

## Correctness and Robustness Findings

## Finding 1: `dense_array.zig` documentation does not match the implementation

`packages/static_collections/src/collections/dense_array.zig:1` describes stable `Handle` identifiers with generation tracking. The actual implementation:

- returns `usize` indices from `append`;
- looks up by raw index;
- uses `swapRemove`; and
- therefore invalidates moved indices.

This is not a small wording issue; it describes a different data structure than the code actually implements.

Recommendation:

- Either rewrite the module docs to describe a plain dense swap-remove array, or redesign the type to actually provide handle semantics.
- If handle semantics are desired, this likely belongs with `index_pool` and/or `slot_map`, not as a thin wrapper over `Vec`.

## Finding 2: `SparseSet` docs claim a generic API that does not exist

`packages/static_collections/src/collections/sparse_set.zig:1` says `SparseSet(T)`, but the implementation is a concrete `u32` sparse set.

Recommendation:

- Fix the docs to describe the actual API (`u32` IDs in a bounded universe), or generalize the implementation if the generic shape is intentional.

## Finding 3: `flat_hash_map` compile-time context validation is incomplete

`packages/static_collections/src/collections/flat_hash_map.zig:29` says the context is validated at comptime, but the validation currently checks only part of the contract:

- `Ctx.hash` arity is checked, but not parameter types or return type.
- `Ctx.eql` arity is checked, and only the first parameter is verified against `K`.
- the second parameter and return type are not validated.

This does not necessarily create a runtime bug, but it weakens the promised diagnostics and can allow confusing downstream compiler errors.

Recommendation:

- Strengthen `validateCtx` so it fully checks both function signatures against the documented contract.

## Finding 4: `min_heap` contains a stale internal documentation reference

`packages/static_collections/src/collections/min_heap.zig:6` references `docs/roadmap/09_deferred_items_schedule.md`, but that path is currently missing.

Recommendation:

- Remove or update the dead internal reference so the comment remains self-contained and trustworthy.

## Finding 5: package naming and design goals are in tension

Several modules are allocator-backed and open-ended unless the caller separately constrains memory:

- `vec`
- `small_vec`
- `dense_array`
- `slot_map`
- `flat_hash_map`
- `sorted_vec_map`

That is a meaningful divergence from the repo's static-first posture. Some of it is defensible for control-plane code, but it should be made explicit.

Recommendation:

- Clarify in the package docs which containers are:
  - fixed-capacity;
  - capacity-configured at init; or
  - allocator-backed with optional budget limits.
- Consider whether some dynamic containers belong in a differently named package if the workspace wants `static_*` names to imply stronger boundedness.

## Duplicate / Dead / Misplaced Code Review

### `slot_map` duplicates lifecycle logic already present in `index_pool`

Both modules manage:

- generation counters;
- free-slot reuse; and
- stale-handle invalidation.

The duplication is not exact, but the concepts are the same. This increases maintenance cost and raises the chance that future fixes land in one place but not the other.

Recommendation:

- Extract a shared slot-allocation primitive or make `slot_map` build on `index_pool`.

### Most of the package is public but not yet validated by real consumers

In this pass, only `index_pool` showed meaningful external use. The rest of the package looks more like a library catalog than a set of primitives already demanded by the workspace.

That does not make the code dead, but it does mean the public API is ahead of demonstrated need.

Recommendation:

- Prioritize maintenance and polish around externally used modules first.
- Let actual consumers justify keeping or expanding the thinner wrappers.

## Example Coverage

The package has examples for only 4 of its 12 modules:

- `vec`
- `flat_hash_map`
- `slot_map`
- `min_heap`

Missing examples for important modules:

- `index_pool`
- `bit_set`
- `sorted_vec_map`
- `sparse_set`
- `fixed_vec`
- `small_vec`
- `dense_array`

Recommendation:

- Add an `index_pool` example first, because it is externally used and central to the package's strongest value.
- Then add one bounded-container example (`fixed_vec` or `bit_set`) and one ordered-container example (`sorted_vec_map`).

## Test Coverage

Coverage is broad at the unit level:

- `vec`: 7 tests
- `fixed_vec`: 3 tests
- `small_vec`: 3 tests
- `bit_set`: 7 tests
- `dense_array`: 5 tests
- `handle`: 2 tests
- `index_pool`: 3 tests
- `slot_map`: 5 tests
- `flat_hash_map`: 6 tests
- `sorted_vec_map`: 5 tests
- `sparse_set`: 6 tests
- `min_heap`: 6 tests

Strengths:

- most modules exercise basic success and failure behavior;
- the package has decent edge coverage for bounds, stale handles, load factor config, and heap exhaustion.

Gaps:

- there are no behavior-level tests proving the externally used `index_pool` interactions in `static_io` and `static_scheduling`;
- there is little cross-module coverage for the handle/index family;
- example coverage is much thinner than test coverage.

Recommendation:

- Add one behavior-level integration test around `index_pool` in a real consumer path.
- Add at least one test that compares `slot_map` lifecycle expectations against `index_pool` semantics if both are kept.

## Prioritized Recommendations

### High priority

1. Fix the `dense_array` documentation/API mismatch.
2. Fix the `SparseSet` documentation mismatch.
3. Decide whether `slot_map` should share lifecycle machinery with `index_pool`.
4. Clarify which `static_collections` types are truly bounded versus allocator-backed.

### Medium priority

1. Strengthen `flat_hash_map` context signature validation.
2. Add an `index_pool` example and one or two more representative examples.
3. Remove the stale `min_heap` roadmap reference.

### Low priority

1. Revisit whether `bit_set` and `flat_hash_map` justify owning custom implementations instead of leaning more on std.
2. Reassess `small_vec` if it remains externally unused.

## Bottom Line

`static_collections` has useful pieces, but it currently feels like a mixed bag rather than a sharply curated package.

The strongest, most workspace-justified parts are:

- `index_pool`
- `handle`
- `fixed_vec`
- `min_heap`

The least convincing parts are the thin or unproven wrappers over std-like facilities:

- `bit_set`
- `flat_hash_map`
- `small_vec`
- `dense_array` in its current documented form

The package does not need a rewrite, but it does need tighter curation:

- correct the docs;
- center the externally useful primitives;
- reduce or better justify overlapping wrappers; and
- make the boundedness story explicit module by module.
