# `static_ecs`

World-local typed ECS building blocks for the `static` workspace.

## Current status

- The root workspace build is the supported entry point; package-local `zig build`
  is not supported.
- The current implemented surface includes `ArchetypeKey`, compact
  sparse-archetype metadata, and a bounded `Chunk(comptime Components)` layout
  that uses one backing allocation per live chunk instead of per-column heap
  slices.
- The current structural layer includes `ArchetypeStore(comptime Components)`
  plus `World`-level spawn, despawn, fused `spawnBundle()` / `insertBundle()`,
  and explicit archetype transition support with ECS-owned row relocation.
- Direct `ArchetypeStore` usage mirrors `World` on
  `components_per_archetype_max` validation, rejects occupied-slot aliasing
  before mutation, keeps bounded empty-chunk retention through
  `WorldConfig.empty_chunk_retained_max`, and directly proves chunk/archetype
  swap reindexing.
- The current hot-path layer includes typed query descriptors and a zero-copy
  borrowed chunk-batch `View` over matching archetypes, with fail-fast
  invalidation after structural mutation in runtime-safety builds.
- The current control-plane layer includes a bounded
  `CommandBuffer(comptime Components)` with separate entry-count and
  payload-byte bounds, fused bundle staging, deterministic apply order, and
  typed `World.insert()` / `World.remove()` helpers so value-component
  additions stay initialized.
- Archetype lookup and append-path chunk acquisition now use package-owned fast
  paths instead of full scans as the primary route.
- The package now also owns a first `static_testing.testing.model` sequence
  proof for mixed command-buffer structural mutation over a bounded typed
  world.
- The package now also owns representative compile-contract coverage for the
  main public generic `@compileError` boundaries through `tests/compile_fail/`
  plus the matching integration harness.
- The package now owns benchmark review workloads under `zig build bench` for
  chunk-batch iteration, structural churn, and command-buffer apply
  throughput, with shared `static_testing` baseline/history artifacts and
  explicit cross-OS / cross-CPU environment notes.
- Runtime-erased queries, import/export, and spatial adapters remain deferred.
- The current follow-up closure posture now lives in
  `docs/plans/completed/static_ecs_performance_and_memory_followup_closed_2026-04-05.md`.

## Main surfaces

- `src/root.zig` exports the package API.
- `src/ecs/world_config.zig` owns the explicit hard-bound configuration
  contract.
- `src/ecs/entity.zig` and `src/ecs/entity_pool.zig` own bounded identity
  allocation and stale-id rejection.
- `src/ecs/component_registry.zig` owns typed component-universe admission.
- `src/ecs/archetype_key.zig` owns deterministic runtime component-subset keys.
- `src/ecs/chunk.zig` owns bounded SoA column materialization for one
  archetype chunk, compact present-column metadata, and single-backing
  allocation layout.
- `src/ecs/archetype_store.zig` owns bounded archetype placement and ECS-owned
  row relocation, with direct config-bound validation parity, occupied-slot
  alias rejection before mutation, fingerprint-based archetype lookup,
  append-path chunk fast paths, bounded empty-chunk retention, and raw
  value-adding archetype moves fenced behind explicit initialization
  requirements.
- `src/ecs/bundle_codec.zig` owns deterministic encoded bundle layout for fused
  runtime bundle staging and apply.
- `src/ecs/query.zig` owns typed query descriptors and matching semantics.
- `src/ecs/view.zig` owns borrowed typed chunk-batch iteration over matching
  archetypes, invalidated by structural mutation.
- `src/ecs/command_buffer.zig` owns bounded structural staging with separate
  metadata and payload storage plus deterministic apply order.
- `src/ecs/world.zig` owns the world-local typed ECS shell on top of that
  structural layer, including typed insert/remove helpers, fused bundle
  admission, and command-buffer initialization.
- `benchmarks/` owns the admitted ECS benchmark review workloads and shared
  benchmark-workflow output contract.

## Validation

- `zig build check`
- `zig build test`
- `zig build bench`
- `zig build docs-lint`

## Key paths

- `tests/integration/root.zig` wires the package-level deterministic
  integration suite, including the package-owned `testing.model` command-buffer
  sequence proof.
- `tests/compile_fail/build.zig` wires the package-owned compile-contract
  fixtures, while `tests/integration/compile_contract_failures.zig` runs the
  canonical regression harness under the workspace test surface.
- `benchmarks/` holds the admitted `query_iteration_baselines`,
  `structural_churn_baselines`, and `command_buffer_apply_baselines` review
  workloads.
- `docs/plans/completed/static_ecs_performance_and_memory_followup_closed_2026-04-05.md`
  records the fused bundle, command-buffer, chunk-storage, control-plane,
  metadata, and benchmark-admission closure posture.
- `docs/plans/completed/static_ecs_cleanup_followup_closed_2026-04-05.md`
  records the current closure posture and reopen triggers.
