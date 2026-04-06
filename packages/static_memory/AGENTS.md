# `static_memory` package guide
Start here when you need to review, validate, or extend `static_memory`.

## Source of truth

- `README.md` for the package entry point, current status, and commands.
- `src/root.zig` for the exported surface.
- `tests/integration/root.zig` for the package-level deterministic regression surface.
- `benchmarks/` for canonical benchmark entry points and artifact names.
- `docs/plans/completed/static_memory_followup_closed_2026-04-01.md` for the current closure posture and reopen triggers.
- `docs/plans/active/workspace_operations.md` for workspace priority and sequencing.
- `docs/architecture.md` for package boundaries and dependency direction.

## Supported commands

- `zig build check`
- `zig build test`
- `zig build bench`
- `zig build examples`
- `zig build docs-lint`

Command intent:

- Use the root `build.zig` as the supported validation surface.
- Keep `zig build bench` review-only unless a benchmark workflow explicitly opts into gating.
- Keep `zig build examples` as the package usage and smoke surface for allocator helpers.

## Working agreements

- Keep allocator ownership and bounded-resource policy package-local.
- Prefer direct package tests for allocator-specific invariants; use `static_testing` only when a shared harness is the better fit.
- Keep `Budget`, `Arena`, `Pool`, `Slab`, `Scratch`, and related wrappers explicit about bounds, reuse, and failure contracts.
- Keep `Slab` free routing address-ordered and benchmarked alongside pool alloc/free and fallback behavior.
- Keep benchmark artifacts on the shared `baseline.zon` plus `history.binlog` convention; do not add package-local artifact formats.
- Keep package docs aligned with the root repo docs and update the package README and this file together when behavior or navigation changes.

## Package map

- `src/root.zig`: package export surface.
- `src/memory/budget.zig`: byte accounting and `BudgetedAllocator`.
- `src/memory/arena.zig`: bump arena with reset/reuse semantics.
- `src/memory/pool.zig`: fixed-size block pool and typed pool helpers.
- `src/memory/slab.zig`: size-class slab allocation, address-ordered free routing, and fallback handling.
- `src/memory/scratch.zig`: scoped scratch allocator built on `Stack`.
- `src/memory/frame_scope.zig`: explicit stack and scratch rollback guards.
- `src/memory/stack.zig`: stack allocator primitive used by scratch helpers.
- `src/memory/growth.zig`: capacity and growth-policy helpers.
- `src/memory/capacity_report.zig`: common capacity reporting types.
- `src/memory/soft_limit_allocator.zig`: soft-limit wrapper with fallback policy.
- `src/memory/debug_allocator.zig`, `src/memory/profile_hooks.zig`, `src/memory/epoch.zig`, `src/memory/tls_pool.zig`: support and integration helpers.
- `tests/integration/`: package-owned allocator regression coverage.
- `benchmarks/`: canonical pool alloc/free and slab alloc/free review workload.
- `examples/`: bounded usage examples only.

## Change checklist

- Update `README.md` and `AGENTS.md` when package behavior or workflow changes.
- Extend `tests/integration/root.zig` when you add new first-class package regression coverage.
- Re-record benchmark baselines when workload size or semantics change.
- Update root `README.md`, root `AGENTS.md`, and `docs/architecture.md` only when package guidance or repository navigation changes.
