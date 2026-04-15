# `static_ecs` cleanup follow-up

Scope: validated resource-cleanup hardening for the world-local typed ECS
package.

Status: follow-up closed on 2026-04-05. The validated leak class is fixed, and
the package now directly proves the affected failure paths under bounded budget
pressure.

## Validated issue scope

- `ArchetypeStore.ensureChunkWithSpace()` previously constructed a
  `ChunkRecord` before appending it to the owning chunk vector, but it did not
  clean that record up if `append()` failed. That could leak the chunk-owned
  entity buffer plus its budget reservation.
- `World.init()` previously constructed `EntityPool` before `ArchetypeStore`
  without releasing the already-initialized pool if `ArchetypeStore.init()`
  failed.
- Review follow-up narrowed one earlier claim: `ArchetypeStore.ensureArchetype()`
  now also has symmetric rollback, but the validated leak class was the
  `ChunkRecord` path. `ArchetypeRecord.init()` did not own heap or budget state
  before append in the current implementation.

## Implemented fixes

- `src/ecs/archetype_store.zig` now rolls back newly created archetype and
  chunk records locally before append-failure errors escape.
- `src/ecs/world.zig` now releases `EntityPool` on `World.init()` failure after
  partial initialization.
- `src/ecs/archetype_store.zig` now directly proves that a budget-limited
  first-chunk append failure leaves the live store budget accounting unchanged
  and deinitializes to zero retained usage.
- `src/ecs/world.zig` now directly proves that a budget-limited
  `ArchetypeStore.init()` failure does not leave `EntityPool` reservations
  behind.

## Proof posture

- The package-owned deterministic proof map now includes direct cleanup-path
  coverage instead of relying on code review memory for constructor rollback.
- The existing `testing.model` command-buffer sequence slice remains unchanged;
  the new bug class was better served by direct bounded budget fixtures.

## Current posture

- `static_ecs` remains the same world-local typed-first package slice: no
  runtime-erased queries, import/export, side indexes, scheduler ownership, or
  benchmark admission were added in this follow-up.
- The cleanup hardening stays package-local and consumes the existing
  `static_memory` / `static_collections` contracts without reopening those
  package boundaries.

## Reopen triggers

- Reopen if another partial-init or append-failure path in `static_ecs` is
  found to retain budget or heap state after the error escapes.
- Reopen if allocator-failure coverage becomes meaningfully distinct from the
  current bounded-budget proof and names a separate bug class.
