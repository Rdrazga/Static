# `static_sync` package guide
Start here when you need to review, validate, or extend `static_sync`.

## Source of truth

- `README.md` for the package entry point, current status, and command surface.
- `src/root.zig` for the exported surface and primitive namespace map.
- `tests/integration/root.zig` for the package-level deterministic regression
  surface.
- `benchmarks/` for canonical benchmark entry points and artifact names.
- `docs/plans/completed/static_sync_followup_closed_2026-04-01.md` for the
  current closure posture and reopen triggers.
- `docs/plans/active/workspace_operations.md` for workspace priority and
  sequencing.
- `docs/architecture.md` for package boundaries and dependency direction.

## Supported commands

- `zig build check`
- `zig build test`
- `zig build harness`
- `zig build examples`
- `zig build bench`
- `zig build docs-lint`

Command intent:

- Keep `zig build test` as the primary pass/fail surface for package
  integration and retained regression coverage.
- Keep `zig build harness` as a success-only smoke surface for the shared
  deterministic examples that are intended to stay non-failing.
- Keep `zig build examples` for bounded usage demos and any examples that are
  intentionally not part of the smoke surface.
- Treat `zig build bench` as review-only unless a benchmark workflow
  explicitly opts into gating.

## Working agreements

- Use the root `build.zig` as the supported validation surface.
- Keep `static_sync` focused on synchronization, cancellation, bounded
  coordination, and wait primitives, not on higher-level runtime policy.
- Prefer shared `static_testing` surfaces for model, replay, fuzz, simulation,
  and temporal proof work when those are the right fit.
- Keep host-thread smoke coverage deterministic and bounded.
- Keep benchmark artifacts on shared `baseline.zon` plus `history.binlog`;
  do not add package-local artifact formats.
- Keep package guidance aligned with the root docs and update this file when
  the package boundary or supported workflow changes.

## Package map

- `src/root.zig`: package export surface and primitive namespace map.
- `src/sync/backoff.zig`: bounded backoff helpers.
- `src/sync/padded_atomic.zig`: padded atomic helpers for contention-sensitive
  primitives.
- `src/sync/seqlock.zig`: sequence-lock coordination.
- `src/sync/once.zig`: one-time initialization helper.
- `src/sync/cancel.zig`: cancellation source and token helpers.
- `src/sync/event.zig`: event-style signaling.
- `src/sync/semaphore.zig`: bounded semaphore coordination.
- `src/sync/condvar.zig`: condition-variable wrapper and capability gating.
- `src/sync/wait_queue.zig`: wait-queue coordination and wake semantics.
- `src/sync/barrier.zig`: reusable barrier coordination.
- `src/sync/grant.zig`: capability and token-grant helpers.
- `src/sync/caps.zig`: inline-test-only capability declarations.
- `tests/integration/`: deterministic model, replay, fuzz, and host smoke
  coverage.
- `benchmarks/`: canonical fast-path and contention benchmark workflows.
- `examples/`: bounded usage examples only.

## Change checklist

- Update `README.md`, `AGENTS.md`, and
  `docs/plans/completed/static_sync_followup_closed_2026-04-01.md` when
  package behavior or workflow changes.
- Extend `tests/integration/root.zig` when you add new first-class package
  regression coverage.
- Re-record benchmark baselines when workload sizes or semantics change.
- Update root `README.md`, root `AGENTS.md`, and `docs/architecture.md` when
  package guidance or repository navigation changes.
