# `static_memory` ReleaseFast slab follow-up

Scope: fix the validated `ReleaseFast` hot-path costs and observability gaps in
`static_memory.slab` that were surfaced while reviewing `static_ecs`
dependencies.

## Review focus

- `Slab` is a direct allocator option for downstream packages such as
  `static_ecs`, so hot-path behavior in `ReleaseFast` is part of the package
  contract even when the API remains functionally correct.
- The current issue is not only assertion density. The validated problem is
  that traversal-heavy invariant helpers still execute real class scans on
  `alloc()` and `free()` after inner asserts are stripped in `ReleaseFast`.
- The second issue is allocator routing cost: `free()` currently linearly scans
  classes to rediscover ownership.
- The third issue is observability: slab fallback behavior and class-count
  sensitivity are not represented in the admitted benchmark/history surface.

## Current state

- `Pool` already has a canonical benchmark owner and package-owned deterministic
  proof.
- `Slab` currently exposes class-based allocation plus optional large fallback,
  but the admitted benchmark surface does not make its hot paths reviewable.
- `static_ecs` currently stays allocator-agnostic and can accept a slab-backed
  allocator from callers, so `static_memory` needs its own truthful
  `ReleaseFast` contract before downstream adoption should broaden.

## Approved direction

- Treat the invariant-walk and free-routing findings as active implementation
  work now.
- Treat slab telemetry and benchmark observability as part of the same slice so
  the package can prove the fix instead of relying on one-off review notes.
- Keep the package allocator-generic; do not add ECS vocabulary or package
  coupling while fixing slab behavior.

## Ordered SMART tasks

1. `Slab invariant gating`
   Make traversal-heavy slab invariant helpers safety-only so `ReleaseFast`
   `alloc()` and `free()` no longer pay per-class validation scans.
   Done when:
   - `slab.zig` keeps full invariant checking in runtime-safety builds;
   - `ReleaseFast` hot paths retain only O(1) pre/postcondition checks;
   - direct proof still covers the existing invalid-config and invalid-block
     behavior.
   Validation:
   - `zig build test`
2. `Slab free-path routing`
   Remove the current O(class_count) ownership rediscovery from the steady-state
   `free()` path or explicitly replace it with a cheaper bounded routing
   strategy.
   Done when:
   - the package records the accepted routing policy in code comments or docs;
   - `free()` no longer linearly scans every class on the expected hot path;
   - invalid-block and fallback-free semantics remain directly proved.
   Validation:
   - `zig build test`
   - `zig build check`
3. `Slab benchmark admission`
   Add bounded canonical benchmark owners for slab alloc/free behavior and
   fallback behavior so future `ReleaseFast` regressions are review-visible.
   Done when:
   - `zig build bench` includes at least one slab alloc/free owner that varies
     class count;
   - the shared baseline/history workflow records slab results;
   - the workload is pre-sized so it measures routing and invariant cost rather
     than allocator noise from unrelated setup.
   Validation:
   - `zig build bench`
4. `Telemetry and docs closure`
   Make slab fallback accounting and benchmark posture explicit in package docs.
   Done when:
   - README / AGENTS describe the accepted fallback-accounting behavior;
   - the benchmark owner and artifact path are documented;
   - this plan can move to `docs/plans/completed/`.
   Validation:
   - `zig build docs-lint`

## Ideal state

- `Slab` stays truthful in runtime-safety builds without imposing debug-style
  class scans on `ReleaseFast`.
- Free-path routing cost scales with the accepted routing design rather than a
  hidden linear class walk.
- Downstream packages such as `static_ecs` can evaluate slab adoption against a
  real admitted benchmark surface instead of ad hoc local runs.
