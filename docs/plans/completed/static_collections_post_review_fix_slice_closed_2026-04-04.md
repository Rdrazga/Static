# `static_collections` post-review fix slice closed 2026-04-04

Scope: close the reopened `static_collections` follow-up recorded after the
2026-04-04 package audit. The slice stayed intentionally narrow: one
`SmallVec` correctness fix, one `FlatHashMap` default-hash safety extension,
and one `Handle` doc correction.

Reopen baseline:

- `docs/plans/completed/static_collections_review_2026-04-03.md`
- `docs/plans/completed/static_collections_tiger_style_hardening_2026-04-04.md`
- `docs/plans/completed/static_collections_validated_review_fixes_2026-04-04.md`
- `docs/plans/completed/static_collections_alias_clone_invariant_fixes_2026-04-04.md`
- `docs/plans/completed/static_collections_ergonomics_followup_closed_2026-04-04.md`
- `docs/plans/completed/static_collections_map_entry_helpers_closed_2026-04-04.md`

Validation commands:

- `zig build test`
- `zig build docs-lint`

## Completed work

1. `SmallVec spilled-empty shrink contract`
   `SmallVec` no longer asserts that a non-null spill must always have positive
   length or capacity. An empty spilled `SmallVec` may now legally shrink to
   zero capacity while remaining in the one-way spilled state, and direct
   coverage proves `spill -> clear -> shrinkToFit -> append` remains reusable.

2. `FlatHashMap default-hash representation safety`
   The default-hash safety helper now models broader raw-representation risk
   instead of only struct padding. Union-shaped keys and nested wrappers around
   them are now rejected from the default raw-byte hash path unless callers
   provide a custom `Ctx.hash`, and direct coverage keeps both the risk helper
   and the custom-hash union escape hatch live.

3. `Handle invalid-sentinel docs`
   The handle module docs now match the actual API and refer to
   `Handle.invalid()`.

## Validation summary

- `zig build test`
- `zig build docs-lint`
