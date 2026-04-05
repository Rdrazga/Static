# `static_ecs` package readiness review - 2026-04-04

## Goal

Review the existing `static_*` packages as substrate for a future
`static_ecs` package that must support both:

- static data-oriented library usage where ECS storage is an internal engine
  detail; and
- runtime ECS usage with entity lifecycles, structural mutation, deterministic
  command application, and optional runtime scheduling or side indexes.

This review is narrower than "can the repo do game engine things?". The
question here is whether the current package boundaries and contracts are the
right base for a real ECS package, or whether lower-package fixes are still
needed first.

This sketch extends:

- `docs/sketches/static_ecs_package_sketch_2026-04-02.md`
- `docs/sketches/dense_array_end_state_2026-04-02.md`
- `docs/sketches/static_hash_dod_gpu_report_2026-03-17.md`
- `docs/plans/completed/static_collections_followup_closed_2026-04-03.md`
- `docs/plans/active/packages/static_spatial.md`
- `docs/plans/active/packages/static_hash_algorithm_portfolio_research.md`

## Review frame

`static_ecs` needs these capability groups:

1. entity identity, stale-handle rejection, and bounded lifecycle management
2. archetype or chunk storage with explicit relocation policy
3. dense query or view iteration over SoA-oriented storage
4. deterministic structural mutation and command buffering
5. component metadata and stable versus runtime type identity
6. archetype-signature or component-set keying
7. optional runtime coordination for system execution
8. optional world-owned spatial side indexes
9. deterministic review surfaces for mutation sequences, replay, and benchmark
   baselines

The main boundary test is simple:

- keep generic reusable primitives in lower packages;
- keep ECS-shaped storage, relocation, query, and world adapters in
  `static_ecs`;
- only reopen lower packages when a generic contract is actually missing or
  inconsistent.

## Summary

The workspace is already strong enough to support a first real `static_ecs`
package.

The current repo does not need a broad substrate rewrite first.

It does need:

- one concrete `static_spatial` contract fix before spatial adapters can look
  uniform across index families;
- one explicit `static_collections.dense_array` end-state decision now that the
  ECS review names a real relocation-aware swap-remove use case;
- continued `static_hash` batch-shape research, but that is a performance and
  package-shape follow-on, not a blocker for the first ECS slice.

The main missing work is ECS-owned work, not lower-package work:

- `Entity`
- `EntityPool`
- `ComponentRegistry`
- `ArchetypeKey`
- `Chunk`
- `ArchetypeStore`
- `Query` / `View`
- `CommandBuffer`
- world-owned spatial and runtime adapters

## Package readiness ledger

### Direct first-slice substrate

#### `static_core`

Status: ready.

Why:

- `core.errors` already gives a stable workspace vocabulary for ECS-facing
  operating errors such as `NoSpaceLeft`, `InvalidConfig`, `NotFound`,
  `AlreadyExists`, `WouldBlock`, and `Timeout`.
- `core.time_budget` is already used by runtime code and is a good fit for
  bounded join or wait surfaces if `static_ecs` later adds runtime scheduling
  helpers.

Needed changes:

- none found for the first ECS slice.

#### `static_memory`

Status: ready.

Why:

- `budget.Budget` and `BudgetedAllocator` already give the right bounded-memory
  control plane for worlds, chunks, staging buffers, and temporary query work.
- `Arena`, `Scratch`, and `frame_scope` already cover the common ECS temporary
  allocation patterns for per-frame or per-query scratch work.
- `Pool` and `Slab` are good fits for fixed-size chunk pages or stable-sized
  runtime records if ECS later wants page-class allocation instead of one
  allocator per storage family.
- `Epoch` and `Versioned(T)` are already useful for change-tracking and cache
  invalidation around world snapshots or query caches.

Needed changes:

- none found at package level.
- `static_ecs` should own chunk policy itself rather than asking
  `static_memory` to become "the chunk package".

#### `static_collections`

Status: mostly ready as substrate, with one concrete follow-up decision needed.

Already strong:

- `handle.Handle` is a valid packed entity-id substrate.
- `index_pool.IndexPool` is a strong bounded entity allocator with stale-handle
  rejection, `handleForIndex`, `validate`, and `clear`.
- `sparse_set.SparseSet` is already a strong fit for tags, dirty sets,
  membership filters, and dense entity-id iteration.
