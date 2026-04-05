# `static_ecs` package guide
Start here when you need to review, validate, or extend `static_ecs`.

## Source of truth

- `README.md` for the package entry point and commands.
- `src/root.zig` for the exported surface.
- `tests/integration/root.zig` for the package-level deterministic regression
  surface.
- `docs/plans/completed/static_ecs_cleanup_followup_closed_2026-04-05.md` for the
  current closure posture and reopen triggers.
- `docs/plans/active/workspace_operations.md` for workspace priority and
  sequencing.
- `docs/architecture.md` for package boundaries and dependency direction.

## Supported commands

- `zig build check`
- `zig build test`
- `zig build docs-lint`

## Working agreements

- Use the root `build.zig` as the supported validation surface.
- Keep the first implementation slice world-local and typed-first.
- Do not pull transport, scheduler, persistence, replication, GPU, or UI
  ownership into the package while the world-local core is still in flight.
- Keep row relocation, archetype ownership, and typed query semantics in this
  package rather than pushing them into lower generic packages.
- Keep hard bounds explicit in `WorldConfig`; do not hide them behind a generic
  bounded-mode flag.
- Keep the exported direct `ArchetypeStore` surface truthful about config
  bounds and occupied-slot rejection instead of relying on `World` as the only
  enforcing wrapper.

## Package map

- `src/ecs/world_config.zig`: hard-bound world configuration.
- `src/ecs/entity.zig`: ECS-owned entity identity value type.
- `src/ecs/entity_pool.zig`: bounded entity allocation and stale-id rejection.
- `src/ecs/component_registry.zig`: typed component-universe admission.
- `src/ecs/archetype_key.zig`: deterministic component-subset identity.
- `src/ecs/chunk.zig`: bounded SoA chunk layout for one archetype subset.
- `src/ecs/archetype_store.zig`: bounded archetype ownership, placement, and
  row relocation, with direct config-bound validation parity, occupied-slot
  alias rejection before mutation, and raw value-adding archetype moves
  rejected until the caller supplies typed initialization.
- `src/ecs/query.zig`: typed query descriptor validation and matching.
- `src/ecs/view.zig`: typed chunk-batch hot-path iteration.
- `src/ecs/command_buffer.zig`: bounded structural staging and deterministic
  apply order.
- `src/ecs/world.zig`: world-local typed ECS shell over the structural store,
  including typed insert/remove helpers and command-buffer initialization.
- `tests/integration/`: package-level deterministic structural coverage.
  The package now also uses `static_testing.testing.model` here for mixed
  command-buffer structural sequences.

## Change checklist

- Update `README.md`, `AGENTS.md`, and the relevant plan or closure record
  when package behavior or workflow changes.
- Extend `tests/integration/root.zig` when you add new first-class package
  integration coverage.
- Update root `README.md`, root `AGENTS.md`, and `docs/architecture.md` when
  package guidance or repository navigation changes.
