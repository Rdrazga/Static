# `static` workspace guide
Start here when you need to boot, navigate, or extend the repository.
## Source of truth
- `README.md` for the workspace entry point and common commands.
- `docs/architecture.md` for package boundaries and dependency direction.
- `docs/plans/active/README.md` and `docs/plans/active/workspace_operations.md` for the current work queue, priorities, and sequencing.
- `docs/plans/README.md` for the overall planning system, including active and completed work.
- `docs/reference/zig_coding_rules.md` for the Zig rules index and task-specific rule links.
- `packages/static_testing/README.md` and `packages/static_testing/AGENTS.md` for the shared deterministic harness package entry points.
## Supported commands
- `zig build docs-lint`
- `zig build check`
- `zig build test` - pass/fail correctness surface
- `zig build harness` - success-only smoke validation
- `zig build examples` - builds examples, including retained-failure demos
- `zig build bench` - review-only by default unless a slice opts into gating
- `zig build ci` - aggregate pass/fail validation surface
## Working agreements
- Use the root `build.zig` as the supported validation surface.
- Plan non-trivial work in `docs/plans/active/` and move finished plans to `docs/plans/completed/`.
- Keep `docs/plans/active/` sparse: only work with concrete unfinished steps belongs there; closed plans and trigger-only follow-up belong in `docs/plans/completed/`.
- Keep `docs/plans/active/workspace_operations.md` and matching `docs/plans/active/packages/*.md` current while work is in flight.
- Write active tasks as ordered SMART steps with the exact surface,
  completion signal, and validation command.
- Keep repository knowledge current when behavior changes: update `AGENTS.md`, `README.md`, `docs/architecture.md`, and the relevant plan or reference doc in the same change.
- Update the specific Zig rules document that matches the task rather than growing a monolithic rules file again.
- Keep harness work deterministic. New fuzz, replay, simulation, and benchmark flows should expose explicit seeds, bounded artifacts, and replayable failure inputs through `static_testing`.
- Prefer shared `static_testing` review artifacts over ad hoc files. Benchmark
  workflows should keep using versioned `baseline.zon` plus bounded binary
  history sidecars rather than package-local artifact formats while the wider
  storage migration is still in flight. Retained deterministic failures should
  prefer canonical `manifest.zon`, `trace.zon`, `violations.zon`, and shared
  binary replay/record artifacts over new JSON sidecars.
- Put repository automation in `scripts/*.zig` rather than shell scripts.
## Package map
- `static_core`: Core error vocabulary, config validation, and shared base contracts, with package-level root-surface negative-contract integration coverage.
- `static_bits`: Bit-level readers, writers, layouts, cursors, varint helpers,
  and package-owned malformed-input replay/fuzz plus shared benchmark adoption.
