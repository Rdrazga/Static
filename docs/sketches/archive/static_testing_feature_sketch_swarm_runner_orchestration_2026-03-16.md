# `static_testing` feature sketch: swarm runner orchestration

Date: 2026-03-16

## Goal

Add a first-class swarm runner to `static_testing` that can execute many bounded
deterministic simulation runs across seeds and weighted scenario variants,
persist actionable failure bundles, and expose named runner profiles without
moving orchestration concerns into `testing.sim`.

Companion module/API draft:
`docs/sketches/archive/static_testing_swarm_runner_module_api_2026-03-16.md`

## Why this belongs in `static_testing`

The current package already has strong deterministic run substrate:

- `packages/static_testing/src/testing/sim/` owns the event loop, scheduler,
  logical clock, timer queue, and fault-script primitives.
- `packages/static_testing/src/testing/fuzz_runner.zig` already proves the
  package should own bounded multi-case orchestration over deterministic seeds.
- `packages/static_testing/src/testing/replay_runner.zig`,
  `replay_artifact.zig`, `trace.zig`, and `corpus.zig` already define the
  reproducibility and persistence side of the testing control plane.

What is missing is the VOPR-style layer that decides which runs to execute, with
which scenario weights and budgets, and what to save when one fails.

## Proposed placement

Keep the architectural boundary explicit:

- `packages/static_testing/src/testing/sim/`: single-run deterministic engine
  and reusable low-level primitives.
- `packages/static_testing/src/testing/fuzz_runner.zig`: bounded deterministic
  case runner for general fuzz/property workflows.
- `packages/static_testing/src/testing/swarm_runner.zig`: campaign runner for
  many simulation runs, profile selection, progress reporting, and failure
  retention.

Export the new module from `packages/static_testing/src/testing/root.zig`.

This keeps `testing.sim` focused on the data plane while the new swarm runner
stays in the testing control plane.

## Core responsibilities

The swarm runner should own:

- seed enumeration and split-seed derivation;
- scenario portfolio selection, including weighted options and disabled paths;
- named execution profiles such as `smoke`, `stress`, and `soak`;
- per-run step, time, and artifact budgets;
- stop-on-first-failure versus continue-and-collect policy;
- deterministic progress summaries; and
- failure bundle persistence plus replay handles.

The swarm runner should not own:

- application-specific invariants or state checkers;
- production subsystem simulation logic;
- network or storage fault semantics; or
- unbounded concurrency or wall-clock dependent run semantics.

## Minimal API shape

One narrow starting shape is enough:

- `SwarmConfig`: `seed_count_max`, `steps_per_seed_max`, `profile`,
  `stop_policy`, `failure_retention_max`, and report settings.
- `SwarmScenario`: a callback or small interface that builds one harness from
  seed plus weighted options and returns a deterministic result.
- `SwarmExecution`: one run summary with run identity, stats, and optional
  failure bundle metadata.
- `SwarmSummary`: aggregate counts and retained failures for the full campaign.

The runner should reuse existing `RunIdentity`, trace metadata, replay
artifacts, and later replay failure bundles instead of inventing a parallel
artifact vocabulary.

## Integration points

The new runner should integrate with current or planned `static_testing`
surfaces:

- `testing.sim`: drive one deterministic simulation run.
- `testing.replay_artifact` and replay bundles: persist enough context for exact
  reproduction.
- `testing.trace`: attach bounded event summaries to failures.
- `testing.checker`: normalize invariant failures and explicit check failures.
- `testing.corpus`: store failing seeds and scenario metadata.
- schedule exploration: optionally treat a schedule portfolio as one scenario
  dimension, without merging the two modules.
- benchmark baselines: optionally record harness overhead for campaign profiles,
  but keep benchmark gating separate from swarm correctness runs.

## Phased implementation bias

The MVP should stay narrow:

1. Single-threaded orchestration.
2. Seed plus weighted-option scheduling.
3. Named bounded profiles.
4. Failure retention with deterministic summaries.

Only later, if justified, should the runner add:

- host-thread parallel seed execution;
- seed-retention heuristics beyond first-failure and bounded collect-many;
- campaign resume/merge workflows; or
- cross-package scenario scheduling.

## Validation target

The feature is worthwhile if it makes the following cheap:

- run many deterministic simulation seeds in CI;
- retain a short actionable failure bundle on the first failing run;
- replay failures from persisted metadata without bespoke harness glue; and
- define VOPR-like campaign modes without embedding policy into `testing.sim`.

## Non-goals

- Generic distributed-systems framework magic.
- UI or browser simulator work.
- Full coverage-guided engine implementation inside `static_testing`.
- A replacement for package-specific scenario harnesses.
