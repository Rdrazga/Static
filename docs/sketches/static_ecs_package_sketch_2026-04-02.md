# `static_ecs` package sketch - 2026-04-02

## Why this package should exist

The current workspace has several strong ECS building blocks, but not an ECS
runtime shape:

- `static_collections` provides generational handles, dense sets, bounded
  vectors, and generic containers;
- `static_meta` provides deterministic type identity and bounded registration;
- `static_hash` provides deterministic hashing but is still mostly scalar and
  reflective rather than batch-shaped;
- `static_spatial` provides read-mostly and dynamic spatial indices, but they
  are library structures rather than world-owned ECS adapters.

Those are good substrate layers. They are not the right place to put archetype
storage, query iteration, component relocation, or world-owned adapters for
spatial and hash surfaces.

`static_ecs` should be the package that owns those ECS-specific shapes.

## Package goal

Provide a deterministic, data-oriented ECS package that:

- keeps archetype and chunk storage ECS-specific;
- keeps world-local adapters and query surfaces out of generic collection and
  spatial packages;
- supports bounded or reserve-at-init configurations where practical;
- exposes system-friendly batch mutation and query surfaces rather than only
  scalar container methods.

## Non-goals

- Do not turn `static_collections` into an ECS umbrella package.
- Do not move generic hashing, type identity, or spatial indexing ownership out
  of their current packages.
- Do not pull scheduling, task orchestration, or host-thread execution policy
  into the first `static_ecs` boundary.
- Do not treat `SlotMap` or `FlatHashMap` as the primary component-storage
  story.

## Direct findings from the audit

### Reusable directly

- `static_collections.handle.Handle` is a valid entity or external-reference
  substrate.
- `static_collections.IndexPool` is a strong fit for bounded entity-id
  allocation and stale-handle rejection.
- `static_collections.SparseSet` is a strong fit for tag membership, dirty
  sets, and dense id iteration.
- `static_collections.Vec` is a good fit for command buffers, staging lists,
  and chunk-local temporary storage where budget tracking matters.
- `static_spatial.BVH` is a good fit for read-mostly side indexes when the
  stored payload is an entity id or handle.

### Keep behind ECS adapters or systems

- `SlotMap` is handle-safe but still scalar and slot-shaped rather than
  archetype/chunk-shaped.
- `DenseArray` is a packed array helper, not a full ECS storage boundary.
- `FlatHashMap` is useful for registries and world-local lookup tables, not as
  the main component hot path.
- `IncrementalBVH` and the dynamic grid family should be owned by ECS systems or
  side-index adapters, not called ad hoc from gameplay code.
- `hashAny` and `stableHashAny` are useful deterministic utilities, but they
  are not the right hot-path shape for archetype-signature or repeated-record
  hashing without ECS-owned wrappers or a later generic batch primitive.

## Recommended package boundary

`static_ecs` should depend on:

- `static_core`
- `static_memory`
- `static_collections`
- `static_meta`
- `static_hash`
- optional domain adapters from `static_spatial`

It should not invert ownership. Generic containers remain in
`static_collections`; generic spatial structures remain in `static_spatial`;
generic hashing remains in `static_hash`.

## Initial surface recommendation

### Phase 0: entity and world identity

- `Entity`
  Prefer an ECS-owned value type that is either a thin wrapper around
  `static_collections.handle.Handle` or an equivalent packed id with explicit
  world-local semantics.
- `EntityPool`
  Backed by `IndexPool` for bounded entity allocation and stale-id rejection.
- `WorldConfig`
  Names maximum entities, allocator or budget policy, and chunk sizing rules.

### Phase 1: archetype and chunk storage

- `ComponentTypeId`
  Use `static_meta` runtime identity and optional stable identity.
- `ArchetypeId`
  World-local identifier for a sorted component set.
- `Chunk`
  SoA-oriented storage for one archetype, preferably fixed-size or reserve-at-init.
- `ArchetypeStore`
  Owns chunks, row allocation, and entity-to-row plus row-to-entity mapping.

This is where ECS-specific data motion belongs:

