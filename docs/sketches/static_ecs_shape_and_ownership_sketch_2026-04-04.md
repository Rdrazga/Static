# `static_ecs` shape and ownership sketch - 2026-04-04

This sketch extends [static_ecs_package_sketch_2026-04-02.md](./static_ecs_package_sketch_2026-04-02.md)
with tighter design direction for the lower-package approvals, the ECS hot-path
versus batch-path shape, sharded-world communication, and strict ownership
boundaries for the example project families.

## Approved lower-package assumptions

These assumptions should be treated as the current approved direction while
`static_ecs` remains a sketch:

- `static_spatial`
  - approve bounded-grid `queryAABB` alignment to the BVH total-hit contract;
  - preserve duplicate semantics while changing truncation reporting.
- `static_collections`
  - do not assume a `DenseArray` relocation helper exists;
  - default to keeping swap-remove relocation bookkeeping in `static_ecs`
    unless a stronger generic packed-storage helper is later proven.
- `static_hash`
  - assume fold-many `combine` helpers are valid lower-package work;
  - do not assume a fixed-width repeated-record batch primitive exists.

`static_ecs` should therefore be designed so its first real package plan does
not depend on speculative lower-package extraction beyond the approved slices
above.

## Implementation-plan entry conditions

The first real `static_ecs` plan should open only against assumptions that are
stable enough to implement directly:

- `static_spatial` bounded-grid alignment may still be in flight, but ECS v1
  should not depend on spatial adapters landing in the first slice;
- `static_collections` may still reject a generic relocation helper, and ECS v1
  should treat packed-row relocation as ECS-owned by default;
- `static_hash` fold-many `combine` helpers may land, but ECS v1 should not
  depend on any fixed-width repeated-record helper.

The first plan should therefore be able to ship a coherent world-local ECS even
if:

- spatial adapters are deferred;
- cross-world import/export is deferred;
- runtime-erased query planning is deferred;
- repeated-record batch hashing stays ECS-owned or remains unnecessary.

## Core direction

`static_ecs` should be a deterministic, chunk-oriented, data-oriented ECS that
supports:

- one semantic model for hot iteration and batch execution;
- explicit structural mutation and explicit world-owned side indexes;
- local-world efficiency first;
- future extraction into sharded, replicated, or accelerator-adjacent flows
  without pulling transport, rendering, or storage ownership into ECS itself.

The package should stay centered on world storage, archetype transitions, query
planning, and deterministic structural batches. It should not become a general
runtime umbrella.

## V1 implementation boundary

The first implementation plan should target a narrow world-local ECS core.

### V1 should include

- `WorldConfig`
  - explicit hard bounds and allocation policy.
- `Entity` and `EntityPool`
  - bounded local identity allocation and stale-id rejection.
- `ComponentRegistry`
  - metadata needed to build and validate world-local component storage.
- `ArchetypeKey`
  - component-set identity and lookup.
- `Chunk`
  - bounded SoA storage for one archetype.
- `ArchetypeStore`
  - spawn, despawn, add/remove component-set transitions, and deterministic row
    relocation.
- typed query plus view surfaces
  - hot-path iteration over comptime-known component sets.
- `CommandBuffer`
  - deterministic structural staging and application.

### V1 should defer

- runtime-erased query planning unless a concrete non-hot-path caller appears
  during the first package slice;
- cross-world import/export;
- world-owned spatial adapters;
- change-tracking, observers, or event buses;
- scheduler or executor integration;
- GPU extraction helpers beyond chunk-batch-friendly iteration shape;
- persistence, replication, or protocol-specific bridges.

### Reason

That boundary is small enough to validate, but large enough to prove the real
ECS storage and mutation model rather than only an entity-id shell.

## Library versus caller ownership

The package boundary should stay explicit about what the ECS library guarantees
versus what callers must declare or supply themselves.

### Library-owned responsibilities

