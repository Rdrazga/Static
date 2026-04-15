# `static_collections` review remediation plan — 2026-04-03

Scope: address all validated issues from the 2026-04-03 critical review of the
`static_collections` package. Tasks are ordered by dependency and priority
(correctness first, then rule alignment, then API hardening, then documentation).

Validation command: `zig build test`
Docs validation: `zig build docs-lint`

## Review summary

The review found 19 valid issues, 4 partially valid, and 2 invalid across
correctness, API design, performance, structural design, and coding-rule
compliance. This plan addresses every valid and partially-valid finding.

Items are grouped into slices that can each be landed as a single commit and
validated independently.

---

## Slice 1 — Correctness fixes

These are bugs or contract violations that should be fixed before any API work.

### 1.1 Fix `DenseArray` doc comment (review 1.1)

The module header claims stable `Handle` identifiers and generation counters.
The implementation is an index-addressed dense packed array with swap-remove.

Action: rewrite the `//!` header of `dense_array.zig` lines 1-7 to match the
frozen contract from `docs/sketches/dense_array_end_state_2026-04-02.md`:

> Dense array: a packed, gap-free array with O(1) swap-remove deletion.
> Indices returned by `append` are positional and are invalidated when
> `swapRemove` moves the last element into a vacated slot. Callers that
> need stable external references must own that policy explicitly.

Done when: `dense_array.zig` header no longer mentions handles or generations,
and `zig build docs-lint` passes.

### 1.2 Fix `IndexPool.assertBasicInvariants` O(n^2) cost (review 1.2)

The free-stack duplicate check and the occupied-to-free cross-check are both
O(n^2). Every public method calls `assertBasicInvariants`, making debug builds
O(n^2) per operation.

Action: replace the two quadratic scan loops with a single O(n) pass using a
temporary stack-local or comptime bitset (the pool is bounded by `slots_max`
which is `u32`, and the occupied array already exists). Approach:

