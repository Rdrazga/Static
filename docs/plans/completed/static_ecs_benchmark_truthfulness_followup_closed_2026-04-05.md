# `static_ecs` benchmark truthfulness follow-up

Scope: close the 2026-04-05 reopen that corrected benchmark build-mode
truthfulness, command-buffer owner semantics, and structural-churn rerun
bounds for the admitted ECS benchmark owners.

Status: follow-up closed on 2026-04-05. The affected ECS benchmarks now report
the intended release-style build mode, the command-buffer owner names match the
timed work, and structural-churn reruns stay bounded on this machine.

## Validated issue scope

- The root bench build advertised `ReleaseFast`, but benchmark history still
  reported debug builds because the reusable imported package modules were
  created with the workspace optimize mode instead of the bench optimize mode.
- `command_buffer_apply_baselines` timed setup and staging plus apply while the
  owner and case names implied apply-only throughput.
- `structural_churn_baselines` rebuilt fresh worlds inside each measured
  operation while keeping the default full benchmark iteration budget, making
  direct reruns awkwardly long.
- The fragmented query cases were explicitly validated as expected current-view
  behavior rather than a benchmark bug, so they stayed out of this fix slice.

## Implemented fixes

- `build.zig` now creates a dedicated benchmark module graph under
  `ReleaseFast` for the root `zig build bench` and named benchmark steps,
  instead of reusing the workspace optimize-mode package modules.
- `packages/static_ecs/benchmarks/command_buffer_apply_baselines.zig` now owns
  the truthful benchmark owner `command_buffer_staged_apply_baselines`, with
  stage-plus-apply case names and matching environment metadata.
- `packages/static_ecs/benchmarks/structural_churn_baselines.zig` now uses a
  reduced benchmark configuration so the scalar and bundle churn cases remain
  observable without requiring the old long rerun budget.
- Package and repo docs now describe the corrected benchmark semantics and the
  release-style benchmark build posture.

## Proof posture

- `zig build check` proved the build-graph and benchmark-owner updates compile.
- `zig build micro_hotpaths_baselines` now runs under the corrected release
  benchmark build graph and records fresh history for that mode.
- `zig build command_buffer_staged_apply_baselines` proved the renamed
  command-buffer owner runs under the root bench surface.
- `zig build structural_churn_baselines` now completes under the reduced rerun
  budget on this machine.
- `zig build docs-lint` proved the package docs and plan references stay
  aligned.

## Current posture

- The current ECS benchmark numbers are again attributable to the intended
  release-style build mode rather than the workspace debug optimize setting.
- The command-buffer owner is now semantically truthful about measuring staged
  command-buffer throughput through apply rather than pure apply-only cost.
- Structural-churn reruns are bounded enough to stay practical while still
  preserving the scalar-versus-bundle comparison signal.

## Reopen triggers

- Reopen if benchmark history and the root bench build drift out of optimize
  alignment again.
- Reopen if a benchmark owner names apply-only or mutation-only work while
  timing setup outside that contract.
- Reopen if rerun budgets for the admitted ECS owners drift high enough that
  direct validation becomes impractical again.
