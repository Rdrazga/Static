# `static_ecs` follow-up plan

Scope: first real world-local typed ECS package for the workspace.

Status: follow-up closed on 2026-04-05. The v1 world-local typed core is now
implemented, the first proof map is explicit, the initial `testing.model`
structural sequence slice is landed, and benchmark posture is intentionally
recorded as deferred until one ECS workload is stable enough to admit as a
canonical shared benchmark owner.

## Current posture

- `static_ecs` now owns the first world-local typed ECS core for the workspace:
  `WorldConfig`, `Entity`, `EntityPool`, typed component-universe admission,
  `ArchetypeKey`, bounded `Chunk`, `ArchetypeStore`, typed query descriptors,
  chunk-batch `View`, a bounded `CommandBuffer`, and a `World(comptime
  Components)` shell over those surfaces.
- Typed structural growth is now explicit. `World.insert()` /
  `World.remove()` and the corresponding store-level helpers own initialized
  component admission and removal, while raw `moveToArchetype()` calls reject
  value-adding transitions that would otherwise create uninitialized columns.
- The first package-owned proof map is now recorded:
  direct unit tests own world-config bounds, entity identity, archetype-key
  ordering, chunk layout, structural relocation, typed query matching, and
  command ordering basics; integration tests own world-facing identity,
  archetype mutation, query/view, and command-buffer behavior; and
  `static_testing.testing.model` now owns bounded mixed command-buffer
  structural sequences through
  `packages/static_ecs/tests/integration/command_buffer_runtime_sequences.zig`.
  The typed-query misuse boundary currently stays package-local through
  comptime validators and in-source proof, not a separate compile-fail harness.
- The package boundary remains intentionally narrow. Runtime-erased queries,
  cross-world import/export, scheduler ownership, transport/replication,
  persistence, GPU/UI concerns, and spatial adapters remain deferred out of the
  v1 package surface.

## Benchmark posture

- No `static_ecs` benchmark is admitted yet.
- Chunk iteration and structural churn are both real future benchmark
  candidates, but the current package surface does not yet have one canonical,
  review-stable workload definition that is clearly better than deferring.
- Admitting a benchmark now would risk freezing premature semantics around one
  archetype mix, one row shape, or one command distribution before a real
  downstream caller proves the right owner workload.

## Deferred benchmark candidates

- `chunk_batch_iteration_dense_columns`
  Defer until one canonical hot-path workload is fixed enough to name exactly:
  component mix, chunk occupancy, archetype fanout, and whether optional-column
  presence is in scope.
- `command_buffer_structural_churn`
  Defer until one canonical control-plane workload is fixed enough to name
  exactly: spawn/despawn versus insert/remove mix, apply cadence, and whether
  same-tick entity reuse is part of the benchmark contract.

## Open follow-up triggers

- Reopen benchmark admission only if one concrete ECS workload becomes stable
  enough to serve as a canonical shared `zig build bench` owner.
- Reopen runtime-erased query work only if a real caller needs dynamic query
  planning beyond the current typed-first surface.
- Reopen cross-world/import-export work only if a real package slice defines a
  durable caller-owned transfer contract for component data.
- Reopen side-index or spatial-adapter work only if a real world-local ECS
  adopter needs a generic package-owned adapter surface rather than a local
  integration layer.
- Reopen negative-proof work only if the in-source comptime validation stops
  being sufficient and the package needs a dedicated compile-fail harness.
