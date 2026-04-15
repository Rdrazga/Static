# `static_collections` map entry helper follow-up closed 2026-04-04

Scope: close the narrow additive helper slice for the map families without
committing `static_collections` to a full occupied/vacant entry API.

Reopen baseline:

- `docs/plans/completed/static_collections_ergonomics_followup_closed_2026-04-04.md`
- `docs/sketches/static_collections_ergonomics_proposals_2026-04-04.md`

Validation commands:

- `zig build test`
- `zig build docs-lint`
- `zig build examples`

## Completed work

1. `Shared helper naming and result contract`
   `SortedVecMap` and `FlatHashMap` now both expose `getOrPut(key, default)`
   returning `{ value_ptr, found_existing }`, and both expose `removeOrNull`
   alongside the existing strict `remove` path.

2. `SortedVecMap helper implementation`
   `SortedVecMap.getOrPut()` now uses one binary-search result to decide
   whether to return the existing value pointer or insert a new slot, and
   `removeOrNull` / `removeOrNullBorrowed` now provide the soft-miss removal
   path without weakening `remove`.

3. `FlatHashMap helper implementation`
   `FlatHashMap.getOrPut()` now proves the existing-key fast path before
   `ensureInsertCapacity()` runs, and `removeOrNull` /
   `removeOrNullBorrowed` now wrap the existing probing and tombstone update
   logic without changing the strict `remove` contract. `FlatHashSet` also
   forwards a boolean `removeOrNull` helper.

4. `Public usage proof and repo knowledge`
   Direct collection tests now cover both insertion and existing-key helper
   behavior, including the no-growth existing-key path for `FlatHashMap`, and
   the repo queue plus package descriptions now record the bounded helper
   subset that landed.

## Explicit non-goals kept out of this slice

- No occupied/vacant entry-handle API.
- No `getOrPutAssumeCapacity` public API.
- No heterogeneous borrowed-key insertion contract.
- No package-wide trait or adapter layer for containers.
