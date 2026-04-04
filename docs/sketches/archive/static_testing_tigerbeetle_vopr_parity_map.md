# `static_testing` <-> TigerBeetle VOPR parity map

## Snapshot

- Audit date: `2026-03-05`
- TigerBeetle source snapshot: `.tmp/tigerbeetle_20260305_000407`
- TigerBeetle commit: `b34a0cb7e01c0c79057ad1cba4dc4a3117528e4f` (`2026-03-04T22:19:48Z`)
- Scope: `src/vopr.zig`, `src/testing/*`, `src/testing/cluster/*`, `src/scripts/cfo.zig`,
  `docs/internals/vopr.md`, `docs/internals/testing.md`, `build.zig`

## Decision vocabulary

- `Adopt`: copy concept/API shape almost directly into `static_testing`.
- `Adapt`: keep concept, but generalize API for cross-package use.
- `Harness-only`: valuable, but belongs in package/app-specific harnesses, not core library.
- `Exclude`: not currently worth carrying into `static_testing`.

## Phases used in this map

- `Phase 0` (complete): research, parity decisions, and architecture sketches.
- `Phase 1` (next implementation focus): deterministic engine + reproducibility + base runner.
- `Phase 2`: environment simulators (network/storage/time/io) and generic fault API.
- `Phase 3`: advanced orchestration, long-horizon automation, and richer tooling.

## Parity matrix

| Area | TigerBeetle implementation evidence | Feature | Parity decision | Target phase | Why |
|---|---|---|---|---|---|
| Reproducibility | `src/testing/fuzz.zig` (`parse_seed`) | Reproducible seeds (decimal and commit-hash based) | `Adopt` | `Phase 1` | Core to deterministic replay and CI/debug handoff. |
| Reproducibility | `src/vopr.zig` (`main`, seed handling/logging) | Failure replay via seed + full options print | `Adopt` | `Phase 1` | Required for actionable failures. |
| Runner modes | `src/vopr.zig` (`options_swarm`, `options_lite`, `options_performance`) | Named profiles for run style | `Adapt` | `Phase 1` | Keep profile concept, but make package-agnostic (`smoke`, `stress`, `soak`). |
| Budgets | `src/vopr.zig` (`ticks_max_requests`, `ticks_max_convergence`) | Explicit tick budgets per phase | `Adopt` | `Phase 1` | Boundedness aligns with AGENTS safety rules. |
| Engine loop | `src/vopr.zig` (`Simulator.tick`) | Single-threaded deterministic tick loop | `Adopt` | `Phase 1` | Foundation of DST determinism and repeatability. |
| Pending reasons | `src/vopr.zig` (`pending`) | Explain why run is not converged | `Adapt` | `Phase 1` | Use enum-based reasons over free-form strings. |
| Safety->liveness split | `src/vopr.zig` (`transition_to_liveness_mode`, `cluster_recoverable`) | Two-stage validation (faulty run, then heal+converge check) | `Adapt` | `Phase 1` | Strong pattern for separating correctness and recovery checks. |
| Core selection | `src/vopr.zig` (`random_core`, `full_core`) | Subgraph/core selection for liveness proofs | `Adapt` | `Phase 2` | Keep as generic quorum/connectivity selection utility. |
| Ordered replies | `src/testing/reply_sequence.zig` | Reassemble out-of-order effects for deterministic checking | `Adapt` | `Phase 2` | Generalizable as ordered-event verifier utility. |
| Workload generator | `src/vopr.zig` (`StateMachine.Workload`) | Seeded workload generation under bounds | `Adapt` | `Phase 1` | Needed; but belongs to pluggable workload trait, not fixed state machine type. |
| Observer logs | `src/vopr.zig` (`log_override`), `docs/internals/testing.md` | Short/full log modes and structured state output | `Adapt` | `Phase 1` | Keep observer modes; avoid TigerBeetle-specific columns in core. |
| Message summary | `src/testing/cluster/network.zig` (`MessageSummary`) | Per-command counts/bytes stats | `Adapt` | `Phase 2` | Useful generic telemetry for simulations. |
| Packet simulation | `src/testing/packet_simulator.zig` | Delay/loss/replay/capacity queue behavior | `Adopt` | `Phase 2` | Strong reusable base for simulated networks. |
| Per-link control | `src/testing/packet_simulator.zig` (`link_filter`, `link_drop_packet_fn`) | Filter/drop hooks by link and command | `Adopt` | `Phase 2` | Critical for deterministic fault targeting. |
| Partition modeling | `src/testing/packet_simulator.zig` (`PartitionMode`, `PartitionSymmetry`) | Controlled partition generation strategies | `Adopt` | `Phase 2` | Core distributed-system fault dimension. |
| Congestion modeling | `src/testing/packet_simulator.zig` (`path_clog_probability`) | Path clogging with duration distributions | `Adopt` | `Phase 2` | Models latency spikes and queue pressure. |
| Packet record/replay | `src/testing/packet_simulator.zig` (`link_record`, `replay_recorded`) | Targeted recording and deterministic replay | `Adopt` | `Phase 2` | Very high debugging value. |
| Network liveness mode | `src/testing/cluster/network.zig` (`transition_to_liveness_mode`) | Deterministic healing profile | `Adapt` | `Phase 2` | Keep concept as reusable "repair profile" API. |
| Storage simulation | `src/testing/storage.zig` | Tick-based async read/write queues | `Adopt` | `Phase 2` | Reusable for storage-heavy systems. |
| Storage latencies | `src/testing/storage.zig` (`read_latency`, `write_latency`) | Distribution-based latency injection | `Adopt` | `Phase 2` | Common need for deterministic fault workloads. |
| Storage corruption | `src/testing/storage.zig` (`read_fault_probability`, `write_fault_probability`) | Per-operation corruption fault injection | `Adopt` | `Phase 2` | Core fault primitive. |
| Misdirected writes | `src/testing/storage.zig` (`write_misdirect_probability`, overlays) | Plausible misdirect model with reversible overlays | `Adapt` | `Phase 2` | Valuable but complex; keep with simpler first implementation. |
| Crash fault behavior | `src/testing/storage.zig` (`reset`, `crash_fault_probability`) | Crash-time corruption of pending writes | `Adopt` | `Phase 2` | High-value failure mode for durability logic. |
| Recoverability guardrails | `src/testing/storage.zig` (`ClusterFaultAtlas`) | Fault distribution constrained to preserve repairability | `Adopt` | `Phase 2` | Prevents generating mostly-useless impossible worlds. |
| Time simulation | `src/testing/time.zig` (`TimeSim`) | Tick-based monotonic/realtime with controllable drift models | `Adapt` | `Phase 2` | Keep deterministic clock core, optional drift models. |
| Mock IO backend | `src/testing/io.zig` | Simple queued IO + explicit fault modes | `Adapt` | `Phase 2` | Useful as reference backend; align API with static packages. |
| State correctness checker | `src/testing/cluster/state_checker.zig` | Commit chain and client-reply invariants | `Harness-only` | `Phase 2` | Pattern is reusable, rules are app/protocol specific. |
| Storage determinism checker | `src/testing/cluster/storage_checker.zig` | Cross-replica checkpoint/compaction checksum checks | `Harness-only` | `Phase 2` | Keep checker framework in core, not TigerBeetle checksum semantics. |
| Manifest checker | `src/testing/cluster/manifest_checker.zig` | Checkpointed manifest consistency checks | `Harness-only` | `Phase 3` | Domain-specific to TigerBeetle LSM internals. |
| Journal checker | `src/testing/cluster/journal_checker.zig` | WAL/header consistency invariants | `Harness-only` | `Phase 3` | Domain-specific storage protocol checks. |
| Grid checker | `src/testing/cluster/grid_checker.zig` | Block coherence by checkpoint identity | `Harness-only` | `Phase 3` | Useful pattern, but TB-specific object model. |
| Release upgrade simulation | `src/vopr.zig`, `src/testing/cluster.zig` | Live rolling upgrades and bundle versions | `Harness-only` | `Phase 3` | Not a core requirement for all static packages. |
| Replica lifecycle simulation | `src/vopr.zig` (`crash/restart/pause/reformat`) | Process lifecycle and recovery actions | `Adapt` | `Phase 2` | Keep generic process/node lifecycle; keep reformat semantics harness-level. |
| Exit code taxonomy | `src/testing/cluster.zig` (`Failure`) | Separate crash/liveness/correctness exits | `Adapt` | `Phase 1` | Useful for CI diagnostics and automation routing. |
| Continuous orchestration | `src/scripts/cfo.zig` | Long-horizon concurrent fuzz runner with timeout and seed retention | `Adapt` | `Phase 3` | Build a smaller library runner first; keep GitHub/devhub specifics out of core. |
| Weighted swarm schedule | `src/scripts/cfo.zig` (`Fuzzer.weights`) | Weighted test target scheduling | `Adapt` | `Phase 3` | Useful for budget allocation across scenarios. |
| Seed curation policy | `src/scripts/cfo.zig` (`SeedRecord.merge`) | Prefer failing, fast-failing, and older seeds | `Adapt` | `Phase 3` | Valuable for stable regression buckets. |
| Browser simulator UX | `docs/internals/vopr.md` (live simulator mention) | Live visualization | `Exclude` | N/A | Out of core for initial `static_testing`. |

