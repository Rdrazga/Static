# `static_ecs` direct-surface hardening follow-up

Scope: reopened direct-surface hardening for malformed encoded-bundle
rejection, world/store admission truthfulness, and empty-chunk retention
accounting in the world-local typed ECS package.

Status: closed on 2026-04-05. The validated direct-surface bug classes are now
fixed, and the package owns direct deterministic proof for the hardened
contracts.

## Validated issue scope

- Public encoded-bundle admission previously trusted malformed bytes through
  `assert(...)` and `unreachable`, so truncated buffers, forged payload sizes,
  invalid component ids, duplicate ids, and unsorted ids did not fail through
  stable operating errors.
- `World.spawnBundleEncoded()` previously relied on a debug-only
  `EntityPool.contains()` assertion, so release builds could admit a fabricated
  free-slot entity into `ArchetypeStore` without the matching pool allocation.
- `ArchetypeStore` previously incremented `retained_empty_chunks` when an empty
  chunk was retained, but it did not clear that accounting when the retained
  chunk became live again, so later empty chunks could be reclaimed too early
  under `empty_chunk_retained_max`.

## Implemented fixes

- `src/ecs/bundle_codec.zig` now rejects malformed encoded bundles through
  stable operating errors:
  - truncated header and payload bounds now return `error.MalformedBundle`;
  - forged payload-size metadata now returns `error.MalformedBundle`;
  - invalid component ids now return `error.ComponentOutOfRange`;
  - duplicate and unsorted component ids now return
    `error.DuplicateComponent` and `error.UnsortedComponentIds`.
- `src/ecs/archetype_store.zig` now threads those decode errors through the
  direct encoded-bundle store surface instead of relying on parser assertions.
- `src/ecs/world.zig` now rejects direct encoded-bundle spawn on entities not
  allocated by the owning world through `error.EntityNotAllocated`, preserving
  `EntityPool` / `ArchetypeStore` lockstep in all build modes.
- `src/ecs/archetype_store.zig` now decrements retained-empty accounting when a
  retained empty chunk is reused, so `empty_chunk_retained_max` tracks actual
  retained empty chunks across repeated churn cycles.
- `packages/static_ecs/tests/integration/encoded_bundle_runtime.zig` now owns
  direct regression coverage for:
  - well-formed encoded bundle spawn and insert;
  - malformed encoded-bundle rejection across the public world route;
  - direct encoded spawn rejection for non-owned entities;
  - retain -> reuse -> empty-again chunk retention accounting.
- `packages/static_ecs/README.md` and `packages/static_ecs/AGENTS.md` now
  describe the hardened direct encoded-bundle contract and the new proof
  ownership.

## Proof posture

- The package now owns direct deterministic proof that the public
  encoded-bundle world APIs reject malformed bytes without mutating world
  state.
- The package now directly proves that direct encoded-bundle spawn cannot
  desynchronize the entity pool from the archetype store.
- The package now directly proves that bounded empty-chunk retention survives
  retained-chunk reuse rather than drifting after the first churn cycle.

## Current posture

- `static_ecs` remains the same world-local typed-first package slice: no
  runtime-erased queries, import/export, scheduler ownership, or spatial
  adapters were added in this follow-up.
- The direct encoded-bundle route remains public, but it is now a truthful
  operating-error surface instead of a caller-trusted assertion boundary.

## Reopen triggers

- Reopen if another encoded-bundle admission path bypasses the malformed-input
  validation or reintroduces assertion-only rejection.
- Reopen if a future direct world/store helper can again admit entities outside
  `EntityPool` ownership.
- Reopen if chunk-retention changes stop honoring
  `WorldConfig.empty_chunk_retained_max` across repeated reuse cycles.
