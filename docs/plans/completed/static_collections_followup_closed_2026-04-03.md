# `static_collections` follow-up plan

Scope: fixed-capacity and allocation-aware collection types.

Status: follow-up closed on 2026-04-03. The root-surface review is now
implemented, the ECS-shape boundary is recorded, the remaining iterator and
regression fixes landed with direct proof, the reopened validation queue is now
closed again, the first shared benchmark owner is admitted, and no
collection-specific helper is strong enough to move into `static_testing`
today.

## Current posture

- The package root is now intentionally narrow: keep the exported collection
  families plus the `memory` alias, and cut the `core` and `hash` aliases from
  `src/root.zig`.
- `SlotMap` now documents that structural mutation invalidates iterators and
  yielded pointers, and package-owned integration coverage now proves iterator
  handle/value visibility up to the next structural mutation.
- The follow-up regression fixes are closed:
  `SmallVec` now retires inline state once spill becomes authoritative so
  spilled vectors can drain back to empty safely, and `FlatHashMap.clone()`
  now copies only occupied entries instead of reading undefined empty slots.
- The reopened validation fixes are also closed:
  `FlatHashMap.put()` and `putNoClobber()` now prove existing-key overwrite or
  duplicate-key rejection before any growth attempt, `IndexPool` full
  invariants again prove free-stack uniqueness instead of only matching
  counts, `MinHeap.clear()` and `PriorityQueue.clear()` now invalidate tracked
  indices through the explicit `invalid_index` sentinel, and `MinHeap.clone()`
  now documents and directly proves that storage is copied independently while
  pointer-backed comparator contexts still alias shared external state.
- The canonical admitted benchmark set is the shipped
  `packages/static_collections/benchmarks/flat_hash_map_lookup_insert_baselines.zig`
  executable with the bounded `lookup_hit_hotset` and `insert_remove_churn`
  workloads, validated through `zig build bench` on the shared `baseline.zon`
  plus `history.binlog` path.
- The ECS-shape extraction review is recorded: keep `Handle`, `IndexPool`,
  `SparseSet`, `Vec`, and the generic container families package-local as
  reusable substrate, while archetype/chunk storage, entity-row relocation,
  batch component moves, and query/view adapters stay out of `static_collections`
  and belong to a future `static_ecs` package if they are ever promoted.
- The package-owned model/integration harnesses stay local. `SlotMap`,
  `IndexPool`, and `Vec` action tables and reference states are still family-
  specific, while the shared runner, reduction, replay, and persistence
  mechanics already live in `static_testing`.

## Deferred benchmark candidates

- `sorted_vec_map` ordered insert/update churn remains deferred until review
  needs a small-map canonical comparison beyond the admitted `flat_hash_map`
  workload.
- `small_vec` inline-versus-spill crossover timing remains deferred until a
  concrete allocator-sensitive tuning question appears.
- `dense_array` packed iteration and swap-remove churn remain deferred until an
  ECS-adjacent review names a concrete packed-storage hot path worth admitting.

## Open follow-up triggers

- Reopen benchmark admission only if review needs a concrete second collection
  workload beyond `flat_hash_map` lookup/insert churn.
- Reopen shared-harness extraction only if multiple collection families start
  sharing enough action-table framing that a package-local helper stops being
  family-specific.
- Reopen root-surface review only if downstream usage demonstrates a concrete
  value for another transitive alias beyond the retained `memory` export.
- Reopen ECS-shape extraction only if a future package slice promotes an exact
  archetype, chunk, relocation, or query/view primitive instead of a generic
  reusable container.
- Reopen `MinHeap` contract work only if a real downstream caller needs a
  stronger clone-isolation guarantee than the retained by-value context copy,
  or if the `invalid_index` sentinel needs to change.