1. First loop: walk `free_stack[0..free_len]`, assert each index is in-bounds
   and not occupied. Use the existing `occupied` slice as the uniqueness check
   (each free slot must have `occupied[slot] == false`; if two free-stack
   entries pointed to the same slot, the second would find `occupied[slot]`
   already false but we'd count more free entries than unoccupied slots).
2. Second loop: walk all slots, count unoccupied, assert the count equals
   `free_len`. This is O(n) not O(n*free_len).
3. Drop the inner duplicate-scan loop entirely — the count-match between
   unoccupied slots and free_len, plus the in-bounds and not-occupied checks,
   is sufficient to prove the free stack is a valid permutation of unoccupied
   indices.

Done when: `assertBasicInvariants` is O(n) in `slots_max`, all existing
IndexPool tests pass under `zig build test`, and the integration model tests
still pass.

### 1.3 Fix `nextPow2` dead-code / debug-release divergence (review 1.5)

`assert(n > 0)` on line 328 panics in debug when n==0, but the `if (n == 0)`
fallback on line 329 activates in release. The comment acknowledges the tension.

Action: remove the `if (n == 0) return 1;` fallback and keep only the assert.
All callers already guarantee n > 0 (init enforces `>= 8`, rehash passes
`cap * 2`). The assert is the contract; the dead fallback is misleading.

Done when: `nextPow2` has no unreachable branch, and `zig build test` passes.

---

## Slice 2 — Rule alignment: receiver conventions and struct layout

These changes are mechanical and safe to batch.

### 2.1 Fix `Vec` by-value receivers (review 2.3, rule R1)

`Vec.len`, `Vec.capacity`, `Vec.items`, and `Vec.assertInvariants` take
`self: Self` (by value, ~52 bytes). The coding rule says >16 bytes should be
`*const`. Every other collection in the package already uses `*const Self` for
read-only methods.

Action: change the four functions from `self: Self` to `self: *const Self`.
Update `assertInvariants` to `*const Self` as well (it is called from mutable
methods, which can coerce `*Self` to `*const Self`).

Done when: no `self: Self` receivers remain in `vec.zig`, and `zig build test`
passes.

### 2.2 Normalize struct field ordering (rule R4)

`SlotMap`, `FlatHashMap`, and `Vec` inner structs place types (`Config`,
`Entry`, `Element`, `Slot`) before fields. The coding rule says fields first,
then types, then methods.

Action: for generic container structs, document an explicit exception in this
plan: associated types (`Config`, `Element`, `Entry`, `Slot`) that are required
to understand the field declarations may appear before fields. This matches the
current layout and is more readable for parameterized types.

Rationale: the reader needs to see `Config`, `Entry`, and `Element` definitions
before the field list makes sense. Forcing fields first would require forward
references or split definitions that hurt readability.

Done when: this exception is recorded here. No code change required — the
current ordering is the intentional convention for this package.

---

## Slice 3 — API completions

### 3.1 Add `clear` to `Vec` (review 2.1)

`Vec` has no way to reset length without deinit/reinit. `FixedVec` already has
`clear`. Budget-aware callers need to keep their reserved capacity while
resetting the logical length.

Action: add `pub fn clear(self: *Self) void` that sets `self.storage.items.len = 0`
(via `self.storage.clearRetainingCapacity()`). Budget reservation and backing
capacity are unchanged. Assert pre/postconditions.

Done when: `Vec.clear` exists, unit test confirms `len() == 0` and
`capacity()` unchanged after clear, budget.used() unchanged, `zig build test`
passes.

### 3.2 Add `clear` to `DenseArray` (review 2.2)

Same gap as Vec. DenseArray wraps Vec and should expose clear.

Action: add `pub fn clear(self: *Self) void` delegating to `self.data.clear()`.
Assert postconditions.

Done when: `DenseArray.clear` exists with unit test, `zig build test` passes.

### 3.3 Add optional budget to remaining heap-allocating collections (review 2.3 / R3)

6 collections heap-allocate but lack budget support: `FlatHashMap`, `SlotMap`,
`IndexPool`, `SortedVecMap`, `SparseSet`, `BitSet`.

As a general-purpose library, budgets should be opt-in (`?*memory.budget.Budget = null`
in Config), not mandatory. Callers who don't need budgets pass `null` and pay
nothing.

Action for each collection, in priority order:

1. **`FlatHashMap`**: add `budget: ?*memory.budget.Budget = null` to Config.
   Reserve on alloc in `init` and `rehash`, release on `deinit` and before
   freeing old arrays in `rehash`. Track `reserved_bytes: usize` to know how
   much to release.
2. **`SlotMap`**: add budget to Config. Reserve when `slots` grows via
   `append`, release on `deinit`.
3. **`SortedVecMap`**: add budget to Config. Reserve when `entries` grows,
   release on `deinit`.
4. **`IndexPool`**: add budget to Config. Reserve the three arrays at `init`,
   release on `deinit`. IndexPool is fixed-capacity so this is init-time only.
5. **`SparseSet`**: add budget to Config. Reserve sparse array at init and
   dense array on growth, release both on deinit.
6. **`BitSet`**: add budget to Config. Reserve word array at init, release on
   deinit.

Constraint: budget integration must not change the non-budget code path. When
`budget == null`, the collection behaves identically to today.

Done when: all 6 collections accept an optional budget, unit tests confirm
budget.used() returns to 0 after deinit, existing tests still pass,
`zig build test` passes.

### 3.4 Add pre-allocation path to `SparseSet` dense array (footgun F4)

`SparseSet.insert` can fail with `OutOfMemory` even for in-universe values
because the dense array grows dynamically.

Action: add `ensureDenseCapacity(self: *SparseSet, count: usize) Error!void`
that pre-allocates the dense backing array. Callers who need allocation-free
inserts after setup can call this during init.

Done when: `ensureDenseCapacity` exists, test confirms insert after
pre-allocation does not allocate, `zig build test` passes.

### 3.5 Add pre-allocation path to `SmallVec` spill (review 3.1 / footgun F6)

`SmallVec` has no way to pre-allocate the spill `Vec`. Callers who know they
will exceed inline capacity cannot avoid the surprise allocation.

Action: add `ensureCapacity(self: *Self, n: usize) Error!void` that triggers
spill and reserves capacity if `n > InlineN`. If already spilled, delegates to
`spill.ensureCapacity`.

Done when: `SmallVec.ensureCapacity` exists, test confirms no allocation on
append after pre-reserve, `zig build test` passes.

---

## Slice 4 — Consistency and safety hardening

### 4.1 Fix `BitSet` API asymmetry (review 2.5)

`set`/`clear` return `error.InvalidInput` for OOB, but `isSet` returns `false`.
Callers may check `isSet`, get `false`, then fail on `set`.

Action: change `isSet` to return `Error!bool`. OOB returns `error.InvalidInput`.
Update all call sites and tests.

Done when: `BitSet.isSet` and `FixedBitSet.isSet` return `Error!bool`,
tests updated, `zig build test` passes.

### 4.2 Fix `SparseSet.remove` return type (review 2.6)

Every other collection returns an error for not-found removal. `SparseSet`
returns `bool`.

Action: change `remove` to return `error{InvalidInput}!void`. Return
`error.InvalidInput` when the value is absent. Update all call sites and tests.

Done when: `SparseSet.remove` returns an error union, tests updated,
`zig build test` passes.

---

## Slice 5 — Performance improvements

### 5.1 Optimize `SmallVec` spill migration (review 3.1)

The spill transition copies inline items one-by-one via `spill.append()`, each
hitting Vec's invariant checks and capacity logic.

Action: after initializing the spill Vec with sufficient capacity, replace the
per-item append loop with:

```zig
@memcpy(spill.storage.items.ptr[0..self.inline_len], self.inline_items[0..self.inline_len]);
spill.storage.items.len = self.inline_len;
```

Then append the new value. This avoids N redundant invariant checks during
migration.

Constraint: only do this if the Vec exposes a way to bulk-set length after
memcpy, or use `appendSliceAssumeCapacity` / direct storage manipulation.
If Vec's encapsulation makes this awkward, keep the loop but add a code comment
explaining the tradeoff.

Done when: spill migration uses bulk copy where possible, existing tests pass,
`zig build test` passes.

### 5.2 Eliminate redundant write in `SortedVecMap.put` (review 3.3)

The append-then-shift pattern writes the entry at the tail, memmoves over it,
then writes again at the insertion point.

Action: replace with direct memmove-then-write:

1. `ensureUnusedCapacity(1)` (already present).
2. Directly set `self.entries.items.len += 1` to extend the slice.
3. `@memmove` elements in `[index+1..new_len]` from `[index..old_len]`.
4. Write the new entry at `index`.

This removes one redundant write and avoids writing undefined-ish data that
the memmove immediately overwrites.

Done when: `SortedVecMap.put` uses direct shift, all sorted_vec_map tests pass,
`zig build test` passes.

---

## Slice 6 — Documentation: footgun warnings

These are behaviors that should exist for flexibility but need explicit
documentation so callers understand the tradeoffs.

### 6.1 Document `DenseArray.swapRemove` index invalidation (footgun F1)

Action: add a `///` doc comment on `swapRemove` stating that the last element
moves to fill the gap, invalidating the index that previously referred to the
last element. Consider whether `swapRemove` should return a struct with both
the removed value and the index of the relocated element (or `null` if the
removed element was the last). Record the accept/reject decision here before
implementing.

Decision: defer the return-type change to the `DenseArray surface hardening`
task (existing plan item 5). For now, document the invalidation behavior.

Done when: `swapRemove` has a doc comment explaining index invalidation.

### 6.2 Document `FlatHashMap` padding-dependent hashing (footgun F2)

Action: add a `///` doc comment on `FlatHashMap` warning that the default hash
path uses `std.mem.asBytes(&key)`, which includes struct padding. Composite key
types with padding must provide a custom `Ctx.hash`. Consider adding a comptime
check that emits `@compileError` when `K` has padding and no `Ctx.hash` is
provided (detectable via field-size sum vs `@sizeOf`).

Done when: doc comment exists on `FlatHashMap` warning about padding, and
either a comptime guard is added or a reject decision is recorded here.

### 6.3 Document `SlotMap` generation wrap-around (footgun F3)

Action: add a `///` doc comment on `SlotMap` noting the theoretical ABA window
after 2^32 generation cycles on a single slot. This is a known limitation of
generational handles, not a bug.

Done when: doc comment exists on `SlotMap` or `remove` mentioning the wrap.

### 6.4 Document `SparseSet.insert` allocation (footgun F4)

Action: add a `///` doc comment on `insert` stating it may allocate and fail
with `OutOfMemory` despite the value being in-universe. Reference
`ensureDenseCapacity` (from slice 3.4) as the pre-allocation path.

Done when: doc comment exists on `insert`.

### 6.5 Document `MinHeap` index invalidation and `setIndex` requirement (footgun F5)

Action: change the `///` doc comment on `updateAt` and `removeAt` to state that
indices are invalidated by any mutation. Change the `Ctx` doc to state that
`setIndex` is **required** (not optional) for correct use of `updateAt` and
`removeAt`. Without it, callers have no way to track live indices.

Done when: doc comments updated on `updateAt`, `removeAt`, and the `Ctx`
description in the module header.

### 6.6 Document `SmallVec` one-way spill (footgun F6)

Action: add a `///` doc comment on `SmallVec` stating that spill is permanent.
Once heap-allocated, the SmallVec remains heap-backed regardless of subsequent
element count. Callers who need to reclaim memory must `deinit` and
reconstruct.

Done when: doc comment exists on `SmallVec` module header or the struct.

---

## Slice 7 — Assertion minimum and negative-space style

### 7.1 Record assertion convention for trivial accessors (rule R6)

Several simple getters (`len`, `capacity`, `items`, `contains`, `items`) have
only one assertion site (the `assertInvariants()` call).

Decision: `assertInvariants()` satisfies the 2-assertion minimum for trivial
accessors because it bundles both structural preconditions and postconditions
internally. Explicit pre/post pairs are reserved for functions with branching
logic, mutation, or non-obvious return values.

Action: record this convention here. No code change needed for trivial
accessors. For non-trivial functions that currently rely only on
`assertInvariants`, audit and add explicit postcondition asserts where the
function's return value or mutation effect is not self-evident from the
invariant check alone.

Done when: this decision is recorded. Spot-check that non-trivial public
methods (e.g., `swapRemove`, `put`, `remove`, `rehash`) have explicit
postcondition asserts beyond `assertInvariants` — they already do.

### 7.2 Add explicit `else` or negative-space asserts where missing (rule R9)

The coding rule says consider whether every `if` needs an `else`. A few
functions have early-return `if` branches without explicit negative-space
handling.

Action: audit public methods for bare `if (condition) return ...;` without a
corresponding else or assert. Add `else` blocks or negative-space assertions
where the implicit fall-through is non-obvious. Do not add them where the
fall-through is self-evident (e.g., `if (len == 0) return null;` — the
negative space is "len > 0, proceed").

Done when: audit complete, obvious gaps addressed, `zig build test` passes.

---

## Deferred / out of scope

The following findings are acknowledged but not addressed in this plan:

| Item | Reason deferred |
| --- | --- |
| `usize` for internal counters (R2) | For a general-purpose library, `usize` is the platform-correct type for logical lengths that interact with slice indexing. Using `u32` would require pervasive narrowing casts. The rule's intent (avoid platform-dependent behavior) is satisfied because collection lengths are bounded by addressable memory. |
| Linear probing clustering (review 3.2) | Valid observation but debatable severity. The 70% default load factor mitigates primary clustering. Changing the probing strategy is a larger design decision that belongs in the benchmark definition task (existing plan item 8), not a review remediation. |
| `Handle.invalid()` as function vs constant (review 5.3) | Minor style preference. The function contains an assert that validates the sentinel, which is marginally useful as documentation. Not worth a code change. |
| Integration test style (review 4.5) | Deterministic scenario tables are an intentional testing style. Property-based supplements belong in the testing adoption plan, not here. |
| `SmallVec.inline_len` stale after spill (review 5.1) | By design. The invariant check documents and depends on this value being frozen at the migration point. Changing it would break the invariant assertion. |
| Iteration support on `FlatHashMap`/`SlotMap` (review 2.7) | Valid gap but additive feature work. Belongs in a separate API expansion plan after the current remediation is complete. |
| `Vec.ensureCapacity` silent geometric-to-exact fallback (R7) | Intentional amortization strategy. The budget-aware growth path degrades gracefully by design. Documenting this behavior is sufficient — see footgun documentation in slice 6. |

---

## Execution order and parallelism

- Slices 1, 2, and 6 have no dependencies and can proceed in parallel.
- Slice 3 depends on slice 1.1 (DenseArray doc fix before API additions).
- Slice 4 depends on nothing but should follow slice 3 to avoid churn.
- Slice 5 depends on nothing but should follow slice 3.
- Slice 7 depends on nothing and can proceed in parallel with anything.

Recommended sequence: 1 → 2 + 6 (parallel) → 3 → 4 → 5 → 7.