- `vec.Vec(T)` is already the right generic staging buffer for command buffers,
  structural batches, and allocator-budget-aware temporary lists.
- `flat_hash_map.FlatHashMap` and `sorted_vec_map.SortedVecMap` are already good
  control-plane maps for world metadata, registries, lookup tables, and small
  sorted descriptor maps.

Correct boundary call:

- `slot_map.SlotMap` is useful, but it is still slot-oriented scalar storage,
  not archetype or chunk storage.
- `dense_array.DenseArray` is a generic packed array, not an ECS storage
  boundary.
- the package follow-up record is already correct that archetype storage,
  relocation, and query or view ownership belong in `static_ecs`, not here.

Concrete follow-up:

- `dense_array.swapRemove()` currently returns only the removed value. The
  earlier dense-array sketch explicitly deferred a relocation-aware result until
  an ECS-adjacent packed-storage hot path became concrete. This review is that
  concrete use case.
- ECS row storage usually needs to update an external entity-to-row reverse map
  whenever swap-remove relocates the tail element.

Recommendation:

- do not turn `DenseArray` into an ECS type;
- either:
  - keep relocation metadata entirely ECS-owned inside chunk storage; or
  - reopen `DenseArray` narrowly for an additive relocation-aware remove result
    if two or more packed-storage callers need the same generic helper.

Assessment:

- not a blocker for `static_ecs`;
- it is now a real generic-surface question instead of a hypothetical one.

#### `static_meta`

Status: ready with ECS-owned wrappers.

Why:

- `TypeId`, runtime names, and stable identity are already split correctly.
- `TypeRegistry` is deterministic, allocation-free after caller-owned storage
  setup, and good for component registration during control-plane setup.
- stable versus runtime identity is already explicit, which is important for
  ECS package design:
  - runtime ids are fine for in-process query dispatch and component
    registration;
  - stable identities are the right basis for save data, tooling, or
    cross-binary persistence.

Constraint:

- `TypeRegistry` is append-only and linear by design. That is correct for small
  bounded registries and control-plane setup, but it is not a hot-path
  archetype-query index by itself.

Recommendation:

- keep `TypeRegistry` simple;
- let `static_ecs` own any dense component-id mapping, archetype lookup index,
  or query cache keyed by component sets.

#### `static_hash`

Status: ready for correctness, not yet ideal for ECS hot-path batch shape.

Already usable:

- `combine.combineOrdered64` and `combineUnorderedMultiset64` are good scalar
  composition helpers for component-set keys.
- `fingerprint64`, `fingerprint128`, `stableFingerprint64`, and
  `stableHashAny` are usable for deterministic metadata, save-format keys, and
  archetype-signature wrappers.
- the package already protects `FlatHashMap` callers from unsafe default hashing
  of padded composite key types, which matters for ECS control-plane maps.

Current limit:

- `hash_any` and `stable` remain reflective, scalar, row-oriented entrypoints.
- the DoD report is still correct: there is no `hashMany`, batch fingerprint,
  or schema-compiled repeated-record path for high-throughput ECS signature or
  table-key workloads.

Recommendation:

- keep ECS-specific signature and archetype-key wrappers in `static_ecs`;
- do not block the first ECS slice on a generic batch-hash primitive;
- continue the active `static_hash` research plan with the ECS scenario rows it
  already names:
  - short fixed-schema signature keys;
  - repeated archetype or table keys;
  - repeated homogeneous-record hashing.

Assessment:

- not a blocker for `static_ecs` v1;
- real performance-shape ceiling for later high-throughput ECS work.

#### `static_testing`

Status: ready and strongly aligned.

Why:

- `testing.model` is almost a direct fit for structural add, remove, move,
  spawn, despawn, and command-application sequences.
- replay artifacts, failure bundles, and reduction are already appropriate for
  minimized archetype-move or relocation failures.
- `bench.workflow` is already the correct shared review surface for:
  - chunk iteration;
  - add or remove churn;
  - command-buffer apply throughput;
  - archetype-key lookup;
  - side-index rebuild and query scans.
- `ordered_effect`, `temporal`, and `liveness` are good later fits for command
  ordering or eventual repair semantics if runtime ECS adapters become more
  involved.

Needed changes:

- none in `static_testing` itself.
- `static_ecs` should plan to adopt shared testing surfaces immediately instead
  of inventing package-local harness machinery.