- `static_hash`: Stable hashing, checksums, and fingerprint primitives, with shared benchmark-workflow adoption for byte, combine, fingerprint, and structural review artifacts.
- `static_meta`: Compile-time type IDs, registries, and metadata helpers, with bounded runtime registry mutation and lookup coverage through `testing.model`.
- `static_rng`: Deterministic random number generators and sampling helpers, sequence-sensitive `testing.model` stream-lineage coverage, retained seed replay/failure-bundle proofs, shared generator/distribution benchmark workflows, and an explicit bounded pathological-engine contract for `uintBelow()`.
- `static_string`: Bounded string, ASCII, UTF-8, and string-pool utilities, package-owned malformed-text replay/fuzz coverage, sequence-sensitive `testing.model` intern-pool adoption, and shared validation/interner benchmark workflows.
- `static_memory`: Budgets, arenas, pools, slabs, and bounded allocation patterns, with shared benchmark-workflow adoption for pool alloc/free review artifacts, package-owned `testing.model` coverage for pool allocation/release/reuse/reset/exhaustion behavior, arena reset/reuse/high-water accounting sequences, slab class-routing/reuse/invalid-free misuse paths, budgeted-allocator accounting for budget denial vs parent OOM plus growth/shrink and `takeDeniedLast()` behavior, and a fail-fast `Budget.release()` over-release contract in all builds.
- `static_collections`: Fixed-capacity and allocation-aware collection types, with package-owned `testing.model` coverage for `SlotMap` runtime mutation sequences, `IndexPool` handle invalidation/reuse/exhaustion behavior, `Vec` budget-aware growth/exact-capacity fallback/NoSpaceLeft stability plus an explicit oversized-capacity `Overflow` contract before allocator or budget side effects, `FlatHashMap` collision-heavy runtime mutation sequences under borrowed callback paths, `SortedVecMap` ordered borrowed-lookup runtime sequences, and `SparseSet` dense-membership runtime sequences, plus a package-owned negative compile-contract harness for the main generic `@compileError` boundaries in `FlatHashMap`, `SortedVecMap`, and `MinHeap`, `SmallVec` read/reset parity on top of its one-way spill contract, `SortedVecMap` and `FlatHashMap` public iterator surfaces with const keys and mutable values where safe, additive borrowed lookup/removal helpers for the map families, aligned bounded `getOrPut` plus `removeOrNull` helper surfaces for the two map implementations, dual by-value or `*const` comparator/hash/equality callback support across the affected map and heap surfaces, `MinHeap` / `PriorityQueue` tracked-index invalidation now proved on clear, pop, and indexed removal paths, `FlatHashMap` default hashing now gated away from padded key types unless callers provide a custom hash, `SortedVecMap` comparator-signature validation now firing at type instantiation, direct `SlotMap` iterator handle/value visibility proof including the read-only iterator path, shared benchmark-workflow adoption for `flat_hash_map` lookup-hit and insert/remove churn review artifacts, and the root surface now narrowed to the collection families plus the retained `memory` alias.
- `static_ecs`: World-local typed ECS building blocks, now in first-slice implementation with explicit `WorldConfig` bounds, ECS-owned `Entity` identity, bounded `EntityPool` allocation, typed component-universe admission, `ArchetypeKey`, bounded `Chunk` layout, ECS-owned `ArchetypeStore` relocation with direct config-bound parity and occupied-slot alias rejection, typed query/view hot paths, a first bounded `CommandBuffer`, package-owned direct swap-reindex proof plus a `testing.model` sequence proof for mixed structural mutation, and a `World(comptime Components)` shell with typed insert/remove helpers, while runtime-erased queries, import/export, and side-index adapters remain deferred in the package plan.
- `static_sync`: Synchronization primitives, cancellation, and coordination building blocks, with replay-backed primitive campaigns, shared `testing.sim.fixture` wait/wake protocol modeling, temporal ordering checks, package-owned `testing.model` barrier and seqlock proof slices, host-thread smoke coverage, and shared benchmark-workflow adoption.
- `static_queues`: Queue, channel, inbox, outbox, and handoff structures, with shared benchmark-workflow adoption for ring-buffer, SPSC, and disruptor throughput review artifacts plus package-owned `testing.model` coverage for channel close/wraparound and ring-buffer FIFO/batch/discard/contiguous-peek/overwrite runtime sequences, temporal publish-barrier coverage for `InboxOutbox` and broadcast fanout/backpressure ordering, and bounded `testing.sim.explore` coverage for `WaitSet` channel-selection rotation and close semantics.
- `static_scheduling`: Task-graph and scheduler-oriented coordination utilities, with replay-backed task-graph invariants, `testing.model` timer-wheel coverage, shared planning benchmark workflows, package-owned timer-queue sim/explore/temporal ordering coverage, retained exploration provenance replay, executor join-timeout integration coverage, and stale `static_queues` build wiring removed.
- `static_io`: I/O runtime pieces, backends, and buffer-pool integration, now serving as the runtime-heavy downstream adopter for `testing.system`, `testing.process_driver`, shared subsystem simulators, seeded runtime/buffer fuzzing, and shared benchmark workflows, including a composed process-driver-plus-runtime system proof and a bounded simulator failure-plan matrix over storage/retry flows.
- `static_serial`: Binary framing, readers, writers, wire-format helpers, package-owned malformed-frame replay/fuzz coverage, incremental `testing.model` adoption, and shared benchmark workflows.
- `static_net`: Network-facing address, frame, and protocol utilities, package-owned malformed-frame replay/fuzz coverage, incremental decoder `testing.model` adoption, and shared benchmark workflows.
- `static_net_native`: OS-native network endpoint and socket-address bridging, package-owned sockaddr replay/fuzz coverage, bounded loopback `testing.system` adoption, and shared conversion benchmark workflows.
- `static_profile`: Counters, hooks, and trace-export instrumentation, with package-level export-shape and hook-ordering integration coverage.
- `static_math`: Scalar, vector, matrix, transform, and camera math, with package-level integration coverage for camera/lookAt conventions and exact TRS roundtrips.
- `static_testing`: Deterministic harnesses for replay, fuzz, state machines, API/protocol-state/sim-backed model examples, simulation fixtures, bounded `testing.sim.explore` portfolio and PCT-style schedule exploration, reusable subsystem simulators such as `sim.network_link`, `sim.storage_lane`, `sim.storage_durability`, and `sim.retry_queue` with simulator expansion governed by `docs/decisions/2026-03-21_static_testing_simulator_boundary.md`, `sim.network_link` now supporting bounded node-isolation partitions, directed/group partitions, route-matched drop/extra-delay fault rules, route-specific congestion windows, route-matched backlog saturation with explicit overflow behavior, and bounded pending-delivery snapshot/replay over caller-owned `Delivery` buffers, `sim.storage_durability` now supporting bounded crash/recover plus read/write corruption policies, an explicit post-recover stabilization guardrail, bounded caller-owned state snapshot/replay over pending-operation and stored-value buffers, bounded misdirected-write placement faults, and acknowledged-but-not-durable write omission faults, `testing.sim.clock.RealtimeView` now supporting bounded reference-time offset/drift projections over the same monotonic clock for lease, timeout, and other clock-sensitive protocol studies, and `testing.ordered_effect` now supporting bounded duplicate/stale-aware reassembly of out-of-order effects into one expected sequence, a bounded `testing.liveness` repair/convergence helper with typed pending reasons, a bounded `testing.system` repair/convergence bridge over the same fixture/trace/failure-bundle surface, a bounded `testing.system` composition harness for deterministic multi-component and process-boundary flows with multiple downstream adopters plus smoke/harnessed package-owned system examples, benchmark baseline review workflows, bounded binary benchmark history/exploration artifacts, caller-owned benchmark environment notes and bounded environment tags for compatibility filtering, canonical bounded failure-bundle `ZON` sidecars with optional typed retained pending-reason metadata in `manifest.zon`, optional retained `trace_events.binlog` trace sidecars, optional typed `actions.zon` model sidecars, bounded causal/provenance trace summaries, retained provenance through model/swarm/system and exploration persistence, a smoke/harnessed bounded swarm campaign example with retained pending-reason forwarding on the same bundle contract, shared binary swarm campaign records with deterministic resume support, shard partitioning, bounded campaign-summary/retained-seed helpers, bounded worker-lane host-thread swarm execution with deterministic commit order, and bounded temporal assertions over deterministic traces.
- `static_simd`: SIMD-oriented math and memory operations, with replay-backed trig differential integration coverage over bounded deterministic input families.
- `static_spatial`: Spatial indexing, BVH, and uniform-grid structures, with package-level `IncrementalBVH` lifecycle integration coverage plus bounded `testing.model` mutation/query sequences for insert/refit/remove/reinsert/overlap flows, a retained replay/failure roundtrip for inclusive boundary-touching query semantics, and `IncrementalBVH` total-hit query reporting aligned with `BVH`.
## Repo shape
- `packages/` holds the `static_*` libraries separated by concern and dependency layer.
- Each `packages/static_*/` root carries scoped `README.md` and `AGENTS.md` entry points; keep them aligned in structure, semantics, and root-command wording.
- Package-local docs should stay map-like: `AGENTS.md` for fast operational guidance and `README.md` for package purpose, scope, validation, and key paths.
- Package-owned `tests/` directories hold integration coverage inside the package boundary being validated.
- `docs/reference/` holds stable rules and contracts.
- `docs/sketches/` holds exploratory notes that are not yet stable.
## Change checklist
- Add or update a plan before large implementation work.
- Extend `zig build harness` when adding new first-class harness workflows.
- Extend `scripts/docs_lint.zig` when you add a new source-of-truth document or required cross-link.
## Core Repo Ideologies
- Every function should maintain a minimum of 2 assertions covering preconditions and postconditions. Assertions can also serve as stronger documentation of behavior and ensure fail-fast behavior in `ReleaseSafe` or `Debug` modes.
- Every implementation made should consider data-oriented-design.
- The packages should remain thoroughly tested using Zig's `std.testing`, `std.debug` when useful, and should always consider where and how to integrate `static_testing` simulations, testing helpers, and benchmarking.
- Napkin math for CPU, memory, disk, network, and the connections between them should be considered when designing functions.
- Where reasonable, the packages should maintain (or provide a pathway for package consumers to choose if there would be negative side-effects) bounded resource use, zero post-init allocation options, and where allocating carefully avoid and test for memory issues.
- Clear or traceable code execution, maintainable minimized-tech debt code, clear control flows.
- Safety and Performance are top priorities (True performance based on DoD), followed by DX, readable, traceable, and understandable code, followed by the code being highly tested and simulated to strive for 0-error code.
- Maintain documentation and decisions in-repo.
