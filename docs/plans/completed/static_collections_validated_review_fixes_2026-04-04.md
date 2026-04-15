# `static_collections` validated review fixes â€” completed 2026-04-04

Scope: close the validated 2026-04-04 `static_collections` review findings
without regressing the package's in-flight work.

Validation commands:

- `zig build test`
- `zig build docs-lint`

## Completed work

1. `MinHeap tracked-index invalidation`
   `popMin()` and `removeAt()` now invalidate removed tracked indices through
   `Ctx.setIndex(..., invalid_index)` before returning the removed value.
   Direct heap coverage and downstream `static_queues` index-tracking coverage
   now prove removed entries stop publishing stale indices.

2. `Vec const-correct item access`
   `Vec.items()` now requires `*Self`, `Vec.itemsConst()` owns the const-view
   path, and `DenseArray` plus the package model coverage now use the correct
   receiver flavor.

3. `FlatHashMap default-hash safety`
   The default hash path now rejects key types whose raw byte representation
   contains padding unless callers provide a custom `Ctx.hash`, and package
   coverage keeps the custom-hash escape hatch live for padded composite keys.

4. `SmallVec oversized-capacity operating error`
   `SmallVec.ensureCapacity()` now returns `error.Overflow` for oversized
   runtime requests instead of asserting, and direct coverage locks that
   operating-error contract down.

5. `Repository knowledge trail`
   The workspace queue, repo-level package descriptions, and plan archive now
   record the reopened `static_collections` fix slice and its closure.