### Optional but important runtime or adapter substrate

#### `static_spatial`

Status: adapter-ready with one real contract blocker.

Already strong:

- `BVH` is a good read-mostly side index for entity ids or handles.
- `IncrementalBVH` is a good dynamic side index for world-owned mutation,
  refit, and query paths.
- both BVH families now report total hit count under truncation, which is the
  right query contract for callers that need bounded output buffers but still
  need to detect truncation.

Remaining blocker:

- `UniformGrid`, `UniformGrid3D`, and `LooseGrid` still return only the number
  written from `queryAABB()`, not total hits under truncation.
- this is already recorded in the active `static_spatial` plan, and it is the
  one concrete package-level mismatch that would make a generic ECS spatial
  adapter awkward or misleading.

Recommendation:

- close the bounded-grid query-contract review before shipping ECS spatial
  adapters that abstract over multiple index families.

Assessment:

- blocker for a uniform spatial-adapter story;
- not a blocker for a first ECS slice that ships without spatial adapters.

#### `static_sync`

Status: useful optional substrate, not a blocker.

Why:

- `seqlock.SeqLock` is already a good building block for single-writer,
  many-reader snapshot-style access to read-mostly ECS views.
- barriers, events, semaphores, cancellation, and condition variables are all
  useful if runtime ECS later grows worker coordination or blocking join paths.

Boundary call:

- `static_sync` should not own world phases, schedule barriers, or ECS read and
  write borrowing policy.
- `static_ecs` must still own when structural mutation is allowed and how query
  reads interact with it.

Needed changes:

- none found.

#### `static_queues`

Status: useful optional substrate, but not the first command-buffer story.

Why:

- `RingBuffer` is already a good bounded queue for event streams or runtime
  command ingress.
- `InboxOutbox` is already a useful publish barrier for single-writer,
  single-reader handoff patterns.
- the queue family is already strong for runtime systems that want bounded
  communication paths.

Important boundary call:

- the first ECS `CommandBuffer` should still be ECS-owned and probably built on
  `Vec`, not on generic queue abstractions.
- ECS command buffering is structural world policy, not just queue mechanics.

Needed changes:

- none found at package level.

#### `static_scheduling`

Status: partial fit; good for deterministic planning, not yet a true ECS
parallel scheduler substrate.

Already usable:

- `task_graph.TaskGraph` is a clean deterministic control-plane primitive for
  expressing system dependencies.
- `executor.Executor` is usable when ECS runtime work wants bounded spawned jobs
  and optional worker threads.

Current gap:

- `parallel_for.runSequential()` is explicitly sequential today.
- that is not a bug, but it means the package does not yet provide a convincing
  data-parallel ECS execution story.

Recommendation:

- keep the first ECS slice independent from scheduling policy;
- treat runtime scheduling as an optional adapter layer over `TaskGraph`,
  `Executor`, and later thread-pool work.

Assessment:

- not a blocker for ECS storage, queries, or command buffers;
- runtime ECS parallel execution remains future work.

#### `static_string`

Status: useful for names and tooling, not for hot-path identity.

Why:

- `InternPool` is deterministic, bounded, and allocation-free after setup.
- it is a good fit for component names, schema labels, debug channels, tooling,
  and editor-facing identifiers.

Constraint:

- interning remains linear-scan over stored entries and is not the right hot
  path for component-id lookup or query dispatch.

Recommendation:

- use it for names, not for the core ECS storage identity path.

#### `static_profile`

Status: useful optional instrumentation substrate.

Why:

- counters and trace export are already good fits for world-level metrics,
  schedule traces, chunk-churn counters, and command-application telemetry.

Needed changes:

- none found.

### Helpful payload or compute packages, but not ECS-boundary blockers

#### `static_math`

Status: useful as component payload math, not an ECS blocker.

Why:

- transforms, vectors, matrices, and camera conventions are already a clean
  payload library for component data and systems.

Needed changes:

- none for `static_ecs`.

#### `static_simd`

Status: useful later for SoA hot loops, not an ECS blocker.

Why:

- gather/scatter and vector math are relevant to dense ECS system kernels, but
  they do not need to be part of the initial ECS package boundary.

Needed changes:

- none for the first ECS slice.

### Later integration packages, not first-slice prerequisites

