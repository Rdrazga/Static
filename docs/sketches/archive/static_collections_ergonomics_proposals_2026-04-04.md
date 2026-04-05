# `static_collections` ergonomics proposals sketch - 2026-04-04

Scope: proposal set for the reopened `static_collections` ergonomics work.

This is not an execution plan. It was the design input for the now-closed
follow-up at
`docs/plans/completed/static_collections_ergonomics_followup_closed_2026-04-04.md`.

## Problem statement

`static_collections` is already solid for small scalar and POD-like workloads,
but several public surfaces become awkward as soon as downstream packages bring
larger domain keys, stateful comparators, or generic container code:

- lookup and comparator APIs are mostly by-value;
- iterator/view surfaces are inconsistent across container families; and
- callers still need container-specific reach-through for common read-only
  tasks that should be library-owned.

TigerStyle is useful here as a forcing function for API clarity, but it should
not be applied mechanically. A small `u32` key should stay cheap and natural.
The package should instead add explicit pathways for the large-key and
multi-domain cases.

## Design constraints

- Keep the bounded-storage and explicit-control-flow direction intact.
- Prefer additive APIs first so downstream packages can migrate incrementally.
- Avoid a trait-heavy abstraction layer while the package surface is still
  settling.
- Preserve straightforward small-scalar call sites.
- Make iterator and borrowed-key invalidation rules explicit in doc comments.

## Decision summary for the active plan

The active implementation plan should treat the following as the current
recommended direction unless a concrete code-level blocker appears:

1. Keep existing by-value small-key entry points, then add borrowed lookup and
   callback paths as additive APIs rather than replacing the current ones.
2. Support both by-value and borrowed callback signatures at comptime for the
   map and heap families that need comparators or hashing hooks.
3. Establish a minimum common public vocabulary directly in the package code
   instead of relying on docs-only conceptual parity.
4. Add explicit iterator or view surfaces for `FlatHashMap`,
   `SortedVecMap`, and `SlotMap` so downstream code stops reaching through
   internals.
5. Normalize error naming around constructor configuration, runtime invalid
   input, lookup miss, overflow, budget exhaustion, and allocator failure
   before landing broader ergonomics additions.

## Evaluation matrix

| Proposal area | Keep small-scalar ergonomics | Improves large-key ergonomics | Migration risk | Recommended |
| --- | --- | --- | --- | --- |
| Borrowed lookup APIs | Yes | Yes | Low | Yes |
| Pointer-only callback switch | No | Yes | High | No |
| Dual callback signatures | Yes | Yes | Medium | Yes |
| Docs-only parity | Yes | No | Low | No |
| Direct iterator/view APIs | Yes | Yes | Low | Yes |
| Full entry API now | Mixed | Mixed | High | No |

## Proposal set

### Proposal A: Borrow-friendly lookup and callback APIs

Problem:
`FlatHashMap`, `SortedVecMap`, and `MinHeap` still assume by-value keys or
callbacks, which is awkward for domain keys larger than 16 bytes and limits
stateful comparison strategies.

Option A1: additive borrowed-key APIs.

- Keep current by-value entry points.
- Add borrowed forms such as `getBorrowed`, `getConstBorrowed`,
  `containsBorrowed`, and `removeBorrowed`.
- Let the borrowed path use `*const K` or a dedicated borrowed-key type when
  the lookup key should not be copied.
- Extend context support so `Ctx.hash` / `Ctx.eql` may optionally accept
  borrowed forms without breaking the current small-key path.

Option A2: switch the primary callback shape to borrowed pointers everywhere.

- Make `Ctx.hash(*const K, seed)` and `Ctx.eql(*const K, *const K)` the main
  contract.
- Wrap small by-value callers through helper shims.

Option A3: dual-signature support at comptime.

- Accept either the current by-value callback signature or a pointer-based one.
- Resolve the chosen call path at comptime per `Ctx`.

Recommendation:
Choose A1 plus A3. Keep the existing small-key path stable, then add a
borrow-friendly path that larger downstream domains can opt into without
forcing every current call site to change.

Design note:
Prefer borrowed-key naming that makes the contract obvious at the call site.
`getBorrowed` / `getConstBorrowed` are clear for the first additive slice.
If the package later standardizes around a broader borrowed-key pattern, the
names can be collapsed then.

### Proposal B: Common public vocabulary across collection families

