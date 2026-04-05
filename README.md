# `static`

Workspace for the `static_*` Zig packages.

## Current status

- The root workspace build is the supported entry point.
- Repository guidance is anchored in `AGENTS.md`, `docs/architecture.md`, and `docs/plans/README.md`.
- The shared simulator boundary is locked by
  `docs/decisions/2026-03-21_static_testing_simulator_boundary.md`.
- Unit tests, package-local integration tests, harness smoke validation,
  examples, docs topology checks, and CI-style aggregate steps are wired
  through `build.zig`.
- `static_testing` now includes shared state-machine harnesses with API-state,
  protocol-state, and sim-backed model examples, `baseline.zon` benchmark review artifacts,
  bounded binary benchmark-history and exploration sidecars, canonical
  benchmark text reports with derived `ns/op`, `ops/s`, and tail-latency
  summaries, caller-supplied benchmark environment notes and bounded
  compatibility tags,
  `manifest.zon` / `violations.zon` plus optional `trace.zon` /
  `trace_events.binlog` failure-bundle sidecars, optional typed `actions.zon`
  model sidecars, optional typed retained pending-reason metadata in
  `manifest.zon`, bounded causal/provenance trace summaries, bounded temporal
  assertions over deterministic traces, deterministic simulation-fixture
  workflows, bounded `testing.sim.explore` portfolio and PCT-style
  schedule-exploration modes, bounded subsystem simulators for network delivery, storage
  completions, storage durability, retry scheduling, and opt-in clock
  drift/offset projection, plus a bounded ordered-effect reassembly helper,
  with network delivery
  now also supporting bounded node-isolation partitions, directed/group
  partitions, route-matched drop/extra-delay rules, route-specific congestion
  windows, route-matched backlog saturation with explicit overflow behavior,
  and bounded pending-delivery snapshot/replay over caller-owned `Delivery`
  buffers
  and storage durability now supporting bounded crash/recover plus read/write
  corruption policies, an explicit post-recover stabilization guardrail, and
  bounded caller-owned state snapshot/replay over pending-operation and
  stored-value buffers plus bounded misdirected-write placement faults and
  acknowledged-but-not-durable write omission faults and
  `testing.sim.clock.RealtimeView` now supporting bounded reference-time
  offset/drift projection for lease and timeout studies and
  `testing.ordered_effect` now supporting bounded duplicate/stale-aware
  out-of-order effect release, a
  bounded repair/liveness execution
  helper with typed pending reasons, a bounded `testing.system`
  repair/convergence bridge over the same fixture/trace/failure-bundle
  surface,
  plus a bounded `testing.system`
  composition harness for deterministic multi-component and process-boundary
  flows and retained failures, with the package-owned system and swarm
  examples now promoted onto the supported smoke/harness surfaces, and with
  retained provenance now flowing through
  model, swarm, system, and exploration persistence, with retained swarm
  failures now also able to carry typed pending-reason metadata on the same
  bundle contract, plus shared binary swarm
  campaign records with deterministic resume support, deterministic shard
  partitioning, and bounded campaign-summary/retained-seed triage helpers, plus
  bounded worker-lane host-thread swarm execution with deterministic main-thread
  commit order.
- `static_bits` now serves as the first foundation-package downstream adopter
  of `static_testing` replay/fuzz malformed-input coverage and shared
  cursor/varint benchmark workflows.
- `static_serial` now serves as the first parser/codec downstream adopter of
  `static_testing` incremental `testing.model`, retained malformed-frame
  replay/fuzz coverage, and shared serialization benchmark workflows.
- `static_net` now serves as the protocol-framing downstream adopter of
  `static_testing` retained malformed-frame replay/fuzz coverage, incremental
  `testing.model` decoder review, and shared protocol benchmark workflows.
- `static_net_native` now serves as the host-boundary downstream adopter of
  `static_testing` sockaddr replay/fuzz coverage, bounded loopback
  `testing.system` proof, and shared endpoint/socket-address conversion
  benchmark workflows.
