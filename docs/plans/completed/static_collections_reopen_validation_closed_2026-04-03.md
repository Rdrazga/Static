# `static_collections` reopen validation closure

Scope: close the reopened 2026-04-03 validation queue against the completed
`static_collections` follow-up baseline.

Status: closed on 2026-04-03 after the validated implementation slices landed
under `zig build test` and `zig build docs-lint`.

## Closed items

1. `FlatHashMap` overwrite-path growth
   `put()` and `putNoClobber()` now prove key existence before attempting
   growth, so existing-key overwrite and duplicate-key rejection no longer
   allocate, rehash, or budget-fail first.
2. `IndexPool` free-stack fail-fast strength
   `assertFullInvariants()` now uses the occupied slice as bounded scratch to
   prove the free stack is a duplicate-free permutation of the free slots
   rather than only matching counts.
3. `MinHeap.clear()` tracked-index semantics
   `clear()` now invalidates all tracked indices through the explicit
   `invalid_index` sentinel, and `PriorityQueue.clear()` inherits and
   documents the same contract.
4. `MinHeap.clone()` contract hardening
   `clone()` now documents the true ownership split: backing storage is copied
   independently, while `Ctx` is still copied by value and may continue to
   reference shared external state.

## Direct proof added

- `flat_hash_map.zig`
  direct budgeted tests now prove overwrite and duplicate-key rejection stay
  deterministic when growth would otherwise fail.
- `index_pool.zig`
  a bounded direct test now proves duplicate free-stack corruption is
  detectable without leaving scratch-state mutations behind.
- `min_heap.zig`
  direct tests now prove the clear-time invalidation sentinel and the retained
  clone contract for pointer-backed contexts.
- `priority_queue_index_tracking.zig`
  integration coverage now proves tracked indices are nulled on clear through
  the queue adaptor boundary.

## Remaining reopen triggers

- Reopen `MinHeap` only if a downstream user needs stronger clone isolation
  than "independent storage plus by-value context copy", or if the
  `invalid_index` sentinel proves insufficient for a real tracked-context
  consumer.
- Reopen `FlatHashMap` only if a new collision, tombstone, or iteration issue
  appears beyond the now-closed overwrite-path growth fix.
- Reopen `IndexPool` only if a new fail-fast invariant gap appears beyond the
  restored duplicate-free free-stack proof.