- add component set
- remove component set
- move entity between archetypes
- reserve chunk capacity
- batch spawn / batch despawn / batch mutate

Those shapes should not be added to `static_collections`.

### Phase 2: query and view surfaces

- `Query`
  Compile or resolve component-set requirements.
- `View`
  Iterate matching chunks in dense SoA order.
- `CommandBuffer`
  Stage structural changes outside hot iteration.
- `ApplyCommands`
  Deterministic batch application and relocation path.

The package should prefer chunk or batch surfaces over scalar per-entity helper
calls when the operation is structurally about many entities.

### Phase 3: adapters

Adapters should live in `static_ecs`, not in the generic packages:

- `ecs.spatial.BvhIndex`
  Rebuild or query adapter over `static_spatial.BVH`.
- `ecs.spatial.IncrementalBvhIndex`
  World-owned dynamic index adapter over `IncrementalBVH`.
- `ecs.hash.ArchetypeKey`
  ECS-owned component-set key or signature wrapper over `static_hash`.
- `ecs.meta.ComponentRegistry`
  ECS-facing wrapper over `static_meta.TypeRegistry` and component metadata.

If these wrappers need generic helpers later, only the truly generic primitive
should move down into the lower package.

## Shape rules for `static_ecs`

- Prefer SoA or chunked storage over row-owned AoS where the access pattern is
  hot or repeated.
- Keep structural mutation batched and explicit.
- Avoid hidden world-global allocations after init where a reserve or bounded
  mode is practical.
- Keep component iteration and structural mutation separate by default.
- Keep adapters world-owned and deterministic; do not hide mutation in
  scattered helper calls.

## Testing fit

Best fit:

- `testing.model` for structural add/remove/move command sequences
- retained replay for minimized archetype-move failures
- `bench.workflow` for chunk iteration, add/remove churn, query scans, and
  side-index rebuild or query baselines

Not first-fit:

- process-boundary testing
- broad scheduler policy
- distributed/world-sharding concerns

## First implementation slice recommendation

The first package slice should be small and structural:

1. bounded `Entity` plus `EntityPool`
2. one `ArchetypeStore` for spawn, despawn, and move across component sets
3. one dense `Query` or `View` that iterates matching chunks
4. one deterministic `CommandBuffer` for structural changes

Do not start with networking, serialization, prefabs, reflection-heavy runtime
editing, or spatial adapters.

## `static_batching` boundary decision

### Is there a way to build it?

Yes. A generic `static_batching` package could exist as a coordination-focused
surface for:

- size-threshold batch accumulators
- time-window flush policies
- key-based coalescing
- bounded batch buffers
- deterministic flush ordering

It would likely sit conceptually between `static_collections` and
`static_scheduling`, using queues, clocks, or timers without becoming an ECS.

### Is there a need right now?

Not yet.

Current evidence is still package-specific:

- ECS wants command buffering and structural batch application, which is ECS
  policy and should live in `static_ecs`.
- Runtime and I/O batching pressures already have nearby homes in
  `static_queues`, `static_scheduling`, and downstream runtime packages.
- The repo does not yet show two or more non-ECS consumers that need the same
  generic time-window or coalescing abstraction.

### Recommendation

Do not add `static_batching` now.

Reason:

- creating it now would likely duplicate or blur `static_queues`,
  `static_scheduling`, and the first `static_ecs` command-buffer surfaces;
- the current concrete need is ECS structural batching, not a proven
  cross-workspace batching primitive;
- a good generic batching package needs multiple downstream consumers before its
  API can be shaped well.

### Reopen conditions for `static_batching`

Open a real package plan only if at least one of these becomes true:

- `static_ecs` and a non-ECS runtime package both need the same deterministic
  batch-window or coalescing helper;
- `static_io`, `static_net`, or `static_scheduling` grows repeated ad hoc batch
  timers or coalescers with the same control flow;
- a shared bounded flush-policy surface can be named without importing ECS
  vocabulary into a generic coordination package.

Until then:

- ECS command buffers, archetype mutation queues, and world-local adapters
  belong in `static_ecs`;
- generic queues and timers stay in existing coordination packages.