## `std`-first implementation parity rules

These rules are mandatory for `static_testing` implementation decisions:

1. Use `std` directly for host concerns:
   - file/report persistence (`std.fs`, `std.io`)
   - process and runner orchestration (`std.process`, `std.time`)
   - bounded containers and scheduling primitives (`std.PriorityQueue`, hash maps, arrays)
2. Keep simulator determinism explicit:
   - simulated time advances only through deterministic `tick` and scheduled events
   - no wall-clock reads in simulation-state transitions
3. Keep PRNG pluggable but default to deterministic `std.Random` usage with explicit seed input.
4. Use adapters instead of wrappers when integrating with production code:
   - implement test backends that satisfy production interfaces
   - avoid replacing or forking `std` behavior where not necessary

## What `static_testing` should not copy from TigerBeetle

- TigerBeetle consensus/data-model semantics (`vsr`, `state_machine`, release policy).
- TigerBeetle-specific storage data structures and checkers (`manifest`, `journal`, `grid` formats).
- Operational tooling tied to TigerBeetle infra (`devhub`, PR label routing, branch policies).

## Minimal parity backlog (actionable)

### Phase 1 backlog

- Deterministic seed handling and replay metadata.
- Single-threaded bounded simulation loop (`tick`, budgets, pending reason enum).
- Basic observer/report interface (short/full + machine-readable failure payload).
- Generic runner profiles (`smoke`, `stress`, `soak`) with explicit bounds.

### Phase 2 backlog

- Packet simulator module (loss, delay, replay, partition, per-link hooks, record/replay).
- Storage simulator module (async queue, latency, corruption, crash-fault primitives).
- Time simulator module (deterministic tick clock with optional drift models).
- Generic checker hooks and fault-policy API (including recoverability-aware fault distributions).

### Phase 3 backlog

- Long-horizon orchestrator for continuous runs (concurrency, timeout, seed buckets).
- Weighted scenario scheduling and seed-retention policy.
- Optional advanced harness templates for cross-package adoption.
