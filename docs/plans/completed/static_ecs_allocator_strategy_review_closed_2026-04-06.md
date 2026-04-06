# `static_ecs` allocator strategy review

Scope: close the 2026-04-06 allocator-boundary review opened during the ECS
dependency audit.

Status: review closed on 2026-04-06. The current durable boundary remains
allocator-agnostic and caller-supplied, and the package now owns a canonical
benchmark owner that measures that choice directly.

## Reviewed boundary

- `World`, `ArchetypeStore`, `Chunk`, and `CommandBuffer` already accept a
  caller allocator and use `static_memory` only where the current package
  boundary intends to, primarily through `Budget`.
- The main transient-allocation question was the typed bundle helper path in
  `World.spawnBundle()` / `insertBundle()`, which still allocates encoded
  scratch through the caller allocator while the direct encoded route avoids
  that per-call scratch.
- No validated issue justified internalizing slab/pool ownership inside
  `static_ecs` itself.

## Implemented outcome

- The package keeps the caller-supplied allocator boundary rather than
  hard-wiring `static_memory` allocator policy into ECS internals.
- A new benchmark owner,
  [allocator_strategy_baselines.zig](/C:/Users/ryan/Desktop/Forbin%20Solutions/Library%20Dev/static/packages/static_ecs/benchmarks/allocator_strategy_baselines.zig),
  now compares:
  `typed_spawn_despawn_page_allocator`,
  `typed_spawn_despawn_slab_allocator`,
  `encoded_spawn_despawn_page_allocator`, and
  `encoded_spawn_despawn_slab_allocator`.
- Root bench wiring now admits that owner.
- [root.zig](/C:/Users/ryan/Desktop/Forbin%20Solutions/Library%20Dev/static/packages/static_ecs/src/root.zig)
  now re-exports the existing bundle codec module so the package-owned
  benchmark can exercise the direct encoded path without duplicating encoding
  logic.
- Package and repo docs now describe the caller-supplied allocator posture and
  the new admitted benchmark surface.

## Proof posture

- `zig build check`
- `zig build allocator_strategy_baselines`
- `zig build bench`
- `zig build docs-lint`

## Current posture

- The current measured evidence favors keeping allocator policy outside ECS:
  callers can use `std.heap.page_allocator`, a slab-backed allocator, or other
  strategies without the ECS package itself taking ownership of that decision.
- The admitted benchmark owner now makes future allocator-boundary changes
  reviewable instead of speculative.

## Reopen triggers

- Reopen if ECS starts owning allocator-specific policy internally.
- Reopen if another typed helper path introduces meaningful transient
  allocation that the current owner does not capture.
