# `static_collections` alias/clone/invariant fixes - completed 2026-04-04

Scope: close the reopened `static_collections` correctness slice for
`Vec.appendSliceAssumeCapacity`, `FlatHashMap.clone`, and
`IndexPool.assertFullInvariants`.

Validation commands:

- `zig build test`
- `zig build docs-lint`

## Reopen baseline

- `docs/plans/completed/static_collections_review_2026-04-03.md`
- `docs/plans/completed/static_collections_followup_closed_2026-04-03.md`
- `docs/plans/completed/static_collections_reopen_validation_closed_2026-04-03.md`
- `docs/plans/completed/static_collections_validated_review_fixes_2026-04-04.md`
- `docs/plans/completed/static_collections_tiger_style_hardening_2026-04-04.md`

## Completed work

1. `Vec append-slice overlap contract`
   `Vec.appendSliceAssumeCapacity()` now documents that overlap is supported
   when capacity has already been reserved, and the implementation now uses
   `@memmove` so self-alias append calls stay well-defined.

2. `FlatHashMap clone initialization hygiene`
   `FlatHashMap.clone()` now copies slot-state metadata plus only the occupied
   entries, so cloning sparse or cleared tables no longer reads never-written
   empty-entry storage.

3. `IndexPool full-invariant proof restore`
   `IndexPool.assertFullInvariants()` now fails fast on duplicate free-stack
   entries again through a read-only duplicate scan, restoring the uniqueness
   proof that the comments and prior closure notes describe.

4. `Direct regression coverage`
   The package unit surface now proves:
   - self-alias `Vec.appendSliceAssumeCapacity()` works after explicit capacity
     reservation;
   - cloning a cleared `FlatHashMap` preserves an empty logical state and
     reusable capacity; and
   - duplicate free-stack corruption is detectable through the same
     duplicate-scan primitive used by `IndexPool.assertFullInvariants()`.

5. `Repository knowledge trail`
   The active workspace queue no longer points at an open `static_collections`
   package plan, and this closure record now owns the completed slice.