Problem:
The package is hard to use generically because similar containers expose
different read/reset/iteration surfaces.

Option B1: define a minimum common vocabulary and implement it directly.

Suggested baseline:

- slice-backed families: `len`, `capacity` when meaningful, `items`,
  `itemsConst`, `clear`;
- map/set families: `len`, `clear`, const iterator, mutable iterator when
  pointer mutation is safe;
- handle families: mutable and const iterator forms where both are practical.

Option B2: document a conceptual vocabulary only.

- Keep the code mostly unchanged.
- Rely on docs to explain the nearest equivalent per container.

Recommendation:
Choose B1. The package is still small enough that direct API parity beats a
doc-only explanation layer.

First bounded parity target:

- `SmallVec`: add `capacity`, `itemsConst`, and `clear` if the semantics are
  straightforward and do not hide the one-way spill contract.
- `SlotMap`: keep mutable iteration and add const iteration.
- `SortedVecMap` / `FlatHashMap`: add explicit iteration or ordered-view
  surfaces before adding higher-level entry helpers.

### Proposal C: Iterator and view surfaces for maps

Problem:
`FlatHashMap` and `SortedVecMap` still lack library-owned iteration/view APIs,
so tests and future downstream packages will keep reaching through internals.

Option C1: simple iterators returning pointers or entry views.

- `iterator()` for mutable access.
- `iteratorConst()` for read-only access.
- Yield lightweight entry views such as `{ key_ptr, value_ptr }` or
  `{ key, value_ptr }` depending on the container's storage guarantees.

Option C2: slice views for ordered containers only.

- `SortedVecMap.itemsConst()` can cheaply expose ordered entries.
- `FlatHashMap` still uses iterators because its occupied slots are sparse.

Recommendation:
Choose C1 for both map families, and optionally layer C2 on top of
`SortedVecMap` if a direct ordered slice is useful for downstream code.

Entry-view shape recommendation:

- `SortedVecMap.iteratorConst()` may safely return `{ key_ptr: *const K, value_ptr: *const V }`.
- `SortedVecMap.iterator()` may return mutable `value_ptr` plus const `key_ptr`;
  keys should stay immutable once sorted into the table.
- `FlatHashMap` should follow the same key-const, value-mutable split because
  mutating keys in place would break probing invariants.

### Proposal D: `SlotMap` const iteration

Problem:
`SlotMap` has a mutable iterator only, which is enough for some tests but not
for callers that need read-only handle/value traversal without opening
mutation.

Proposal:

- Keep the current mutable iterator.
- Add `iteratorConst()` yielding `{ handle, value_ptr: *const T }`.
- Document that any structural mutation still invalidates both iterator forms.

Recommendation:
Implement directly. This is low-risk and aligns the package with its own
read-only accessor split elsewhere.

### Proposal E: Error-contract normalization

Problem:
Several containers expose overlapping but not meaningfully distinct error
contracts.

Proposal:

- constructors use `InvalidConfig`;
- runtime bounds and domain mistakes use `InvalidInput`;
- stale handle or missing-key lookups/removals use `NotFound`;
- capacity arithmetic overflow uses `Overflow`;
- budget exhaustion stays `NoSpaceLeft`;
- allocator failure stays `OutOfMemory`.

Recommendation:
Adopt this as the package-level default unless a collection has a strong reason
to deviate and documents that reason explicitly.

Practical rule for this slice:

- invalid setup known before mutation: `InvalidConfig`
- invalid runtime argument or out-of-range member: `InvalidInput`
- missing existing entry or stale handle: `NotFound`
- arithmetic or capacity-limit overflow: `Overflow`
- budget refusal: `NoSpaceLeft`
- allocator failure after a valid request: `OutOfMemory`

### Proposal F: Optional entry-style mutation helpers

Problem:
Downstream callers may want fewer redundant searches when inserting or updating
maps, but a full entry API can easily add too much surface too early.

Option F1: small additive helpers.

- `getOrPut`
- `getOrPutAssumeCapacity`
- `removeOrNull`

Option F2: full entry API.

- explicit occupied/vacant entry types
- mutation through entry handles

Recommendation:
Do not pursue F2 in the near term. Reopen only for the low-debt F1 subset
after the borrow and iterator work settles, because those earlier slices were
the more urgent ergonomics blockers. The selected reopen is the bounded
`getOrPut` plus `removeOrNull` helper follow-up recorded in
`docs/plans/active/packages/static_collections_map_entry_helpers.md`.