- world-local entity allocation, stale-id rejection, and row ownership;
- component-set membership, archetype resolution, and row movement;
- chunk layout enforcement and column access rules;
- deterministic query matching and deterministic structural batch application;
- explicit capacity checks, bounded command staging, and world-local side-index
  ownership where an adapter is admitted.

### Caller-owned responsibilities

- defining component types and deciding which ones belong in a world;
- declaring any component storage traits the ECS consumes, such as hot/cold or
  transferability policy;
- writing system logic and choosing hot-loop structure;
- choosing whether cross-world export/import exists at all;
- supplying codecs, remap policy, or external-resource handling for any
  component data that leaves one world and enters another.

The library should not pretend it can infer arbitrary storage, transfer, or
execution policy from Zig reflection alone.

## Static versus runtime world-family direction

The long-term package goal may include both:

- a strongly typed world path optimized for comptime-known component sets and
  hot iteration; and
- a more runtime-driven path for tooling, editors, or other dynamic use cases.

The first implementation plan should not force both into one giant surface.

The recommended direction is:

- anchor v1 on a typed world and typed queries;
- keep internal storage and archetype semantics general enough that a later
  runtime-erased layer can reuse them;
- defer a fully dynamic runtime world surface until the typed storage and
  mutation model is already proven.

This keeps the hottest path aligned with Zig's strengths instead of letting
runtime flexibility dominate the first package boundary.

## Ownership boundary

### `static_ecs` should own

- `Entity`
  - world-local identity and stale-handle rejection semantics.
- `EntityPool`
  - bounded allocation and free/reuse policy over local entities.
- `ComponentRegistry`
  - ECS-facing component metadata over `static_meta`.
- `ArchetypeKey`
  - ECS-owned wrapper over component-set identity and lower hash/meta helpers.
- `Chunk`
  - SoA-oriented packed storage for one archetype.
- `ArchetypeStore`
  - world-local chunk ownership, row allocation, row movement, and
    entity-to-row plus row-to-entity mapping.
- typed query surfaces
  - comptime-known read/write/optional/filter requirements for hot iteration
    over concrete component column types.
- runtime-erased query planning
  - runtime-resolved read/write/optional/filter requirements over component ids
    and erased column descriptors for tools, bridges, and other dynamic flows.
- `View`
  - hot iteration surface over matching chunks and columns.
- `CommandBuffer`
  - deterministic batch staging for structural changes.
- `ApplyCommands`
  - world-local batch application and archetype relocation.
- world-owned side-index adapters
  - for example spatial adapters over `static_spatial`.
- export/import helper surfaces for local deterministic command batches,
  snapshots, or row streams
  - only to the extent needed to externalize world-local state for components
    that satisfy an explicit caller-declared transfer contract, without owning
    transport or replication policy.

### Candidate first public surface

These names are not final, but the first implementation plan should probably
stay close to one small surface like:

- `ecs.WorldConfig`
- `ecs.Entity`
- `ecs.World`
- `ecs.CommandBuffer`
- `ecs.Query(...)`
- `ecs.View(...)`

Possible supporting internal or narrower public types:

- `ecs.ComponentRegistry`
- `ecs.ArchetypeKey`
- `ecs.Chunk`
- `ecs.ArchetypeStore`

The first plan should avoid opening many parallel surface families before the
core world storage contract is proven.

### `static_ecs` should not own

- schedulers, executors, or host-thread orchestration;
- networking, transports, RPC, HTTP, websocket, or auth protocols;
- database engines, storage engines, persistence policy, or distributed
  durability;
- GPU APIs, render graphs, materials, assets, or frame submission;
- browser DOM, router, hydration, or frontend platform runtimes;
- replication policy, consensus, anti-entropy, or conflict resolution.

### Likely sibling packages if those concerns become real

- `static_http` or protocol-specific runtime packages
- `static_storage` or a narrower persistence package
- `static_state_sync` or `static_replication`
- `static_gpu` and likely a higher-level `static_render`
- `static_ui` or `static_web`

None of those should be invented just to start `static_ecs`, but they may block
the full example ambitions below from being solved cleanly.

## One semantic model for hot paths and batch paths

