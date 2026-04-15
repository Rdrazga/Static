# `static_ecs` benchmark review and expansion follow-up

Scope: close the 2026-04-05 benchmark-shape and workflow-metadata reopen for
the world-local typed ECS package.

Status: follow-up closed on 2026-04-05. The admitted ECS benchmark owners now
cover dense versus fragmented query iteration, initial versus live-entity
structural churn, and spawn-heavy versus insert-heavy versus mixed
command-buffer apply, while still using the shared
`static_testing.bench.workflow` baseline/history path.

## Validated issue scope

- `query_iteration_baselines` previously exposed only one mixed
  optional/exclude query case, so it did not show the package's best-case dense
  iteration shape or a fragmented multi-archetype scan shape.
- `structural_churn_baselines` previously compared only initial scalar spawn
  plus insert against fused `spawnBundle()`, so it missed already-live entity
  transition churn where `insertBundle()` should matter most.
- `command_buffer_apply_baselines` previously owned only one mixed apply case,
  so it did not separate spawn-heavy, insert-heavy, and mixed apply behavior.
- `benchmarks/support.zig` already used the shared benchmark workflow, but it
  still sized several report/history buffers around a tiny fixed group and did
  not forward bounded environment tags into benchmark history metadata.

## Implemented fixes

- `packages/static_ecs/benchmarks/support.zig` now sizes report/history storage
  from the admitted case count, forwards bounded environment tags, and prints a
  stable benchmark-owner heading in the text report.
- `packages/static_ecs/benchmarks/query_iteration_baselines.zig` now owns
  three deterministic query workloads: dense single-archetype required reads,
  mixed optional-health with exclusion, and a fragmented optional/exclude-heavy
  multi-archetype scan. Each case has semantic preflight before timing starts.
- `packages/static_ecs/benchmarks/structural_churn_baselines.zig` now owns
  both initial-admission and live-entity transition churn, separating scalar
  insertion from fused bundle admission for each shape.
- `packages/static_ecs/benchmarks/command_buffer_apply_baselines.zig` now owns
  spawn-only, insert-only, and mixed spawn/insert/remove apply workloads with
  deterministic semantic preflight.

## Proof posture

- `zig build check` proves the widened benchmark owners still compile across
  the workspace build surface.
- `zig build bench` now runs the broadened ECS workloads on the shared review
  surface. Because the admitted case sets changed, the existing local
  `baseline.zon` files for the ECS benchmark owners now report expected
  candidate-shape mismatches until a reviewer records fresh baselines for the
  new workload sets.
- `zig build docs-lint` proves the benchmark posture and plan references remain
  aligned in repo docs.

## Current posture

- `static_ecs` benchmark review now distinguishes best-case contiguous query
  throughput from fragmented archetype scans, initial entity admission from
  live-entity transitions, and command-buffer apply shapes instead of treating
  each family as one blended workload.
- The package still uses the shared `static_testing` benchmark workflow rather
  than introducing package-local benchmark artifact formats or sidecars.

## Reopen triggers

- Reopen if a benchmark owner collapses these workload families back into one
  blended case and loses the shape-specific signal this follow-up added.
- Reopen if `static_ecs` benchmark history stops carrying the bounded
  environment metadata needed for compatibility filtering.
- Reopen if a new first-class ECS benchmark owner lands without deterministic
  semantic preflight or without using the shared benchmark workflow path.