- `static_string` now serves as the bounded-text downstream adopter of
  `static_testing` malformed-text replay/fuzz coverage, sequence-sensitive
  `testing.model` intern-pool review, and shared validation and interning
  benchmark workflows.
- `static_rng` now serves as the deterministic-generator downstream adopter of
  `static_testing` sequence-sensitive stream-lineage modeling, retained
  seed replay/failure-bundle coverage, shared generator/distribution
  benchmark workflows, and an explicit bounded pathological-engine contract for
  `uintBelow()`.
- `static_hash` now uses shared benchmark-workflow review artifacts for its
  canonical byte, combine, fingerprint, and structural benchmark suites.
- `static_sync` now serves as the first synchronization-heavy downstream proof
  for replay, shared `testing.sim.fixture` wait/wake modeling, temporal
  ordering checks, retained failures, package-owned `testing.model` coverage
  for `Barrier` phase/generation closure and reuse semantics plus `SeqLock`
  token/retry invariants, and shared fast-path/contention benchmark workflows.
- `static_io` remains the runtime-heavy downstream adopter for
  `testing.system`, `testing.process_driver`, shared subsystem simulators,
  seeded runtime/buffer fuzzing, and shared benchmark workflows, and it now
  also has a composed `testing.system` proof that combines process-driver and
  runtime retry behavior under one retained-provenance run plus a bounded
  simulator failure-plan matrix for immediate-success, retry-success, and
  retry-exhaustion outcomes.
- `static_scheduling` now has package-level timer-queue simulation,
  exploration, temporal ordering, and retained exploration provenance coverage
  for cancel-before-tick and due-order behavior, plus executor join-timeout
  integration coverage, and its stale `static_queues` build wiring has been
  removed.
- `static_collections` now has package-level `testing.model` coverage for
  `SlotMap` runtime mutation sequences, `IndexPool` handle invalidation,
  generation-bump reuse, and exhaustion behavior, `Vec`
  budget-aware growth, exact-capacity fallback, `NoSpaceLeft` stability,
  an explicit oversized-capacity `Overflow` contract before allocator or
  budget side effects, append/pop order, and budget accounting, plus
  collision-heavy `FlatHashMap`, ordered borrowed-lookup `SortedVecMap`, and
  dense-membership `SparseSet` runtime sequences, a package-owned negative
  compile-contract harness for the main generic `@compileError` boundaries in
  `FlatHashMap`, `SortedVecMap`, and `MinHeap`, `SmallVec` read/reset parity
  on top of its one-way spill contract, direct `SlotMap` iterator handle/value
  visibility coverage including the read-only iterator path, public
  `SortedVecMap` and `FlatHashMap` iterator surfaces with const keys and
  mutable values where safe, additive borrowed lookup/removal helpers for the
  map families, aligned bounded `getOrPut` plus `removeOrNull` helper surfaces
  for the two map implementations, dual by-value or `*const`
  comparator/hash/equality callback support across the affected map and heap
  surfaces, `SortedVecMap` comparator-signature validation at type
  instantiation, and shared benchmark-workflow adoption for `flat_hash_map`
  lookup-hit and insert/remove churn review artifacts, while the root surface
  now keeps only the collection families plus the `memory` alias.
- `static_meta` now serves as the narrow runtime-registry downstream adopter of
  `static_testing` bounded mutation and lookup sequence review.
- `static_profile` now has package-level integration coverage for exact mixed
  trace export shape, hook-preserved counter ordering, and bounded
  counter-buffer lifecycle behavior.
- `static_math` now has package-level integration coverage for camera/lookAt
  conventions and exact TRS roundtrips.
- `static_simd` now has replay-backed trig differential integration coverage
  over bounded deterministic scalar-vs-SIMD input families.
- `static_core` now has package-level root-surface negative-contract coverage
  for shared config, error, option, and timeout vocabulary behavior.
- `static_spatial` now has package-level `IncrementalBVH` lifecycle
  integration coverage for insert/query/refit/remove/reuse flows plus bounded
  `testing.model` mutation/query sequences for refit movement, overlap
  handling, reinsertion after drain, and stable empty behavior, plus a
  retained replay/failure roundtrip for inclusive boundary-touching query
  semantics, with `IncrementalBVH` query reporting now aligned to `BVH`
  total-hit semantics.