#### `static_bits`

Status: not required for the first ECS slice.

Use later for:

- tightly packed masks, stable binary layouts, or explicit bit-level persistence
  formats if ECS tooling later needs them.

#### `static_serial`

Status: not required for the first ECS slice.

Use later for:

- deterministic snapshot or replay encodings once ECS persistence exists.

#### `static_net` and `static_net_native`

Status: not required for the first ECS slice.

Use later for:

- replication, remote tooling, network snapshots, or host-boundary endpoint
  adapters.

#### `static_io`

Status: not required for the first ECS slice.

Use later for:

- runtime-heavy async world integration, external asset or stream ingestion, or
  process-boundary adapters.

#### `static_rng`

Status: useful utility, not a boundary blocker.

Use later for:

- deterministic spawn distributions, randomized but replayable simulations, or
  test scenario generation.

## Concrete lower-package changes and follow-ups

### Needed before a uniform ECS spatial-adapter story

1. `static_spatial` bounded-grid truncation contract
   `UniformGrid`, `UniformGrid3D`, and `LooseGrid` should either:
   - align to the BVH total-hit contract; or
   - keep a deliberate split with explicit docs and adapter handling.

Current recommendation:

- align them to total-hit reporting so ECS side indexes can present one bounded
  query contract.

### Newly concrete collection-surface question

1. `static_collections.dense_array` relocation-aware removal result

Reason:

- ECS row storage and reverse maps make "tail element moved into slot X"
  concrete, not hypothetical.

Current recommendation:

- prefer keeping the first implementation ECS-owned inside archetype or chunk
  storage;
- reopen `DenseArray` only if the same relocation helper proves generically
  reusable outside ECS-owned chunk storage.

### Performance-shape follow-on, not a blocker

1. `static_hash` batch-shape research

Reason:

- ECS archetype signatures and repeated fixed-schema rows are real workloads,
  but the first package slice can own adapters over the current scalar
  primitives.

Current recommendation:

- continue the existing research plan instead of forcing a premature generic
  batch API into `static_hash`.

## What should stay ECS-owned

The review does not support pushing these down into lower packages:

- `Entity`
- `World`
- `ComponentRegistry` wrapper
- `ArchetypeKey`
- `Chunk`
- `ArchetypeStore`
- entity-to-row and row-to-entity relocation policy
- structural add or remove component moves
- `Query`
- `View`
- `CommandBuffer`
- world-owned spatial adapters
- runtime ECS scheduling policy

Those are the actual missing pieces.

## Recommended first implementation slice

1. `Entity` plus `EntityPool`
   Backed by `Handle` and `IndexPool`, but with world-local ECS semantics.
2. `ComponentRegistry`
   ECS wrapper over `static_meta`, with explicit runtime versus stable-id policy.
3. `ArchetypeKey`
   ECS-owned component-set signature wrapper over `static_hash`.
4. `Chunk` plus `ArchetypeStore`
   ECS-owned SoA storage, relocation, and row mapping.
5. `CommandBuffer`
   ECS-owned deterministic structural batches, likely staged in `Vec`.
6. `Query` / `View`
   Dense chunk iteration with mutation kept separate from structural changes.

Do not start with:

- runtime scheduling policy
- networking
- serialization
- editor reflection
- spatial adapters
- a generic batching package

## Build and repo-shape implications

The repo is already centralized around the root `build.zig`.

Adding `static_ecs` later will need:

- a new root module registration in `build.zig`;
- explicit dependency wiring against the lower packages it imports;
- package tests wired through the root workspace test surface;
- example and benchmark admission decisions made the same way other packages do;
- repo docs updates in `README.md`, `AGENTS.md`, and `docs/architecture.md`.

That is normal repo work, not a design blocker.

## Final assessment

The repo is ready for a first real `static_ecs` package.

The current blockers are narrow and specific:

- fix the bounded-grid query contract in `static_spatial` before promising one
  uniform spatial-adapter layer;
- make an explicit decision on whether relocation-aware swap-remove metadata
  remains ECS-owned or deserves a generic `DenseArray` helper;
- keep `static_hash` batch-shape work as a sidecar instead of blocking ECS v1.

Everything else important is already in place as reusable substrate, and the
remaining missing work is correctly ECS-owned rather than evidence that the
lower packages were shaped incorrectly.
