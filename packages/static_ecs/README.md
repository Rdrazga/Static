# `static_ecs`

World-local typed ECS building blocks for the `static` workspace.

## Current status

- The root workspace build is the supported entry point; package-local `zig build`
  is not supported.
- The current implemented surface now also includes `ArchetypeKey` and a first
  bounded `Chunk(comptime Components)` layout for runtime archetype subsets of a
  typed component universe.
- The current implemented structural layer now also includes
  `ArchetypeStore(comptime Components)` plus `World`-level spawn, despawn, and
  explicit archetype transition support with ECS-owned row relocation.
- Direct `ArchetypeStore` usage now also mirrors `World` on
  `components_per_archetype_max` validation, rejects occupied-slot aliasing
  before mutation, and directly proves chunk/archetype swap reindexing.
- The current hot-path layer now also includes typed query descriptors and a
  chunk-batch `View` over matching archetypes.
- The current control-plane layer now also includes a bounded
  `CommandBuffer(comptime Components)` plus typed `World.insert()` /
  `World.remove()` helpers so value-component additions stay initialized.
- The package now also owns a first `static_testing.testing.model` sequence
  proof for mixed command-buffer structural mutation over a bounded typed
  world.
- Runtime-erased queries, import/export, and spatial adapters remain deferred.
  The current reopen baseline now lives in
  `docs/plans/completed/static_ecs_cleanup_followup_closed_2026-04-05.md`.

## Main surfaces

- `src/root.zig` exports the package API.
- `src/ecs/world_config.zig` owns the explicit hard-bound configuration
  contract.
- `src/ecs/entity.zig` and `src/ecs/entity_pool.zig` own bounded identity
  allocation and stale-id rejection.
- `src/ecs/component_registry.zig` owns typed component-universe admission.
- `src/ecs/archetype_key.zig` owns deterministic runtime component-subset keys.
- `src/ecs/chunk.zig` owns bounded SoA column materialization for one
  archetype chunk.
- `src/ecs/archetype_store.zig` owns bounded archetype placement and ECS-owned
  row relocation, with direct config-bound validation parity, occupied-slot
  alias rejection before mutation, and raw value-adding archetype moves fenced
  behind explicit initialization requirements.
- `src/ecs/query.zig` owns typed query descriptors and matching semantics.
- `src/ecs/view.zig` owns typed chunk-batch iteration over matching archetypes.
- `src/ecs/command_buffer.zig` owns bounded structural staging and
  deterministic apply order.
- `src/ecs/world.zig` owns the world-local typed ECS shell on top of that
  structural layer, including typed insert/remove helpers and command-buffer
  initialization.

## Validation

- `zig build check`
- `zig build test`
- `zig build docs-lint`

## Key paths

- `tests/integration/root.zig` wires the package-level deterministic
  integration suite, including the package-owned `testing.model` command-buffer
  sequence proof.
- `docs/plans/completed/static_ecs_cleanup_followup_closed_2026-04-05.md`
  records the current closure posture and reopen triggers.
