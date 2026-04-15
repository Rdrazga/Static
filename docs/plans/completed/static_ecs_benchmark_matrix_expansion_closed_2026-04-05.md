# `static_ecs` benchmark matrix expansion follow-up

Scope: close the 2026-04-05 reopen that broadened ECS benchmark observability
with microbenchmarks, scale-sensitive query coverage, and frame-like
multi-pass runs.

Status: follow-up closed on 2026-04-05. The admitted ECS benchmark surface now
adds primitive hot-path microbenchmarks, query scaling across entity and
archetype counts, and sequential frame-like ECS pass runs while staying on the
shared `static_testing.bench.workflow` baseline/history path.

## Validated issue scope

- The package did not own a microbenchmark family for primitive hot paths such
  as component lookup, iterator startup, and one-command staging overhead.
- The package did not have one benchmark family that held the query shape
  stable while varying entity counts and archetype counts directly.
- The package did not have a frame-like workload that measured several ECS
  passes over one world without inventing a scheduler API.
- The repo did not yet carry a durable long-form benchmark backlog for the
  remaining production-grade ECS comparison stories.

## Implemented fixes

- `packages/static_ecs/benchmarks/micro_hotpaths_baselines.zig` now owns
  primitive hot-path microbenchmarks for const component lookup,
  `hasComponent()`, iterator startup, and one-command bundle staging.
- `packages/static_ecs/benchmarks/query_scale_baselines.zig` now owns dense
  and fragmented query scaling cases that vary entity counts and archetype
  counts under one stable query family.
- `packages/static_ecs/benchmarks/frame_pass_baselines.zig` now owns
  sequential frame-like ECS pass runs that vary pass count, entity count, and
  archetype fragmentation while staying explicit that the measured surface is
  sequential ECS work rather than a package-native scheduler.
- `build.zig` now admits the three new ECS owners under `zig build bench` and
  exposes direct named run steps for each admitted benchmark owner so the ECS
  benchmarks can be iterated individually from the root build surface.
- `docs/sketches/static_ecs_production_benchmark_backlog_2026-04-05.md` now
  records the remaining high-value benchmark stories for broader production ECS
  comparison work.

## Proof posture

- `zig build check` proved the widened benchmark owners compile on the
  workspace build surface.
- `zig build micro_hotpaths_baselines` proved the microbenchmark owner runs and
  records shared baseline/history artifacts.
- `zig build query_scale_baselines` proved the scale-sensitive query owner runs
  and records shared baseline/history artifacts.
- `zig build frame_pass_baselines` proved the frame-like ECS pass owner runs
  and records shared baseline/history artifacts.
- `zig build docs-lint` proves the package docs, architecture notes, sketches,
  and plan references stay aligned.

## Current posture

- `static_ecs` benchmark review now covers primitive lookup and staging hot
  paths, query scaling by entity count and archetype fragmentation, and
  sequential frame-like ECS pass mixes in addition to the previously admitted
  query, structural-churn, and command-buffer families.
- The widened benchmark surface still uses shared `static_testing`
  baseline/history artifacts and explicit environment metadata instead of
  package-local benchmark formats.

## Reopen triggers

- Reopen if a new ECS benchmark owner bypasses the shared benchmark workflow or
  drops deterministic semantic preflight.
- Reopen if the direct named benchmark steps drift out of sync with the
  admitted benchmark owners under `zig build bench`.
- Reopen if the production backlog becomes stale enough that major missing ECS
  comparison stories are no longer visible in-repo.