If one ECS is expected to support both hot loops and batch-oriented flows on
the same semantics, the package should separate semantic shape from execution
shape.

### Semantic shape

The semantic layer should be the same regardless of how work executes:

- entities live in archetypes defined by component-set membership;
- chunks own component columns and row membership;
- queries describe read, write, optional, exclude, and tag requirements;
- structural changes are explicit world operations, not hidden inside queries;
- component add/remove and archetype moves preserve one deterministic world
  state transition model.

### Structural mutation model

The first implementation plan should pin one mutation model clearly:

- typed query iteration reads and writes component columns within the current
  archetype layout;
- structural changes that can move rows between archetypes go through
  `CommandBuffer` or an equivalently explicit batched world API;
- direct immediate structural mutation may exist as a control-plane surface,
  but it should not be the default hot-path usage model.

This keeps hot iteration and structural relocation separated in a way that fits
both TigerStyle and a chunk-based ECS.

### Execution shape

Different execution paths should be thin wrappers over those same semantics:

- `View`
  - hot-path dense iteration over chunk columns;
  - intended for simulation, transforms, AI, and other cache-sensitive loops.
- `BatchView` or a similar chunk-batch surface
  - exposes chunk ranges or bounded column slices in larger pieces for parsing,
    extraction, aggregation, or serialization-style work;
  - should not invent a second storage model.
- `CommandBuffer`
  - stages structural changes so hot iteration remains stable;
  - batch systems and hot systems should both feed the same mutation surface.
- `QueryPlan`
  - one resolved plan can back scalar loops, chunk-batch loops, extraction, or
    future executor-driven scheduling.

`BatchView` should be treated as a likely consequence of the chunk model, not
as a required first public type. The first implementation plan can satisfy the
same need by exposing chunk iteration in a way that callers can batch over
directly.

### Compile-time versus runtime query split

Zig can express a high-performance typed query surface when the accessed
component set is known at comptime. Zig does not cleanly support taking an
arbitrary runtime query description and materializing a new typed tuple of
component columns on demand.

The ECS shape should therefore separate:

- typed queries
  - comptime-known component sets and access modes;
  - intended for hot loops and direct column access.
- erased runtime queries
  - runtime component ids plus erased column metadata;
  - intended for tools, editors, import/export bridges, diagnostics, and other
    dynamic flows.

These two paths should share archetype-matching semantics and deterministic
ordering, but they should not be forced into one pretending-to-be-generic API.

### Required ECS shape consequences

- direct per-entity structural mutation during hot iteration should be treated
  as a slow path or forbidden behind explicit barriers;
- query access descriptors should be compile-time-friendly and world-local on
  the typed path, with a separate erased runtime path for dynamic use cases;
- chunk iteration should expose contiguous typed columns, not just row objects,
  when the query shape is known at comptime;
- batching should operate on chunk slices or command streams, not by wrapping
  single-entity APIs in outer loops;
- any future executor integration should consume `QueryPlan` and chunk ranges
  rather than inventing separate ECS semantics.

## Sharded worlds and executor-to-executor communication

If separate worlds or executors need to communicate over similar ECS / DoD
shapes, the first requirement is to keep local-world ECS semantics clean.

### What `static_ecs` should include

- stable component schema description sufficient to externalize command or
  snapshot payloads for components that opt into transfer;
- deterministic ordering for exported command batches and snapshot rows;
- explicit import/export surfaces for:
  - command bundles;
  - snapshot chunks or row batches;
  - entity-remap tables on import.
- world-local namespace boundaries
  - local `Entity` values should remain local by default.

### Transfer contract boundary

Cross-world import/export should not imply that every component is
automatically transferable.

The boundary should be:

- the library owns deterministic row ordering, import/export traversal, and
  entity-remap application;
- the caller owns the decision to mark a component as transferable and the
  codec or externalization policy for that component;
- non-transferable components remain local-only by default;
- pointer-rich, allocator-backed, OS-handle, or other world-external values
  should be rejected by default unless the caller provides an explicit policy
  that externalizes or remaps them safely.

