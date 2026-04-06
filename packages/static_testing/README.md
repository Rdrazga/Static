# `static_testing`

Shared deterministic testing, replay, simulation, fuzz, swarm, and benchmark
review utilities for the `static_*` workspace.

## What this package is for

Use `static_testing` when a package needs deterministic review of behavior that
is awkward to validate with plain unit tests alone:

- stateful API and protocol sequences
- ordering and temporal assertions over traces
- bounded subsystem fault simulation
- deterministic replay of malformed-input or seeded failures
- shared benchmark baseline and history review
- deterministic multi-component or process-boundary harnesses
- bounded multi-seed campaign execution

The package is intentionally library-first. It provides reusable deterministic
primitives and canonical artifact formats, while leaving most policy decisions
to callers so they can preserve their own repo structures, triage flows, and
operational preferences.

## Pick the simplest surface

- `testing.model`: stateful API or protocol transitions, mutation sequences, and
  explicit operation traces
- `testing.temporal`: ordering, deadlines, and trace-based assertions
- `testing.sim.fixture`: deterministic scheduled execution without committing to
  a full system harness
- `testing.sim.explore`: bounded portfolio and PCT-style schedule exploration
  with replayable retained decisions
- `testing.sim.network_link`: transport-level delay, partitions, congestion,
  backlog pressure, and caller-owned pending-delivery replay
- `testing.sim.storage_lane`: delayed completion lanes without durable-state
  semantics
- `testing.sim.storage_durability`: durable-state delay, corruption, crash,
  recovery, placement, omission, and caller-owned state replay
- `testing.sim.retry_queue`: retry and backoff scheduling
- `testing.sim.clock.RealtimeView`: observed-time offset and drift projections
  over a deterministic monotonic clock
- `testing.liveness`: repair/convergence checks when the invariant is eventual
  progress, not one-step exactness
- `testing.system`: deterministic multi-component composition when lower-level
  surfaces stop being enough
- `testing.process_driver`: child-process orchestration inside deterministic
  system flows
- `testing.replay_runner`, `testing.fuzz_runner`, `testing.corpus`: retained
  malformed-input and seeded-input review
- `testing.failure_bundle`: canonical bounded retained failure artifacts
- `testing.swarm_runner`: many deterministic runs with resume, sharding, and
  bounded summaries
- `testing.bench.*`: shared benchmark baseline, history, exploration, and
  review workflows

If more than one surface could work, prefer the smaller one. Start with
`testing.model`, move to `testing.sim`, then to `testing.system`, and only use
`testing.swarm_runner` when many deterministic runs are themselves part of the
review.

## Basic usage

1. Pick the narrowest harness that directly matches the invariant.
2. Keep seeds, timings, fault profiles, and retained artifacts explicit.
3. Bound memory, retained output, and execution steps.
4. Reuse the shared artifact formats instead of inventing package-local ones.
5. Keep clustering, triage, and long-run review policy caller-owned unless the
   repo needs one shared contract.

## Deterministic testing guidance

- Use `testing.model` for sequence-sensitive contracts, not subsystem fault
  mechanics.
- Use `testing.temporal` when the review depends on "before/after", not just
  final state.
- Use `testing.sim.*` when the behavior depends on transport delay, retry,
  storage durability, or clock observation.
- Use `testing.system` only when composition is the point. If a caller needs
  lower-level control, they can bypass it and compose the underlying fixtures
  directly.
- Use `testing.liveness` only when convergence or repair is the invariant being
  reviewed.

## Fuzz and replay guidance

- Keep failure inputs replayable through explicit seeds, corpora, or retained
  bundles.
- Prefer bounded retained outputs such as `manifest.zon`, `violations.zon`,
  `trace.zon`, `trace_events.binlog`, and `actions.zon` when those surfaces
  apply.
- Treat coverage growth, corpus management, and aggressive campaign policy as
  caller concerns unless the repo needs a shared reusable contract.

## Benchmark guidance

- Use stable workloads and explicit tuning knobs.
- Keep review on the shared `baseline.zon` plus bounded binary history sidecars
  instead of package-local benchmark formats.
- Put environment notes and compatibility tags under caller control.
- When setup must stay outside the timer, use `testing.bench.case` prepare
  hooks so warmup/sample reset and staging remain deterministic without
  polluting measured work.

## Reaching VOPR-like functionality

`static_testing` does not try to reproduce TigerBeetle VOPRs wholesale. The
intended pattern is to assemble the needed pieces deterministically:

- model protocol state with `testing.model`
- add transport, storage, retry, or clock mechanics with the narrowest
  simulator that matches the problem
- add `testing.temporal` or `testing.liveness` only when those invariants are
  actually under review
- promote to `testing.system` only when cross-component composition matters
- use `testing.swarm_runner` for explicit seed portfolios, not as the default
  harness

If a project wants stronger clustering, retention, prioritization, or
environment-specific orchestration, prefer building that in the caller's repo
first. Promote it into `static_testing` only when it becomes a stable shared
contract rather than a local workflow preference.

## Key paths

- `src/root.zig`
- `src/testing/root.zig`
- `tests/integration/root.zig`
- `examples/`
- `benchmarks/`
- `docs/plans/completed/static_testing_package_completion_2026-03-24.md`
- `docs/decisions/2026-03-21_static_testing_simulator_boundary.md`

## Common commands

- `zig build test`
- `zig build harness`
- `zig build examples`
- `zig build bench`
- `zig build docs-lint`

Command intent:

- `zig build harness` is the success-only smoke surface for shared deterministic
  harness examples.
- Intentionally retained-failure demos such as model, fuzz, or swarm examples
  stay on `zig build examples` unless they are rewritten to produce
  unambiguous success-only smoke output.
- `zig build bench` is review-only by default; baseline comparison output is
  informative unless the caller explicitly enables gating.
