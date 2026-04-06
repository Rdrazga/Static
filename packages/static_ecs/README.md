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
- Heavy internal invariant walks now short-circuit outside runtime-safety
  builds, so `ReleaseFast` hot paths do not keep paying debug-style scan costs
  just to reach stripped assertions.
- The current control-plane layer includes a bounded
  `CommandBuffer(comptime Components)` with separate entry-count and
  payload-byte bounds, rollback-safe bundle staging, deterministic apply order,
  and typed `World.insert()` / `World.remove()` helpers so value-component
  additions stay initialized.
- The direct encoded-bundle world/store routes now reject malformed bytes
  through stable operating errors, accept misaligned caller byte slices, and
  document payload bytes as same-process bit-valid staging input rather than a
  general value-validation surface.
- The typed `World.spawnBundle()` / `World.insertBundle()` helpers and
  `CommandBuffer` bundle staging no longer materialize stack scratch buffers
  sized by encoded bundle bytes.
- Archetype lookup and append-path chunk acquisition now use package-owned fast
  paths instead of full scans as the primary route.
- The package now also owns a first `static_testing.testing.model` sequence
  proof for mixed command-buffer structural mutation over a bounded typed
  world.
- The package now also owns representative compile-contract coverage for the
  main public generic `@compileError` boundaries through `tests/compile_fail/`
  plus the matching integration harness.
- The package now owns benchmark review workloads under `zig build bench` for
  chunk-batch iteration, structural churn, command-buffer staged-apply
  throughput plus command-buffer setup/stage phase attribution and apply-only
  timing, primitive hot-path microbenchmarks, query scaling across entity and
  archetype counts, frame-like multi-pass ECS runs, branch-heavy versus
  write-heavy frame workload sets, and allocator-strategy comparisons between
  caller-supplied allocators on typed versus direct encoded bundle spawn
  paths, with shared `static_testing` baseline/history artifacts plus explicit
  environment-note and environment-tag metadata.
- The root bench surface now builds the imported ECS and `static_testing`
  modules under the same `ReleaseFast` mode the benchmark history records, so
  benchmark metadata and absolute timings are again aligned.
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
  runtime bundle staging and apply, plus malformed-input rejection and
  misaligned-slice tolerance for the direct encoded-bundle route.
- `src/ecs/query.zig` owns typed query descriptors and matching semantics.
- `src/ecs/view.zig` owns borrowed typed chunk-batch iteration over matching
  archetypes, invalidated by structural mutation.
- `src/ecs/command_buffer.zig` owns bounded structural staging with separate
  metadata and payload storage, rollback-safe bundle staging, and deterministic
  apply order.
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
  sequence proof plus the direct encoded-bundle and empty-chunk-retention
  regressions.
- `tests/compile_fail/build.zig` wires the package-owned compile-contract
  fixtures, while `tests/integration/compile_contract_failures.zig` runs the
  canonical regression harness under the workspace test surface.
- `benchmarks/` holds the admitted `query_iteration_baselines`,
  `structural_churn_baselines`, `command_buffer_staged_apply_baselines`,
  `command_buffer_phase_baselines`, `command_buffer_apply_only_baselines`,
  `micro_hotpaths_baselines`, `query_scale_baselines`,
  `frame_pass_baselines`, and `frame_workload_baselines`, and
  `allocator_strategy_baselines` review workloads.
  `query_iteration_baselines` now owns dense single-archetype, mixed
  optional/exclude, and fragmented multi-archetype scan cases.
  `structural_churn_baselines` now owns initial spawn admission plus
  live-entity scalar-versus-bundle transition churn under a reduced iteration
  budget so direct reruns stay bounded.
  `command_buffer_staged_apply_baselines` now owns spawn-only, insert-only, and
  mixed spawn/insert/remove stage-plus-apply cases.
  `command_buffer_phase_baselines` now owns the corresponding setup-only and
  stage-and-clear attribution cases so staged-apply results can be interpreted
  without implying true apply-only timing.
  `command_buffer_apply_only_baselines` now uses the shared benchmark
  prepare-hook surface to stage a fresh world and command buffer outside the
  timer for each sample so the reported cases isolate `apply()` itself.
  `micro_hotpaths_baselines` now owns primitive hot paths such as const
  component lookup, `hasComponent()`, iterator startup, and one-command bundle
  staging.
  `query_scale_baselines` now owns dense and fragmented query scaling cases
  across varying entity and archetype counts under one stable query family.
  `frame_pass_baselines` now owns sequential ECS frame-like pass mixes that
  vary pass count, entity count, and archetype fragmentation without implying a
  package-native scheduler API.
  `frame_workload_baselines` now owns branch-heavy and write-heavy frame/system
  mixes so later ECS tuning can separate query/filter pressure from column
  write pressure.
  `allocator_strategy_baselines` now compares the current allocator-agnostic
  ECS boundary under `std.heap.page_allocator` versus a caller-supplied
  `static_memory.slab.Slab`, and contrasts that typed bundle path with the
  direct encoded route that avoids per-call scratch allocation.
- `docs/plans/completed/static_ecs_performance_and_memory_followup_closed_2026-04-05.md`
  records the fused bundle, command-buffer, chunk-storage, control-plane,
  metadata, and benchmark-admission closure posture.
- `docs/plans/completed/static_ecs_benchmark_review_and_expansion_closed_2026-04-05.md`
  records the current benchmark-shape and workflow-metadata closure posture.
- `docs/plans/completed/static_ecs_benchmark_matrix_expansion_closed_2026-04-05.md`
  records the microbenchmark, query-scale, and frame-pass benchmark expansion
  closure posture.
- `docs/plans/completed/static_ecs_benchmark_truthfulness_followup_closed_2026-04-05.md`
  records the release-mode truthfulness, command-buffer owner naming, and
  structural-churn rerun-budget closure posture.
- `docs/plans/completed/static_ecs_cleanup_followup_closed_2026-04-05.md`
  records the current closure posture and reopen triggers.
- `docs/plans/completed/static_ecs_bundle_portability_and_command_buffer_followup_closed_2026-04-05.md`
  records the encoded-bundle portability, rollback, stack-shape, and contract
  closure posture.
- `docs/sketches/static_ecs_production_benchmark_backlog_2026-04-05.md`
  records the remaining long-form benchmark backlog for production-grade ECS
  comparison work.