### What should stay out of `static_ecs`

- transport selection;
- world routing;
- conflict resolution across concurrent writers;
- replica consistency models;
- reliable delivery, anti-entropy, or retry policy;
- clock synchronization and distributed causality.

Those belong in a sibling package once there is real need. A likely future
package is `static_state_sync` or `static_replication`.

### Design implication

`static_ecs` should treat cross-world communication as import/export of explicit
world-local data shapes, not as magical globally shared entities. That keeps:

- local hot-path storage simple;
- distributed policy replaceable;
- sharded-world support possible later without forcing v1 ECS into a
  distributed-runtime boundary.

## Maximized efficiency and hardware-aware design

For the ECS to stay performant across a wide range of targets, the package
needs explicit storage and execution policies rather than one opaque default.

### Storage requirements

- chunked SoA by default for hot components;
- zero-sized tag support without phantom column cost;
- hot/cold component separation only through a small explicit storage-policy
  surface, such as comptime traits or a sharply bounded runtime enum, not
  through open-ended metadata magic;
- explicit alignment and stride policy per component column;
- bounded or reserve-at-init modes for entities, archetypes, and command
  buffers;
- predictable row movement and chunk reuse;
- world-local side indexes owned explicitly, not hidden in the core chunk path.

### Required hard bounds

The first real package plan should name exact caps rather than only saying
"bounded mode."

The minimum bound set should include:

- maximum entities per world;
- maximum registered component types per world;
- maximum components per archetype;
- maximum archetypes per world;
- maximum chunks per archetype or an equivalent total chunk cap;
- maximum cached query plans or equivalent query-cache bound;
- maximum command-buffer entries per apply window;
- maximum snapshot/export rows or commands per batch;
- maximum ECS-owned side-index capacity wherever an adapter is admitted.

`WorldConfig` should carry these caps explicitly rather than hiding them behind
one generic "bounded mode" switch.

### Query and mutation requirements

- resolved query plans cached by access pattern;
- contiguous typed column iteration for tight loops;
- optional chunk-level filtering and change-tracking hooks if they can be kept
  honest and cheap;
- command application grouped to reduce archetype churn;
- batch spawn / despawn / add / remove surfaces as first-class operations;
- minimal branchy per-row dispatch in hot paths;
- hot iteration and hot batch extraction should not allocate after init;
- the hot loop should be lowerable to raw typed slices or pointers plus count
  so callers can write standalone functions without forcing object-rich
  callback layers.

### Target-awareness requirements

- chunk sizing should be configurable by target profile instead of hard-coded;
- SIMD-friendly alignment and column grouping should be possible without
  changing ECS semantics;
- GPU-extraction workflows should consume chunk batches rather than forcing row
  marshaling one entity at a time;
- memory-constrained targets should be able to choose smaller chunk sizes and
  stricter bounded modes;
- multi-executor or NUMA-adjacent deployments should scale by sharding worlds
  or work ownership, not by forcing one globally shared mutable world.

### What probably stays outside core ECS even if performance matters

- job scheduling policy;
- GPU buffer lifecycle and render submission;
- storage or replication transport tuning;
- protocol parser specialization.

The ECS should expose shapes those systems can consume efficiently. It should
not own those systems.

## Example project ownership checks

### Comptime-generated SaaS backends

Goal example:

- ECS-shaped HTTP servers, parsers, connection handling, auth, and eventually
  diagonally scaling storage that matches the ECS semantics closely.

`static_ecs` should own:

- world state, archetypes, chunk storage, and component/query semantics;
- command buffering and batch application for request, session, connection, or
  storage-state worlds;
- stable import/export shapes that sibling packages can feed.

`static_ecs` should not own:

- HTTP parsing, protocol codecs, connection runtimes, TLS, auth rules, or
  persistence engines.

Likely sibling packages or blockers:

- `static_http`
- `static_auth`
- `static_storage`
- possibly `static_state_sync` for diagonal scaling and cross-node world sync

Conclusion:

