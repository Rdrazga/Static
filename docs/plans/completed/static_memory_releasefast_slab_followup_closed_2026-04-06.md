# `static_memory` ReleaseFast slab follow-up

Scope: close the 2026-04-06 reopen that validated slab `ReleaseFast`
invariant-scan cost, linear free-path routing, and missing slab benchmark
coverage.

Status: follow-up closed on 2026-04-06. `Slab` no longer pays full invariant
walk cost in non-runtime-safety builds, the free path no longer linearly scans
classes, and the admitted benchmark owner now covers slab routing and fallback
behavior beside the existing pool case.

## Validated issue scope

- `Slab.alloc()` / `free()` called `assertInvariants()` unconditionally, and
  the helper still walked every class even when runtime safety was off.
- `Slab.free()` routed pointers through a linear `classByPtr()` scan over all
  classes.
- The canonical `pool_alloc_free` benchmark owner exposed only the pool case,
  leaving slab class-routing and fallback behavior under-observed.

## Implemented fixes

- [slab.zig](/C:/Users/ryan/Desktop/Forbin%20Solutions/Library%20Dev/static/packages/static_memory/src/memory/slab.zig)
  now returns early from the full invariant walk when
  `std.debug.runtime_safety` is off while preserving the complete checks in
  `Debug` and `ReleaseSafe`.
- `Slab` now stores an address-ordered class index and routes `free()` through
  a bounded binary search instead of the old linear class scan.
- The same slab file now includes a direct three-class routing regression test
  so mixed-class free resolution stays locked down.
- [pool_alloc_free.zig](/C:/Users/ryan/Desktop/Forbin%20Solutions/Library%20Dev/static/packages/static_memory/benchmarks/pool_alloc_free.zig)
  now owns three canonical review cases:
  `alloc_free_cycle`, `slab_class_alloc_free_cycle`, and
  `slab_fallback_alloc_free_cycle`.
- Package docs now describe the address-ordered slab routing contract and the
  widened admitted benchmark surface.

## Proof posture

- `zig build check`
- `zig build test --summary all`
- `zig build pool_alloc_free`
- `zig build docs-lint`

## Current posture

- `static_memory` now keeps the slab free path API-neutral while removing the
  validated O(class_count) routing cost from the hot path.
- The canonical admitted memory benchmark owner now makes slab class-routing
  and fallback timing reviewable through the shared `baseline.zon` plus
  `history.binlog` workflow instead of leaving them as untracked local probes.

## Reopen triggers

- Reopen if slab free routing stops being bounded by the address-ordered class
  index.
- Reopen if full slab invariant walks start executing again in
  `ReleaseFast`-style builds.
- Reopen if another slab hot path needs a separate canonical benchmark owner
  beyond the admitted alloc/free cases.
