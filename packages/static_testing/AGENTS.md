# `static_testing` package guide
Start here when you need to extend or apply the shared deterministic testing
package.

## Source of truth

- `packages/static_testing/README.md` for package purpose and surface selection.
- `packages/static_testing/src/root.zig` for the package export surface.
- `packages/static_testing/src/testing/root.zig` for the testing namespace map.
- `packages/static_testing/tests/integration/root.zig` for first-class
  integration coverage entry points.
- `packages/static_testing/benchmarks/` for supported benchmark review
  workloads.
- `docs/decisions/2026-03-21_static_testing_simulator_boundary.md` for what
  simulator expansion is in scope and what remains caller-owned.
- `docs/plans/completed/static_testing_package_completion_2026-03-24.md` for
  the latest completed repo-owned package record.
- `docs/plans/active/workspace_operations.md` for workspace sequencing.
- `docs/architecture.md` for package boundaries and dependency direction.

## Supported commands

- `zig build test`
- `zig build harness`
- `zig build examples`
- `zig build bench`
- `zig build docs-lint`

Command intent:

- Keep `zig build harness` as a success-only smoke surface for deterministic
  shared-harness examples.
- Keep retained-failure demos on `zig build examples` unless their output can
  read as unambiguous success-only smoke validation.
- Treat `zig build bench` as review-only unless a caller-owned workflow
  explicitly opts into regression gating.

## Working agreements

- Choose the smallest harness that directly proves the invariant:
  `testing.model` before `testing.sim`, `testing.sim` before `testing.system`,
  and `testing.system` before `testing.swarm_runner`.
- Keep seeds, timings, fault plans, and retained artifacts explicit and
  replayable.
- Bound steps, retained files, and buffer growth.
- Prefer shared artifact surfaces such as `baseline.zon`, benchmark history
  sidecars, `manifest.zon`, `violations.zon`, `trace.zon`,
  `trace_events.binlog`, `actions.zon`, and shared replay/campaign records over
  package-local one-off formats.
- Leave clustering, prioritization, long-run retention heuristics, and most
  review policy caller-owned unless the repo needs one stable reusable
  contract.
- Do not add shared retained simulator persistence. `network_link` and
  `storage_durability` stop at caller-owned replay state.
- Do not turn `static_testing` into hosted orchestration, environment control,
  or app-specific test policy.

## Harness selection

- `testing.model`: API and protocol-state mutation sequences.
- `testing.temporal`: trace ordering and deadline assertions.
- `testing.sim.fixture`: deterministic scheduled execution without whole-system
  composition.
- `testing.sim.explore`: bounded portfolio and PCT-style schedule exploration.
- `testing.sim.*`: transport, retry, durability, or clock mechanics.
- `testing.liveness`: repair/convergence checks with typed pending reasons.
- `testing.system`: deterministic multi-component or process-boundary
  composition when lower-level harnesses stop being enough.
- `testing.process_driver`: child-process control inside `testing.system`
  scenarios.
- `testing.replay_runner` / `testing.fuzz_runner`: malformed-input and seeded
  replay review.
- `testing.failure_bundle`: canonical retained failure output.
- `testing.swarm_runner`: bounded many-seed campaigns with deterministic shard,
  resume, and summary behavior.
- `testing.bench.*`: shared benchmark review workflows.

## Design and tuning

- Use `testing.model` for sequence contracts and explicit action traces.
- Use `testing.sim.*` for mechanism modeling: delay, partition, retry,
  corruption, omission, recovery, backlog pressure, or observed-time drift.
- Use `testing.system` only when composition is the invariant. If a caller
  wants lower-level functions instead, keep the composition caller-owned.
- Use `testing.swarm_runner` when campaign execution itself is worth reviewing;
  do not promote every deterministic test into swarm form.
- Keep benchmark workloads stable and caller-tunable, then review them through
  shared `baseline.zon` and history artifacts.
- Promote new shared policy only when it is reusable across packages, bounded,
  and clearly better than caller-side implementation.

## Reaching VOPR-like functionality

- Build deterministic scenarios from explicit model actions, simulator fault
  profiles, and trace assertions.
- Add `testing.liveness` when convergence after failure is the actual contract.
- Add `testing.system` when cross-component wiring or process boundaries are
  the behavior under review.
- Use `testing.swarm_runner` for bounded portfolios of seeds, schedules, or
  fault plans.
- Keep failure clustering, triage rules, retention policy, and environment
  orchestration in the caller's repo unless a shared repo-wide contract becomes
  unavoidable.

## Change checklist

- Update `packages/static_testing/README.md` and `packages/static_testing/AGENTS.md`
  when package usage guidance changes.
- Update `packages/static_testing/tests/integration/root.zig` when adding a new
  first-class integration surface.
- Update `packages/static_testing/examples/` or `packages/static_testing/benchmarks/`
  when a public surface needs a canonical usage path.
- Update root `README.md`, root `AGENTS.md`, `docs/architecture.md`, and the
  relevant plan or decision doc when package-scoped navigation or boundaries
  change.
