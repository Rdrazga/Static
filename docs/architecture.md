# Architecture

This workspace is organized as a layered set of `static_*` packages rather than a single monolithic library.

## Layers

- **Foundation:** `static_core`, `static_bits`, `static_hash`, `static_meta`, `static_rng`, `static_string`
- **Storage and collections:** `static_memory`, `static_collections`
- **State and ECS:** `static_ecs`
- **Coordination and runtime:** `static_sync`, `static_queues`, `static_scheduling`, `static_io`
- **Protocol and harness tooling:** `static_serial`, `static_net`, `static_profile`, `static_testing`
- **Math and spatial:** `static_math`, `static_simd`, `static_spatial`

## Dependency direction

Higher layers may depend on lower layers, but lower layers should remain reusable and avoid pulling in runtime-specific concerns.

Examples:

- `static_io` reuses `static_memory`, `static_queues`, `static_sync`, and `static_net`.
- `static_scheduling` reuses `static_sync` and `static_collections`.
- `static_sync` owns capability-gated waiting/cancellation plus bounded
  coordination contracts; raw host mutex/condition usage stays in `std.Thread`.
- `static_io` keeps runtime and backend ownership package-local while now using
  `static_testing` for bounded `testing.system`, `testing.process_driver`,
  shared subsystem-simulator, seeded fuzz, simulator failure-plan matrices,
  and benchmark-workflow review.
- `static_serial` and `static_net` stay focused on data representation and framing rather than syscall ownership.
- `static_bits` keeps compile-time misuse checks package-local while now using
  `static_testing` only for runtime malformed-input replay/fuzz coverage and
  shared cursor/varint benchmark review.
- `static_serial` keeps framing transport-agnostic while now using
  `static_testing` for retained malformed-frame replay/fuzz coverage,
  sequence-sensitive incremental `testing.model` review, and shared
  serialization benchmark workflows.
- `static_net` keeps protocol utilities transport-agnostic while now using
  `static_testing` for retained malformed-frame replay/fuzz coverage,
  sequence-sensitive incremental decoder `testing.model` review, and shared
  protocol benchmark workflows.
- `static_net_native` keeps OS-native socket address ownership package-local
  while now using `static_testing` for retained sockaddr replay/fuzz coverage,
  bounded live loopback `testing.system` proof, and shared conversion
  benchmark workflows.
- `static_rng` keeps deterministic generator and sampling ownership
  package-local while now using `static_testing` for sequence-sensitive
  stream-lineage modeling, retained seed replay/failure-bundle coverage,
  shared generator/distribution benchmark workflows, and an explicit bounded
  pathological-engine contract for `uintBelow()`.
- `static_hash` keeps hashing and fingerprint ownership package-local while
  now using `static_testing` for shared benchmark review artifacts across byte,
  combine, fingerprint, and structural suites.
- `static_queues` keeps queue-family ordering and handoff ownership
  package-local while now using `static_testing` for shared ring-buffer, SPSC,
  and disruptor throughput benchmark workflows plus package-owned
  `testing.model` queue-runtime review and temporal proof for
  `InboxOutbox` publish barriers plus `Broadcast` fanout/backpressure
  ordering, plus bounded `testing.sim.explore` proof for `WaitSet`
  channel-selection rotation and close semantics.
- `static_memory` keeps allocator and ownership policy package-local while now
  using `static_testing` for shared pool alloc/free benchmark workflows and
  package-owned `testing.model` pool, arena, slab, and budgeted-allocator
  lifecycle/accounting/misuse review, with `Budget.release()` now failing fast
  on over-release in all builds.
