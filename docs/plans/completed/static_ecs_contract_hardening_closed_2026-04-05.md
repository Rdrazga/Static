# `static_ecs` contract-hardening follow-up

Scope: reopened direct-surface hardening and proof completion for the v1
world-local typed ECS package.

Status: closed on 2026-04-05. The exported direct `ArchetypeStore` surface now
matches the intended bounded contract more truthfully, and the highest-risk
swap-reindex structural paths now have direct deterministic proof.

## Implemented fixes

- `ArchetypeStore.init()` now rejects configs whose
  `components_per_archetype_max` understates the typed component universe,
  matching the direct meaning already enforced by `World.init()`.
- `ArchetypeStore.moveToArchetype()` now also rejects target archetype keys
  that exceed `components_per_archetype_max`, so later refactors cannot bypass
  the bound through the direct structural surface.
- `ArchetypeStore.spawn()` now rejects same-index, different-generation direct
  admission before any store mutation through a stable `EntitySlotOccupied`
  operating error.
- `src/ecs/archetype_store.zig` now has direct deterministic tests for:
  - direct-store config-bound parity with `World`;
  - occupied-slot alias rejection without location-map corruption;
  - empty-chunk swap reindexing after draining a non-tail chunk;
  - empty-archetype swap reindexing after removing a middle archetype.

## Proof posture

- The package-owned direct proof map now covers the two highest-risk internal
  relocation paths that were previously only nearby to invariants:
  chunk-vector swap after empty-chunk removal and archetype-vector swap after
  empty-archetype removal.
- The existing `testing.model` command-buffer sequence slice remains in place;
  no broader harness expansion was needed for this reopen because the missing
  gap was better served by direct deterministic structural fixtures.

## Current posture

- `static_ecs` remains the same world-local typed-first package slice: no
  runtime-erased queries, import/export, side indexes, scheduler ownership, or
  benchmark admission were added in this reopen.
- The direct exported `ArchetypeStore` surface is still a first-class package
  API and is no longer relying on `World`-only wrapper assumptions for these
  specific config and occupancy contracts.

## Reopen triggers

- Reopen if a new direct-store misuse class appears around row relocation,
  archetype transitions, or config-bound truthfulness.
- Reopen if runtime-erased queries, import/export, side indexes, or a stable
  ECS benchmark workload become concrete enough to justify a separate package
  slice.
