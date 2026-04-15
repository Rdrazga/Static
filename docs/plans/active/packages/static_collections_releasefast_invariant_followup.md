# `static_collections` ReleaseFast invariant follow-up

Scope: remove validated `ReleaseFast` hot-path traversal leaks from collection
families that `static_ecs` depends on, and admit the missing benchmark owners
needed to keep those regressions visible.

## Review focus

- The validated issue class is the same one recently fixed in `static_ecs`:
  traversal-heavy invariant helpers still do real work in `ReleaseFast` because
  the helper body walks storage even when inner asserts are stripped.
- The highest-priority affected families are `IndexPool`, `MinHeap`,
  `SlotMap`, `SparseSet`, and `SortedVecMap`.
- The package currently lacks admitted benchmark owners for these families, so
  `zig build bench` would not catch the regression class automatically.

## Current state

- `Vec` and `FlatHashMap` already have stronger benchmark and contract
  visibility than the families above.
- `static_ecs` directly inherits `IndexPool` hot-path costs through
  `EntityPool`, and future ECS or scheduler work could plausibly inherit the
  others.
- The existing active `static_collections.md` plan is about packed-storage API
  boundary work, not this `ReleaseFast` invariant/benchmark slice.

## Approved direction

- Open a separate active follow-up for the invariant/benchmark work instead of
  overloading the packed-storage plan.
- Fix the validated hot-path issue package-wide for the named families before
  expanding allocator ergonomics or packed-storage APIs.
- Admit only bounded benchmark owners that directly measure the affected hot
  mutation paths.

## Ordered SMART tasks

1. `Invariant helper gating`
   Gate the traversal-heavy invariant helpers in `IndexPool`, `MinHeap`,
   `SlotMap`, `SparseSet`, and `SortedVecMap` behind `std.debug.runtime_safety`
   while preserving the current safety-build checks.
   Done when:
   - each affected family keeps full invariant checking in runtime-safety
     builds;
   - `ReleaseFast` mutation paths stop paying full-array or full-heap scans;
   - direct tests still prove the current invalidation and misuse contracts.
   Validation:
   - `zig build test`
2. `Benchmark owner admission`
   Add canonical `ReleaseFast` benchmark owners for the hot mutation families
   so the invariant-regression class becomes review-visible.
   Minimum target set:
   - `IndexPool` allocate/release churn;
   - `MinHeap` steady-state push/pop/update;
   - one handle/map family hot-path owner covering either `SlotMap`,
     `SparseSet`, or `SortedVecMap`.
   Done when:
   - the owners are wired into `zig build bench`;
   - shared baselines/history exist;
   - the workloads are pre-sized so they measure collection behavior rather
     than incidental allocation setup.
   Validation:
   - `zig build bench`
3. `Docs and queue alignment`
   Record the accepted `ReleaseFast` invariant policy and the new benchmark
   posture in package and workspace docs.
   Done when:
   - package docs mention the runtime-safety-only invariant-walk policy where
     relevant;
   - benchmark owners are documented in the package map;
   - this plan and `workspace_operations.md` are aligned on priority.
   Validation:
   - `zig build docs-lint`

## Ideal state

- The affected collection families keep their strong safety-build proofs
  without silently turning nominally O(1) or O(log n) mutation paths into
  O(n) or worse work in `ReleaseFast`.
- `static_ecs` and other downstream packages inherit the intended collection
  complexity, not debug-style validation overhead.
- The benchmark surface is broad enough that future invariant leaks in these
  families fail review quickly.