- `static_collections` keeps bounded container ownership package-local while
  now using `static_testing` for package-owned `SlotMap`, `IndexPool`, `Vec`,
  `FlatHashMap`, `SortedVecMap`, and `SparseSet` mutation/resource-boundary
  sequence review, a package-owned negative compile-contract harness for the
  main generic `@compileError` boundaries, direct `SlotMap` iterator
  visibility proof including the read-only iterator path, shared
  `flat_hash_map` benchmark-workflow review, an explicit `Vec`
  oversized-capacity operating-error contract before allocator or budget side
  effects, `SmallVec` read/reset parity without hiding the one-way spill
  boundary, and public `SortedVecMap` / `FlatHashMap` iterator surfaces that
  keep map keys immutable through iteration plus additive borrowed
  lookup/removal helpers, aligned bounded `getOrPut` plus `removeOrNull`
  helpers for the map families, and dual by-value or `*const` callback
  signatures for the affected map and heap families, with `SortedVecMap`
  comparator-signature validation now firing at type instantiation,
  while the root surface keeps the `memory` alias and cuts the `core` and
  `hash` aliases.
- `static_ecs` keeps world-local ECS storage, bounded identity allocation,
  typed component-universe admission, `ArchetypeKey`, bounded chunk layout,
  ECS-owned archetype relocation, typed query/view ownership, and bounded
  structural command staging package-local while reusing `static_memory` and
  `static_collections` for the current world-local core; typed insert/remove
  helpers now own initialized value-component admission, raw value-adding
  archetype moves are rejected until the caller provides initialization, the
  package now uses `static_testing` for bounded command-buffer runtime-sequence
  review, and deferred runtime-erased queries, import/export, spatial
  adapters, and scheduler-facing surfaces remain out of the first package
  boundary.
- `static_scheduling` keeps scheduler coordination policy package-local while
  now using `static_testing` for replay-backed task-graph invariants,
  sequence-sensitive timer-wheel review, shared planning benchmark workflows,
  timer-queue sim/explore/temporal ordering proof, and retained exploration
  provenance replay, while package-owned executor join-timeout integration now
  covers one real blocked-worker path and the stale `static_queues` build
  wiring has been removed.
- `static_sync` keeps synchronization ownership package-local while now using
  `static_testing` for replay-backed single-object campaigns, wait/wake
  simulation and temporal proof, package-owned `Barrier` phase/generation and
  `SeqLock` token/retry model coverage, retained misuse persistence, and
  shared fast-path plus bounded-contention benchmark workflows.
- `static_meta` keeps compile-time identity and bounded registry ownership
  package-local while now using `static_testing` narrowly for runtime registry
  mutation and lookup sequence review.
- `static_profile` keeps bounded trace/counter ownership package-local while
  now using package-level integration tests for exact mixed export shape,
  hook-preserved ordering, and counter lifecycle regressions.
- `static_math` keeps scalar/vector/matrix/transform ownership package-local
  while now using package-level integration tests for camera/lookAt
  conventions and exact TRS roundtrip proof.
- `static_simd` keeps lane-parallel math and memory helpers package-local
  while now using replay-backed differential integration tests for bounded
  scalar-vs-SIMD trig input families.
- `static_spatial` keeps geometry primitives and spatial indexing structures
  package-local while now using package-level integration tests for
  `IncrementalBVH` insert/query/refit/remove/reuse lifecycle proof plus
  bounded `testing.model` mutation/query sequences and a retained
  replay/failure roundtrip for inclusive query-boundary semantics, with
  `IncrementalBVH` query reporting now aligned to `BVH` total-hit semantics.
- `static_core` keeps policy-light shared contracts package-local while now
  using package-level integration tests for root-surface negative-path and
  vocabulary classification proof.
- `static_string` keeps bounded text storage and interning package-local while
  now using `static_testing` for malformed-text replay/fuzz coverage,
  sequence-sensitive `testing.model` intern-pool review, and shared validation
  and interning benchmark workflows.
