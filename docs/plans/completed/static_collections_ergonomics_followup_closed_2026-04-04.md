# `static_collections` ergonomics follow-up closed 2026-04-04

Scope: close the reopened 2026-04-04 `static_collections` package review
follow-up covering API contracts, public-surface parity, borrow-first
ergonomics, and the remaining naming/documentation cleanup.

Reopen baseline:

- `docs/plans/completed/static_collections_review_2026-04-03.md`
- `docs/plans/completed/static_collections_tiger_style_hardening_2026-04-04.md`
- `docs/plans/completed/static_collections_validated_review_fixes_2026-04-04.md`
- `docs/plans/completed/static_collections_alias_clone_invariant_fixes_2026-04-04.md`

Validation commands:

- `zig build test`
- `zig build docs-lint`
- `zig build examples`

## Completed work

1. `Vec oversized-capacity contract`
   `Vec.ensureCapacity()` now rejects public requests above the package's
   supported `u32` capacity bound with a stable `error.Overflow` before budget
   reservation or allocator side effects, and direct coverage proves the
   contract.

2. `Error vocabulary and compile-time cleanup`
   `BitSet.init()` now uses `InvalidConfig` for zero-bit impossible setup and
   `Overflow` for arithmetic failure, `SparseSet.init()` now returns
   `Overflow` for universe-size multiplication failure, and `FixedVec(0)` now
   emits an explicit `@compileError` instead of a raw assertion failure.

3. `Common surface parity`
   `SmallVec` now exposes `capacity`, `itemsConst`, and `clear` without hiding
   its one-way spill behavior. `SlotMap`, `SortedVecMap`, and `FlatHashMap`
   now expose public const-iterator surfaces, and the map iterators keep keys
   immutable while still allowing mutable value access where safe.

4. `Borrow-first ergonomics`
   `SortedVecMap` now supports `getBorrowed`, `getConstBorrowed`,
   `containsBorrowed`, and `removeBorrowed`, plus either by-value or borrowed
   `Cmp.less` signatures. `FlatHashMap` and `FlatHashSet` now support borrowed
   lookup/removal helpers, and `Ctx.hash` / `Ctx.eql` may use either by-value
   or `*const` key signatures. `MinHeap` now accepts either by-value or
   pointer-style comparator signatures for both contextual and `Ctx == void`
   comparator paths.

5. `Documentation and repo knowledge trail`
   The affected collection docs now explain the chosen iterator and
   borrow-first boundaries, ASCII cleanup has been applied across the touched
   sources, and the repo-level package descriptions plus workspace queue docs
   now reflect the closed follow-up.

## Validation summary

- `zig build test`
- `zig build docs-lint`
- `zig build examples`
