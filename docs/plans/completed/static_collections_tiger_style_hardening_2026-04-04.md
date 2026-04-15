# `static_collections` Tiger Style v3 hardening plan — 2026-04-04

Scope: address all validated findings from the 2026-04-04 full Tiger Style v3
review of the `static_collections` package.

Validation command: `zig build test`
Reference: `docs/reference/TigerStylev3.md`

**Status: all items complete.**

---

## Completed slices

### Slice 1 — Critical correctness fixes (ce34137)

- Fixed `BitOps.subsetOf` operator precedence bug.
- Refactored `IndexPool.assertFullInvariants` to not mutate live state.
- Zeroed tombstone entries in `FlatHashMap.clone` (buffer bleed fix).

### Slice 2 — Safety contract hardening (c74b41e)

- Added proof comments to all `catch unreachable` sites.
- Documented `rehash` errdefer + self-mutation invariant.
- Replaced `catch unreachable` with `catch-panic` in test `resetState` functions.
- Added iteration bound to unbounded test loop.

### Slice 3 — Eliminate direct ArrayListUnmanaged coupling (0e72cf1)

- Added `Vec.appendSliceAssumeCapacity` bulk-insert API.
- Refactored SmallVec spill paths to use the new API.
- Documented stdlib coupling in slot_map and sorted_vec_map clone functions.

### Slice 4 — Type discipline (45b80ec, closed)

Completed: `FixedVec` `len_value` narrowed from `usize` to `u32`.

Remaining items (4.1-4.3, 4.4-4.8) **closed without action**. Rationale:

This library provides building blocks for TigerStyle callers. The callers
themselves will use `u32` (or smaller) in their domain types and configure
collections with `u32` initial_capacity (already the config type for most
collections). The collection's public `len()` returning `usize` does not
hinder them — they narrow at their own domain boundary, which is where
TigerStyle says to narrow.

Narrowing the internal `len`/`capacity` fields and return types from `usize` to
`u32` would add ~30-40 `@intCast` calls at `std.ArrayListUnmanaged` boundaries.
Each cast is a potential panic site with no diagnostic context. The real capacity
bound is enforced by the budget system and the `u32` config types — not by the
index type.

The `usize` types are the natural interface between Zig's memory model and the
collection internals. Slice indexing, allocator calls, and ArrayListUnmanaged
all require `usize`. Matching that type eliminates cast noise without weakening
any safety property.

Future consideration: `FixedVec` and `SmallVec` inline lengths are bounded by
a comptime capacity and could use `std.math.IntFittingRange(0, N)` for optimal
struct packing when embedded in bulk (e.g., ECS component arrays). This is a
struct-packing optimization, not a safety concern, and can be evaluated if the
use case arises.

### Slice 5 — API and naming fixes (c5f57d5)

- Renamed `cfg` → `config` across 10 files.
- Fixed `sparse_set` error naming: init returns `InvalidConfig`, runtime
  operations keep `InvalidInput`.
- Removed redundant `error{NotFound} || Error` unions.
- Fixed `popMin`/`removeAt` value capture ordering (capture before invalidate).
- Moved free functions into `IndexPool` struct.

### Slice 6 — Assertion density and invariant quality (5bdb921)

- Raised assertion density to 2-per-function minimum across all collections.
- Removed dead and tautological assertions.
- Tightened binary search bound to logarithmic.
- Added missing `errdefer` in `IndexPool.clone`.

### Slice 7+8 — Comments, documentation, and style (dcbf051)

- Added `//!` module docs to all 13 integration test files.
- Converted bit_set section separators to sentence form.
- Added comptime recursion justification in flat_hash_map.
- Fixed small_vec assert alias inconsistency.
- Added comptime `usize >= 32 bits` assertion in bit_set.
- Added comptime `@sizeOf(T) > 0` pair assertion in dense_array.
- Removed redundant ReleaseFast guard in min_heap assertHeapInvariant.

### Slice 9 — Final items (20d7cbf)

- Removed `Config.budget = null` defaults from all Config structs across 10
  collection files. Updated all call sites in source, unit tests, integration
  tests, and downstream packages (static_queues, static_scheduling, static_io)
  to pass `.budget = null` explicitly.
- Used `@divFloor` in bit_set `wordsForBits`.
- Replaced manual budget cleanup in bit_set clone with `errdefer`.
- Split 9-way compound boolean in index_pool test `finish` into individual
  assertions.
- Added siftDown overflow assertion in min_heap.
- Extracted build.zig examples loop into `addExamples` helper.
- Added missing why-comments: slot_map clear free-list ordering, build.zig
  standalone limitation, dense_array clone purpose.

---

## Retracted items (not actionable)

1. **vec.zig struct ordering** — Zig comptime generics require type aliases
   before fields. Not a violation.
2. **vec.zig ensureCapacity function size** — 39 lines, within limit.
3. **small_vec.zig InlineN * 2 overflow as critical** — Comptime expression,
   caught at compile time.
4. **slot_map/sparse_set hot-path allocation as critical** — Documented design
   choice with pre-allocation API.
5. **Remaining usize → u32 narrowing (Slice 4)** — Config types + budget are
   the real bound mechanism. Internal usize matches stdlib API, adding casts
   would add noise without safety benefit.
