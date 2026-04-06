# `static_ecs` performance and memory follow-up

Scope: close the validated 2026-04-05 performance and memory reopen for the
world-local typed ECS package.

Status: follow-up closed on 2026-04-05. The current package slice now owns
truthful fused bundle mutation, explicit command-buffer payload bounds,
single-backing chunk storage with bounded empty-chunk retention, control-plane
fast paths, compact sparse-archetype metadata, and admitted benchmark review
workloads under the root `zig build bench` surface.

## Validated issue scope

- Bundle-oriented structural mutation previously replayed one scalar insert per
  component and could pay repeated archetype moves plus shared-column copies
  before reaching the final archetype.
- `CommandBuffer` previously stored all commands in one worst-case-sized union,
  so `spawn`, `despawn`, and `remove` entries paid the footprint of the largest
  insertable component in the universe.
- Chunk storage previously fanned one chunk out across multiple allocator
  calls and eagerly reclaimed empty chunk backing, making structural churn
  highly allocator-sensitive.
- Archetype lookup and append-path chunk acquisition previously relied on
  linear scans as the primary route, while dead cache and side-index config
  knobs overstated the implemented control plane.
- Sparse archetypes previously paid full-universe metadata cost in key and
  chunk storage even when only a small subset of components was materialized.
- The package previously had no admitted benchmark owner for chunk iteration,
  structural churn, or command-buffer apply throughput.

## Implemented fixes

- `src/ecs/bundle_codec.zig`, `src/ecs/world.zig`, `src/ecs/archetype_store.zig`,
  and `src/ecs/command_buffer.zig` now support fused encoded bundle admission.
  `World.spawnBundle()` / `World.insertBundle()` and the matching command-buffer
  staging paths now target the final archetype directly instead of replaying
  repeated scalar inserts.
- `src/ecs/command_buffer.zig` now separates command metadata from staged
  payload bytes. `WorldConfig` now carries both
  `command_buffer_entries_max` and `command_buffer_payload_bytes_max`, and the
  package directly proves payload-bound exhaustion plus ordered bundle apply.
- `src/ecs/chunk.zig` now stores each live chunk in one aligned backing
  allocation for the entity lane plus materialized component columns.
  `src/ecs/archetype_store.zig` now keeps bounded empty-chunk retention through
  `WorldConfig.empty_chunk_retained_max` instead of eagerly freeing every empty
  chunk on the first churn cycle.
- `src/ecs/archetype_store.zig` now uses a package-owned archetype fingerprint
  index with exact-key checks plus append-path chunk fast paths, and the dead
  `query_cache_entries_max` / `side_index_entries_max` config knobs are removed
  from `WorldConfig`, tests, and docs.
- `src/ecs/archetype_key.zig` and `src/ecs/chunk.zig` now use compact
  present-component metadata so sparse archetypes no longer pay a full-universe
  metadata table by default.
- `packages/static_ecs/benchmarks/` now owns admitted ECS review workloads for
  `query_iteration_baselines`, `structural_churn_baselines`, and
  `command_buffer_apply_baselines`, all wired into the root `zig build bench`
  surface with shared `static_testing` baseline/history handling and explicit
  `os=` / `arch=` environment notes.

## Proof posture

- Direct deterministic runtime proof now covers fused world and command-buffer
  bundle admission, command-buffer payload accounting, view invalidation,
  direct archetype/chunk swap reindexing, and bounded structural mutation under
  the new storage layout.
- Representative compile-contract proof remains package-owned through
  `tests/compile_fail/` plus the integration harness.
- The package now owns review-stable ECS benchmark workloads under the shared
  benchmark workflow instead of relying only on source-level reasoning for
  cross-CPU and cross-OS comparisons.

## Current posture

- `static_ecs` remains the same world-local typed-first package slice:
  explicit bounds, ECS-owned identity and relocation, typed query/view hot
  paths, bounded command staging, and package-owned benchmark review.
- Runtime-erased queries, import/export, spatial adapters, and broader
  scheduler-facing surfaces remain outside this closure because they were not
  part of the validated reopen scope.

## Reopen triggers

- Reopen if a new bundle helper or structural staging route bypasses final-
  archetype admission and reintroduces repeated scalar move costs.
- Reopen if a new command variant makes non-payload commands pay worst-case
  component storage again or bypasses the explicit payload-byte bound.
- Reopen if chunk churn reintroduces allocator-dependent multi-allocation
  storage or if empty-chunk retention stops honoring the explicit config bound.
- Reopen if a new public config knob lands without an implementation in the
  same package slice.
- Reopen if a new archetype or chunk metadata rewrite regresses sparse-world
  storage back to full-universe tables without a documented tradeoff and direct
  proof.
- Reopen if the admitted ECS benchmarks fall out of the root bench surface or
  stop recording the environment-note contract needed for cross-platform review.
