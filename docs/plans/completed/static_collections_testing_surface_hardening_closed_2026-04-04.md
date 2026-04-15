# `static_collections` testing-surface hardening closure

Closed: 2026-04-04

## Goal

Reopen `static_collections` only for the uneven-testing follow-up identified by
the package review: add negative compile-contract proof for the key generic
`@compileError` boundaries and widen deterministic sequence coverage for the
runtime-heavy collection families still relying mostly on short scripted tests.

## Reopen baseline

- `docs/plans/completed/static_collections_review_2026-04-03.md`
- `docs/plans/completed/static_collections_tiger_style_hardening_2026-04-04.md`
- `docs/plans/completed/static_collections_validated_review_fixes_2026-04-04.md`
- `docs/plans/completed/static_collections_alias_clone_invariant_fixes_2026-04-04.md`
- `docs/plans/completed/static_collections_ergonomics_followup_closed_2026-04-04.md`
- `docs/plans/completed/static_collections_map_entry_helpers_closed_2026-04-04.md`
- `docs/plans/completed/static_collections_post_review_fix_slice_closed_2026-04-04.md`

## Delivered

1. `Negative compile-contract harness`
   Added a package-owned compile-fail harness under
   `packages/static_collections/tests/compile_fail/` plus an integration driver
   in `packages/static_collections/tests/integration/compile_contract_failures.zig`.
   The supported root `zig build test` surface now proves four negative cases:
   padded/default-hash rejection and invalid hash signature for `FlatHashMap`,
   invalid comparator signatures for `MinHeap`, and invalid comparator
   signatures for `SortedVecMap`.
2. `FlatHashMap model coverage`
   Added deterministic `testing.model` runtime sequences in
   `packages/static_collections/tests/integration/flat_hash_map_runtime_sequences.zig`
   covering clustered-hash mutation, borrowed lookup/remove paths,
   get-or-put insertion versus overwrite, clear/reuse, clone isolation, and
   growth under collision-heavy probe state.
3. `SortedVecMap and SparseSet sequence coverage`
   Added deterministic `testing.model` runtime sequences in
   `packages/static_collections/tests/integration/sorted_vec_map_runtime_sequences.zig`
   and `packages/static_collections/tests/integration/sparse_set_runtime_sequences.zig`
   to widen ordered-map and dense-membership state coverage without deleting the
   existing direct scripted tests.
4. `Immediate bug-fix fallout`
   `SortedVecMap` comparator-signature validation now runs at type
   instantiation rather than lazily on first comparison, keeping the generic
   contract aligned with the new compile-fail proof surface.
5. `Repo knowledge`
   Updated `AGENTS.md`, `README.md`, and `docs/architecture.md` so the package
   map reflects the broader `static_collections` validation surface.

## Validation

- `zig build test`
- `zig build docs-lint`

## Follow-up trigger

Reopen `static_collections` only if a new stateful container family remains
stuck on narrow scripted coverage, a generic compile-contract boundary loses
negative proof, or the new sequence slices expose a concrete production bug
class that needs a dedicated follow-up.