- `static_ecs` can provide the state model and high-throughput mutation/query
  substrate;
- the surrounding protocol, auth, and storage stack should stay in sibling
  packages.

### Fullstack framework

Goal example:

- one framework spanning frontend and backend while sharing similar ECS / DoD
  semantics.

`static_ecs` should own:

- backend or shared application state worlds;
- optional client-local world state if the frontend actually benefits from ECS
  semantics;
- import/export surfaces for syncing state into UI or transport layers.

`static_ecs` should not own:

- DOM bindings;
- router/runtime behavior;
- rendering strategy;
- hydration;
- transport or RPC boundary logic.

Likely sibling packages or blockers:

- `static_ui` or `static_web`
- `static_http`
- possibly `static_state_sync` if client/server world synchronization becomes a
  first-class feature

Conclusion:

- `static_ecs` can be the state engine;
- a real fullstack framework needs at least one sibling UI/runtime package to
  stay clean.

### Game engine with close GPU/CPU meshing

Goal example:

- simulation and rendering data stay close enough that extraction and
  synchronization are efficient.

`static_ecs` should own:

- simulation-state worlds;
- chunk-friendly component storage and hot queries;
- extraction-friendly batch views;
- deterministic command buffers for frame or tick boundaries;
- optional world-owned render or physics side-index adapters only at the ECS
  data boundary.

`static_ecs` should not own:

- GPU resource creation;
- shader pipelines;
- render graph logic;
- asset streaming;
- audio or physics engine internals.

Likely sibling packages or blockers:

- `static_gpu`
- likely `static_render`
- possibly `static_assets`
- possibly `static_physics`

Conclusion:

- `static_ecs` should make extraction and synchronization cheap;
- actual GPU and engine subsystems need separate ownership.

## Initial ECS planning consequences

The first real `static_ecs` plan should assume this order:

1. local-world identity and component metadata
2. archetype keying and chunk layout
3. archetype store with deterministic row movement
4. typed query plus view surfaces for hot iteration
5. command buffer and batch application
6. runtime-erased query or export/import surfaces where dynamic flows are
   already justified
7. world-owned adapter surfaces for spatial and other side indexes

## First plan readiness checklist

The sketch is ready to become a real implementation plan only if the plan can
state all of the following up front:

- the exact v1 public surface;
- the exact v1 deferred surface;
- the hard bounds carried by `WorldConfig`;
- the typed query shape chosen for hot iteration;
- the row-relocation ownership model inside `ArchetypeStore`;
- the command-application ordering contract;
- the first proof surfaces under `zig build test` and `static_testing`;
- the first benchmark owner workloads for chunk iteration and structural churn.

If any of those remain vague, the package plan should tighten them first rather
than starting implementation with an underspecified core.

It should not assume:

- distributed execution;
- protocol/runtime ownership;
- GPU ownership;
- a `DenseArray` relocation helper;
- a repeated-record batch hash primitive.
- arbitrary runtime query plans can materialize typed component tuples.

## Open decisions that should not block v1

These are real follow-on design questions, but they should not delay the first
implementation plan:

- whether runtime-erased queries become a public v2 surface;
- whether cross-world import/export belongs in `static_ecs` v2 or a sibling
  package;
- whether spatial adapters are included in the package's first stable release
  or arrive immediately after;
- whether hot/cold storage policy is purely comptime-driven or also allows a
  small runtime enum;
- whether a later runtime-driven world shape should share one `World` type or
  be a sibling surface over the same storage internals.

## Reopen conditions for sibling-package extraction

Open or plan a new sibling package only when the boundary becomes concrete:

- open `static_state_sync` or similar once two worlds or executors need the
  same deterministic import/export, diff, retry, or convergence policy;
- open `static_http`, `static_storage`, or `static_auth` only when the repo is
  ready to own those protocol and runtime boundaries directly;
- open `static_gpu` or `static_render` once GPU-facing ownership becomes more
  than ECS extraction-friendly data layout.

Until then, `static_ecs` should stay focused on world storage, query semantics,
and deterministic structural batches.
