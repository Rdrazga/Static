# `static_ecs` package guide
Start here when you need to review, validate, or extend `static_ecs`.

## Source of truth

- `README.md` for the package entry point and commands.
- `src/root.zig` for the exported surface.
- `tests/integration/root.zig` for the package-level deterministic regression
  surface.
- `tests/compile_fail/build.zig` for the package-owned compile-contract fixture
  wiring.
- `benchmarks/` for the admitted ECS benchmark review workloads.
- `docs/plans/completed/static_ecs_performance_and_memory_followup_closed_2026-04-05.md`
  for the current fused bundle, bounded-storage, control-plane, and benchmark
  closure posture.
- `docs/plans/completed/static_ecs_cleanup_followup_closed_2026-04-05.md` for the
  last closed cleanup follow-up and its reopen triggers.
- `docs/plans/active/workspace_operations.md` for workspace priority and
  sequencing.
- `docs/architecture.md` for package boundaries and dependency direction.

## Supported commands

- `zig build check`
- `zig build test`
- `zig build bench`
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
- Keep bundle-oriented mutation truthful: when the caller already knows the
  final component set, use the fused bundle routes instead of rebuilding the
  same move through repeated scalar insertion.
- Keep control-plane bounds explicit in `WorldConfig`, including
  `command_buffer_payload_bytes_max` and `empty_chunk_retained_max`, and do not
  reintroduce dead cache or side-index config knobs without implementations in
  the same slice.

## Package map

- `src/ecs/world_config.zig`: hard-bound world configuration.
- `src/ecs/entity.zig`: ECS-owned entity identity value type.
- `src/ecs/entity_pool.zig`: bounded entity allocation and stale-id rejection.
- `src/ecs/component_registry.zig`: typed component-universe admission.
- `src/ecs/archetype_key.zig`: deterministic component-subset identity.
- `src/ecs/chunk.zig`: bounded SoA chunk layout for one archetype subset,
  compact active-column metadata, and single-backing allocation ownership.
- `src/ecs/archetype_store.zig`: bounded archetype ownership, placement, and
  row relocation, with direct config-bound validation parity, occupied-slot
  alias rejection before mutation, archetype and chunk fast paths, bounded
  empty-chunk reuse, and raw value-adding archetype moves rejected until the
  caller supplies typed initialization.
- `src/ecs/bundle_codec.zig`: deterministic bundle encoding for fused
  spawn/insert staging and apply.
- `src/ecs/query.zig`: typed query descriptor validation and matching.
- `src/ecs/view.zig`: borrowed typed chunk-batch hot-path iteration with
  fail-fast invalidation after structural mutation in runtime-safety builds.
- `src/ecs/command_buffer.zig`: bounded structural staging with separate entry
  and payload limits plus deterministic apply order.
- `src/ecs/world.zig`: world-local typed ECS shell over the structural store,
  including typed insert/remove helpers, fused bundle admission, and
  command-buffer initialization.
- `benchmarks/`: package-owned benchmark review workloads for chunk iteration,
  structural churn, and command-buffer apply throughput.
- `tests/integration/`: package-level deterministic structural coverage.
  The package now also uses `static_testing.testing.model` here for mixed
  command-buffer structural sequences.
- `tests/compile_fail/`: package-owned negative compile-contract fixtures for
  the main public generic rejection boundaries.

## Change checklist

- Update `README.md`, `AGENTS.md`, and the relevant plan or closure record
  when package behavior or workflow changes.
- Extend `tests/integration/root.zig` when you add new first-class package
  integration coverage.
- Extend `benchmarks/` and the root benchmark wiring together when you add a
  new stable ECS review workload.
- Update root `README.md`, root `AGENTS.md`, and `docs/architecture.md` when
  package guidance or repository navigation changes.