- `static_queues` now has shared benchmark-workflow adoption for SPSC, ring
  buffer, and disruptor throughput review artifacts plus package-owned
  `testing.model` and temporal coverage for channel close/wraparound,
  ring-buffer runtime sequences, `InboxOutbox` publish barriers, and
  `Broadcast` fanout/backpressure ordering, plus bounded `testing.sim.explore`
  coverage for `WaitSet` selection rotation, buffered-before-closed delivery,
  and closed-peer handling.
- `static_memory` now has shared benchmark-workflow adoption for pool
  alloc/free review artifacts plus package-owned `testing.model` coverage for
  pool lifecycle, arena reset/reuse sequences, slab class routing/reuse/misuse
  paths, and `BudgetedAllocator` accounting for budget denial vs parent OOM,
  growth/shrink, `takeDeniedLast()`, and overflow/high-water behavior, with
  `Budget.release()` now failing fast on over-release in all builds.
- `static_ecs` is now in first-slice implementation as a world-local typed ECS
  core, currently covering explicit `WorldConfig` bounds, ECS-owned `Entity`
  identity, bounded `EntityPool` allocation, typed component-universe
  admission, `ArchetypeKey`, bounded `Chunk` layout, ECS-owned
  `ArchetypeStore` structural mutation, typed query/view chunk-batch hot
  paths, a first bounded `CommandBuffer`, and typed `World.insert()` /
  `World.remove()` helpers, with raw value-adding archetype moves now rejected
  until the caller provides typed initialization data, plus package-owned
  `testing.model` coverage for mixed command-buffer structural sequences.
- Active implementation work lives in `docs/plans/active/`, and that tree is
  kept to concrete in-flight work only.
- Active plans use ordered SMART tasks: each open step names the exact surface,
  completion signal, and validation command rather than calendar dates.
- Historical plans, reviews, and implementation records live in `docs/plans/completed/`.

## Common commands

- `zig build docs-lint`: repository docs topology and source-of-truth checks.
- `zig build check`: compile-oriented validation across the workspace.
- `zig build test`: primary pass/fail correctness surface for unit and
  integration coverage.
- `zig build harness`: success-only deterministic smoke validation for shared
  `static_testing` harness surfaces.
- `zig build examples`: build all examples, including retained-failure demos
  that are intentionally kept off the `harness` smoke surface.
- `zig build bench`: benchmark review surface; baseline comparisons report
  regressions but do not fail the build unless a workflow opts into gating.
- `zig build ci`: aggregate pass/fail validation over docs lint, tests, harness
  smoke, and example builds.

## Package groups

- Foundations: `static_core`, `static_bits`, `static_hash`, `static_meta`, `static_rng`, `static_string`
- Data structures: `static_collections`, `static_memory`, `static_queues`
- State and ECS: `static_ecs`
- Systems/runtime: `static_sync`, `static_io`, `static_scheduling`, `static_net`
- Harness/tooling: `static_profile`, `static_serial`, `static_testing`
- Math/performance: `static_math`, `static_simd`, `static_spatial`

## Docs

- `AGENTS.md` is the fast operational repo map.
- `docs/architecture.md` gives the current package-level map.
- `docs/plans/README.md` explains the planning workflow and directory layout.
- `docs/plans/active/` tracks only in-flight work.
- `docs/plans/completed/` preserves completed plans and review history.
- `docs/reference/zig_coding_rules.md` holds the detailed Zig coding contract.
- `docs/sketches/` holds exploratory design work and pre-plan drafts.
- `packages/static_testing/README.md` and `packages/static_testing/AGENTS.md`
  remain the package-scoped entry point for the shared deterministic testing
  surface.
- Every `packages/static_*/` root now carries a package-scoped `README.md` and
  `AGENTS.md` pair so package purpose, scope, validation, and key paths are
  discoverable without leaving the package directory.