## Collection-by-collection proposal targets

### `Vec` / `SmallVec`

- Keep the current slice-based ownership model.
- Normalize `capacity`, `itemsConst`, and `clear` availability where the
  semantics genuinely match.
- Do not hide the one-way spill contract in `SmallVec`; document it alongside
  any new parity surface.

### `SortedVecMap`

- Add iterator and const iterator surfaces first.
- Consider an ordered `itemsConst()` view only after the iterator surface lands
  and the key-immutability contract is explicit.
- Add borrowed lookup after the iterator work so the map has both generic-read
  and large-key pathways.

### `FlatHashMap`

- Add iterator and const iterator surfaces first.
- Keep keys immutable through the iterator API because in-place key mutation
  would break probing and stored-hash invariants.
- Add borrowed lookup and dual-signature `Ctx.hash` / `Ctx.eql` support in the
  next slice.

### `SlotMap`

- Add `iteratorConst()` as the first ergonomic parity change.
- Keep handle/value invalidation documentation close to both iterator entry
  types so callers understand the lifetime rules.

### `MinHeap`

- Preserve the current context-based design.
- Add dual-signature comparator support only if the implementation stays
  compile-time-resolved and does not add runtime dispatch or hidden state.

## Recommended implementation order

1. Normalize the error vocabulary so later APIs land on a stable contract.
2. Add const/mutable iterator parity and the minimum common public vocabulary.
3. Add borrowed-key and dual-signature callback support for the map and heap
   families.
4. Revisit entry-style helper additions only after the earlier slices prove
   useful in downstream packages.

## Post-closure decisions on the deferred options

These are no longer open-ended deferrals. Each item is either promoted into a
concrete follow-up or explicitly rejected until a concrete downstream trigger
appears.

### Planned next: small additive entry helpers

Decision:
Reopen for `getOrPut` and `removeOrNull` on `SortedVecMap` and `FlatHashMap`,
but stop short of occupied/vacant entry handles.

Reason:
This is the smallest helper set likely to prevent downstream wrapper churn and
“library missing a basic map feature” rejection, while keeping pointer
invalidation and mutation semantics understandable.

Status:
Implemented and closed in
`docs/plans/completed/static_collections_map_entry_helpers_closed_2026-04-04.md`.

### Not planned now: heterogeneous borrowed-key types distinct from `K`

Decision:
Do not open an implementation plan yet.

Reason:
The current `getBorrowed` / `getConstBorrowed` path plus dual callback
signatures already preserve an additive extension path. Generalizing to a
different borrowed key type now would force more comparator/hash adapter
surface, worse compile errors, and a larger test matrix before a concrete
downstream adopter has proven the need.

Trigger to reopen:
The first real container use case where stored `K` and lookup key type differ
materially, such as string-like owned-vs-slice lookup, normalized identifiers,
or projection-based composite lookups.

### Not planned now: trait-like or adapter-layer common abstraction

Decision:
Do not open an implementation plan yet.

Reason:
At the current package scale, direct surface parity is lower debt than adding
wrapper types or structural helper layers. A trait-like layer would create more
 compile-time plumbing and contract indirection than it would save.

Trigger to reopen:
Multiple downstream packages independently build the same generic
collection-adapter glue and the duplication is concrete enough to name.

### Not planned now: extra `static_testing` integration for the current ergonomics APIs

Decision:
Do not open an implementation plan yet.

Reason:
The landed ergonomics surfaces are still well covered by direct package tests.
Adding model or retained-failure machinery now would broaden maintenance cost
without a matching increase in defect-finding value.

Trigger to reopen:
Future work adds stateful entry handles, heterogeneous borrowed-key support, or
another API with more subtle invalidation and sequence behavior than the
current additive helpers.

## Rejected directions for now

- A package-wide trait or concept layer for every container.
  Reason: too much abstraction churn while the basic public vocabulary is still
  settling.
- A hard TigerStyle-only pointer transition for every key and callback.
  Reason: it would penalize the small-scalar use cases that this package already
  serves well.
- Collapsing all error sets into one shared package-wide enum.
  Reason: it would hide useful collection-specific failure contracts.
- Mutable-key iterator entry APIs for sorted or hashed maps.
  Reason: changing keys in place would silently violate ordering or probing
  invariants.
