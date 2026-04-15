# `static_ecs` view contract and compile-proof follow-up

Scope: close the two validated follow-ups from the 2026-04-05 `static_ecs`
review: make the borrowed `View` contract explicit and fail fast under
structural mutation, and add package-owned compile-contract proof for the main
public `@compileError` boundaries.

Status: follow-up closed on 2026-04-05. The borrowed-view invalidation contract
is now explicit and enforced in runtime-safety builds, and the package now owns
representative compile-fail coverage beside its runtime integration suite.

## Validated issue scope

- `src/ecs/view.zig` previously returned `ChunkBatch` values that directly
  referenced store-owned chunk and entity buffers, but the package did not
  explicitly state or enforce what happened if callers structurally mutated the
  world or store while holding a live iterator or batch.
- `src/ecs/archetype_store.zig` already supported structural mutation that could
  relocate or reclaim the same backing storage, including row swap-remove,
  empty-chunk reclamation, and empty non-root archetype reclamation.
- The package test surface previously covered only runtime behavior plus one
  `testing.model` command-buffer sequence slice. The public comptime validators
  in `ComponentRegistry`, `ArchetypeKey.fromTypes`, `Query`, and `CommandBuffer`
  had no package-owned compile-contract harness.

## Implemented fixes

- `src/ecs/archetype_store.zig` now tracks a structural-mutation epoch and bumps
  it only when world/store mutation can invalidate borrowed view state.
- `src/ecs/view.zig` now treats iterators and chunk batches as explicitly
  borrowed surfaces. In runtime-safety builds, `Iterator.next()` and the
  `ChunkBatch` accessors panic with a stable diagnostic if used after
  structural mutation invalidates them.
- `tests/integration/view_invalidation_runtime.zig` now directly proves the new
  fail-fast behavior for stale batches and stale iterators, while the existing
  command-buffer path continues to prove the supported "iterate, stage, then
  apply" workflow.
- `tests/integration/compile_contract_failures.zig` plus
  `tests/compile_fail/` now add package-owned compile-fail coverage for the
  main public validators, including invalid component-universe entries,
  duplicate archetype-key component tuples, invalid query component admission,
  zero-sized tag column access, and invalid command-buffer helper usage.

## Proof posture

- Runtime proof now covers both the supported zero-copy hot-path pattern and
  the fail-fast invalidation path for stale borrowed view state.
- Compile-contract proof now runs under the workspace `zig build test` surface
  instead of relying on code review memory for the package's public generic
  rejection boundaries.
- The compile-fail fixtures also keep a package-local `tests/compile_fail/`
  build surface for standalone inspection, but the canonical regression owner is
  the integration test that invokes the Zig compiler directly with explicit
  module wiring.

## Current posture

- `static_ecs` remains the same first world-local typed ECS slice: explicit
  bounds, ECS-owned identity and relocation, typed query/view hot paths, a
  bounded command buffer, and typed insert/remove helpers.
- `View` remains zero-copy and borrowed. Structural mutation no longer has an
  implied contract: callers must either finish using the iterator/batch before
  mutating structurally or stage that work in `CommandBuffer` and apply it
  afterward.
- Runtime-erased queries, import/export, side indexes, spatial adapters, and
  benchmark admission remain deferred.

## Reopen triggers

- Reopen if a new borrowed iterator, batch, or slice surface is added without
  the same explicit invalidation contract and fail-fast behavior.
- Reopen if a structural mutation path in `World` or `ArchetypeStore` is found
  not to bump the borrowed-view invalidation epoch.
- Reopen if a new public generic validator lands in `static_ecs` without
  package-owned compile-contract proof.
