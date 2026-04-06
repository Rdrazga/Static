# `static_collections` ReleaseFast invariant follow-up

Scope: close the 2026-04-06 reopen that validated traversal-heavy
post-mutation invariant work leaking into `ReleaseFast` hot paths for the
affected collection families, and the missing benchmark owner for those paths.

Status: follow-up closed on 2026-04-06. The validated full invariant walkers
now short-circuit outside runtime-safety builds, and the package now owns a
canonical hot-path benchmark owner for the touched mutation families.

## Validated issue scope

- `IndexPool`, `MinHeap`, `SlotMap`, `SparseSet`, and `SortedVecMap` each kept
  their expensive full invariant traversals on hot mutation paths even when
  runtime safety was off.
- The package benchmark surface exposed `flat_hash_map` lookup/insert churn,
  but it had no canonical owner covering the invariant-sensitive mutation hot
  paths in the touched families.

## Implemented fixes

- The full invariant walkers in
  [index_pool.zig](/C:/Users/ryan/Desktop/Forbin%20Solutions/Library%20Dev/static/packages/static_collections/src/collections/index_pool.zig),
  [min_heap.zig](/C:/Users/ryan/Desktop/Forbin%20Solutions/Library%20Dev/static/packages/static_collections/src/collections/min_heap.zig),
  [slot_map.zig](/C:/Users/ryan/Desktop/Forbin%20Solutions/Library%20Dev/static/packages/static_collections/src/collections/slot_map.zig),
  [sparse_set.zig](/C:/Users/ryan/Desktop/Forbin%20Solutions/Library%20Dev/static/packages/static_collections/src/collections/sparse_set.zig),
  and
  [sorted_vec_map.zig](/C:/Users/ryan/Desktop/Forbin%20Solutions/Library%20Dev/static/packages/static_collections/src/collections/sorted_vec_map.zig)
  now return immediately when `std.debug.runtime_safety` is off.
- The package now owns
  [collections_hotpaths.zig](/C:/Users/ryan/Desktop/Forbin%20Solutions/Library%20Dev/static/packages/static_collections/benchmarks/collections_hotpaths.zig),
  a shared-workflow benchmark owner covering:
  `index_pool_alloc_release`, `min_heap_push_pop`,
  `slot_map_insert_remove`, `sparse_set_insert_remove`, and
  `sorted_vec_map_put_remove`.
- The benchmark helper in
  [support.zig](/C:/Users/ryan/Desktop/Forbin%20Solutions/Library%20Dev/static/packages/static_collections/benchmarks/support.zig)
  now sizes its report buffers by case count instead of assuming the old
  two-case owner shape.
- Root bench wiring now admits `collections_hotpaths`.
- Package docs now describe the new benchmark owner and the invariant-gating
  contract.

## Proof posture

- `zig build check`
- `zig build test --summary all`
- `zig build collections_hotpaths`
- `zig build bench`
- `zig build docs-lint`

## Current posture

- The touched collection families keep their full invariant proofs in
  runtime-safety builds without charging that traversal cost to
  `ReleaseFast`.
- The package now has a canonical hot-path benchmark owner for the previously
  under-observed invariant-sensitive mutation slice instead of relying on ad
  hoc local measurement.

## Reopen triggers

- Reopen if a touched family starts running its full invariant walk again in
  non-runtime-safety builds.
- Reopen if another collection family develops the same invariant-cost leak and
  clearly belongs in the shared hot-path owner or a second canonical owner.