- `static_testing` reuses lower layers to provide deterministic seeds, replay,
  corpus, state-machine harnesses with API-state, protocol-state, and sim-backed
  model
  examples, simulation fixtures, bounded `testing.sim.explore` portfolio and
  PCT-style schedule exploration, benchmark-baseline review workflows with
  canonical `ZON` baseline documents, bounded binary benchmark-history and
  exploration artifacts, shared benchmark text reports with derived `ns/op`,
  `ops/s`, and tail-latency summaries plus caller-supplied environment notes,
  bounded caller-owned environment tags for compatibility filtering, canonical
  failure-bundle `ZON` sidecars plus optional
  retained `trace_events.binlog` trace sidecars, optional typed retained
  pending-reason metadata in `manifest.zon`, optional typed `actions.zon`
  model sidecars, bounded causal/provenance trace summaries, bounded temporal
  assertions over retained traces, reusable subsystem simulators such as
  `sim.network_link`, `sim.storage_lane`, `sim.storage_durability`, and
  `sim.retry_queue`, with `sim.network_link` now supporting bounded
  node-isolation partitions, directed/group partitions, route-matched
  drop/extra-delay fault rules, route-specific congestion windows,
  route-matched backlog saturation with explicit overflow behavior, and
  bounded caller-owned pending-delivery snapshot/replay and
  `sim.storage_durability` now supporting bounded crash/recover plus
  read/write corruption policies, an explicit post-recover stabilization
  guardrail, bounded caller-owned state snapshot/replay over pending
  operations and stored values, bounded misdirected-write placement faults,
  and acknowledged-but-not-durable write omission faults and
  `testing.sim.clock.RealtimeView` now supporting bounded
  reference-time offset/drift projections over the same monotonic clock and
  `testing.ordered_effect` now supporting bounded duplicate/stale-aware
  out-of-order effect release, a bounded
  `testing.liveness` repair/convergence helper with typed pending reasons, a
  bounded `testing.system` repair/convergence bridge over the same fixture,
  trace, and failure-bundle surfaces, a bounded `testing.system`
  composition harness for multi-component and process-boundary deterministic
  flows, retained provenance through
  model/swarm/system and exploration persistence, including retained swarm
  failures forwarding the same typed pending-reason metadata, smoke/harnessed
  package-owned system examples, a smoke/harnessed bounded swarm campaign
  example, shared binary swarm campaign records with
  deterministic resume support, shard partitioning, bounded
  campaign-summary/retained-seed helpers, bounded worker-lane host-thread swarm
  execution with deterministic commit order, and shared internal artifact
  helpers without leaking those concerns into production packages. Simulator
  boundary expansion follows
  `docs/decisions/2026-03-21_static_testing_simulator_boundary.md`.

## Build model

The workspace build is intentionally centralized in the root `build.zig`.
Individual package directories contain local build files, but the supported
validation path is the root workspace so that package-local integration tests
and cross-package imports stay consistent.

Root command semantics are intentionally split between pass/fail validation and
review-only surfaces: `zig build test`, `zig build harness`,
`zig build examples`, and `zig build ci` are pass/fail validation commands,
while `zig build bench` remains review-only by default unless a benchmark
workflow explicitly opts into gating.

Primary repository entry points are:

- `docs/README.md` for the top-level documentation map.
- `AGENTS.md` for operational bootstrapping.
- `README.md` for the command surface.
- Package-scoped `README.md` / `AGENTS.md` files when a package needs extra
  operational guidance; `packages/static_io/README.md` and
  `packages/static_io/AGENTS.md` plus `packages/static_ecs/README.md` and
  `packages/static_ecs/AGENTS.md` are current package-local examples.
- `docs/plans/README.md` for implementation workflow.
- `docs/reference/zig_coding_rules.md` for the detailed coding contract.

## Status model

- Active work: `docs/plans/active/`
- Completed work and review history: `docs/plans/completed/`
- Exploratory design sketches: `docs/sketches/`
- Stable design notes: `docs/design/`
- Decision records: `docs/decisions/`
- Package-scoped operational docs live alongside packages when needed, such as
  `packages/static_io/README.md` and `packages/static_io/AGENTS.md`
