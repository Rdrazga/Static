# `dense_array` end-state sketch - 2026-04-02

## Goal

Pick the best durable end state for `static_collections.dense_array` before
implementation changes begin.

The correct target is not "make the current code match the old docs by adding
handles." The correct target is to choose the simplest, strongest production
shape that fits the repo rules and the actual caller needs.

## Current mismatch

Today `packages/static_collections/src/collections/dense_array.zig` says:

- stable `Handle` identifiers
- generation-based stale-reference detection

But the implementation actually provides:

- contiguous dense storage
- `usize` index return from `append`
- lookup by raw index
- `swapRemove`

That means the implementation is a dense packed array, not a handle-bearing
slot container.

## Relevant rules

### `design_and_safety.md`

- choose the simplest implementation that reaches the best end state;
- avoid hidden footguns and duplicated machinery;
- keep hot or data-plane paths allocation-free once capacity is reserved;
- do not use a more complex abstraction when the domain does not require it.

### `performance.md`

- separate control-plane reservation from hot-loop data-plane mutation;
- prefer dense, predictable memory access;
- batch work before the hot path instead of paying per-element setup cost.

### `testing_and_docs.md`

- source comments are Tier 1 documentation and must match behavior exactly;
- subtle contracts need deterministic tests at the package level.

## Needed use cases

### Strong fits

- dense contiguous iteration
- explicit swap-remove when order does not matter
- reusable packed buffers with clear-and-reuse
- allocator or budget-aware growth during setup
- higher-layer ownership of reverse mapping or relocation bookkeeping

### Weak fits

- stable external references
- stale-handle detection
- entity or archetype semantics
- implicit side-index maintenance

Those weak-fit cases already point at `Handle`, `IndexPool`, `SlotMap`, or the
future `static_ecs` package.

## Options considered

### Option A: keep the implementation and fix the docs

Pros:

- simplest and most honest correction
- aligns with the current code and tests
- avoids duplicating handle lifecycle logic already present elsewhere
- preserves a useful packed-array primitive for data-oriented callers

Cons:

- still needs production-grade API review so it is not just a thin wrapper with
  missing control surfaces

### Option B: redesign `dense_array` into a handle-bearing container

Pros:

- would make the old docs true

Cons:

- duplicates `Handle` / `IndexPool` / `SlotMap` semantics
- pushes complexity into the wrong type
- weakens the package boundary between generic packed storage and ECS or
  handle-oriented storage
- does not satisfy the "simplest best end state" rule

### Option C: replace `dense_array` entirely with an ECS-oriented type

Pros:

- might help future `static_ecs`

Cons:

- wrong package ownership
- imports world or archetype semantics into a generic collections package
- collapses a reusable primitive into a domain-specific abstraction

## Recommendation

Choose Option A.

Freeze `dense_array` as:

- a dense, contiguous, index-addressed array
- with explicit swap-remove semantics
- with explicit index invalidation under swap-remove
- with allocator or budget-aware growth at setup boundaries
- with no handle semantics

If a generation-backed dense storage surface is needed later, add a new type
with a new name rather than silently changing `dense_array`.

## Production-grade target surface

### Must keep

- `init`
- `deinit`
- `len`
- mutable dense iteration
- append returning index
- raw index lookup
- swap-remove deletion

### Likely additions to review

- `itemsConst`
- `capacity`
- clear-and-reuse
- explicit reserve or ensure-capacity surface

These are good candidates because they improve caller control without changing
the type's core identity.

### Review carefully before adding

- no-allocation fast path append
- relocation-aware swap-remove result

These may be useful, especially for higher layers that maintain reverse maps,
but they should only be added if the API stays simple and the use case cannot
remain caller-owned without awkwardness.

### Reject

- stable-handle API
- generation counters
- implicit reverse-map or slot bookkeeping
- ECS-specific names or world semantics

## Ideal contract wording

`DenseArray(T)` is a dense packed array for contiguous iteration and O(1)
swap-remove deletion. It returns raw indices, and those indices are invalidated
when a removal moves the last element into a vacated slot. Callers that need
stable external references or reverse mapping must own that policy explicitly.

## Proof obligations

Once the contract is frozen, direct integration proof should cover:

- append and index visibility
- swap-remove density and moved-element behavior
- invalid index rejection
- clear-and-reuse if exposed
- reserve or budget boundary behavior if exposed
- const and mutable iteration visibility

## Implementation order

1. Correct docs to match the frozen contract.
2. Review and freeze the minimal production-grade API additions.
3. Add the direct package-owned proofs required by the accepted surface.
4. Only then consider whether a benchmark slice is justified.

## Boundary with `static_ecs`

`dense_array` remains a generic packed-array primitive.

The following stay out of this type and belong in `static_ecs` or another
purpose-built surface:

- entity-to-row maps
- archetype chunk storage
- stable entity references
- structural command buffering
- world-owned relocation policy
