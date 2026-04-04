# Sketch: `static_memory` Package Review

Date: 2026-03-06 (America/Denver)  
Status: First review pass completed.

## Scope

Review `packages/static_memory/` for:

- adherence to `agents.md`;
- overlap with Zig standard library facilities and whether the package adds enough value;
- correctness and completeness at file and package scope;
- duplicate, dead, or misplaced code;
- example and test coverage; and
- practical refactor paths.

## Package Inventory

- Source files: 15 memory modules plus `root.zig` (16 total).
- Examples: 5 (`budget_lock_in`, `budget_lock_in_embedded`, `frame_arena_reset`, `scratch_mark_rollback`, `typed_pool_basic`).
- Benchmarks: 1 (`pool_alloc_free`).
- Inline unit/behavior tests: 49 plus root wiring coverage.
- Validation in this pass:
  - `zig build examples` passed.
  - `zig build test` remains blocked by the unrelated `static_queues` stress-test failure at `packages/static_queues/src/testing/lock_free_stress.zig:105`.

Observed workspace usage in this pass:

- `budget` is the package anchor and is used throughout `static_collections`, `static_io`, and `static_queues`.
- `pool` and `capacity_report` are used by `static_io`.
- No external usage was found in this pass for `arena`, `stack`, `scratch`, `frame_scope`, `slab`, `slab_policy`, `epoch`, `debug_allocator`, `soft_limit_allocator`, `growth`, `profile_hooks`, or `tls_pool`.

## Package-Level Assessment

`static_memory` is important to the workspace, but it is less cohesive than `static_core` and more justified than `static_collections`.

The core of the package is strong:

- `budget`
- `pool`
- `arena`
- `stack`
- `scratch`
- `capacity_report`

These modules fit the repository goals well: explicit bounds, no hidden hot-path allocation, and useful operational reporting.

The package becomes less coherent at the edges, where it also owns:

- dev/test wrappers (`debug_allocator`);
- policy wrappers (`growth`, `soft_limit_allocator`, `slab_policy`);
- concurrency-heavy pooling (`tls_pool`);
- and `epoch`, which is change-tracking rather than allocation.

So the package is valuable overall, but the public surface is broader than the clearly adopted core.

## What Fits Well

### `budget` is the package anchor

`budget.zig` is the most justified module in the package.

It already provides shared value across the workspace by standardizing:

- byte reservation;
- overflow accounting;
- rejection signaling;
- and budget-aware allocator wrapping.

This is real shared infrastructure, not wrapper noise.

### `pool` is another strong primitive

`Pool` and `TypedPool(T)` are good fits for the workspace:

- bounded capacity;
- stable pointers;
- explicit `NoSpaceLeft`;
- no hot-path allocation after initialization.

This is one of the best-matched modules to the repository goals.

### `arena`, `stack`, and `scratch` form a sensible family

These modules overlap conceptually, but in a useful way:

- `Arena` for simple bump allocation;
- `Stack` for LIFO allocation with markers and `freeLast`;
- `Scratch` as a scoped wrapper over `Stack`;
- `frame_scope` as a tiny ergonomic layer over `Stack`/`Scratch`.

This layering is understandable and mostly disciplined.

## STD Overlap Review

### The core allocator types are justified despite std overlap

Closest std overlap:

- `std.heap.ArenaAllocator`
- `std.heap.FixedBufferAllocator`
- general allocator wrappers in std

Assessment:

- `Arena`, `Stack`, `Pool`, and `Scratch` are not just aliases. They add explicit bounds, reporting, and semantics that are more static-first than the std defaults.
- `Pool` especially has real value because stable pointers plus fixed-capacity blocks are a recurring need in this workspace.

Recommendation:

- Keep these modules as the package core.

### `budget`, `growth`, and `soft_limit_allocator` overlap each other more than std

Assessment:

- the package has multiple wrappers that mediate allocator denial/accounting policy:
  - `BudgetedAllocator`
  - `GuardedAllocator`
  - `SoftLimitAllocator`
  - `Slab` fallback policy
- each has a different semantic niche, but they live close together and can be hard to distinguish at a glance.

Recommendation:

- keep them only if the semantic split stays sharp and documented;
- otherwise this area is the first place where package-internal policy overlap may become confusing.

### `epoch.zig` has little to do with allocation

Closest std overlap:

- a plain `u64` counter plus a small wrapper struct

Assessment:

- `Epoch` / `Versioned(T)` are reasonable utilities, but they are not memory allocation primitives.
- They currently look more like shared state/versioning helpers than memory infrastructure.

Recommendation:

- revisit whether `epoch.zig` truly belongs in `static_memory` if/when it gains real consumers.

## Correctness and Completeness Findings

## Finding 1: `Scratch.init` asserts on a condition it is supposed to report as an operating error

`packages/static_memory/src/memory/scratch.zig:23` returns `ScratchError!Scratch`, but `packages/static_memory/src/memory/scratch.zig:26` asserts `capacity_bytes != 0` before delegating to `Stack.init`.

That is a real contract problem:

- the function advertises `error.InvalidConfig`;
- zero capacity is configuration input, not memory corruption;
- and in debug builds the assert will fire before the error path can be returned.

This violates the repo's own programmer-error versus operating-error split.

Recommendation:

- remove the precondition assert from `Scratch.init`;
- let `Stack.init` return `error.InvalidConfig`;
- add a direct test for zero-capacity `Scratch.init`.

## Finding 2: `Budget.lock` / `lockIn` currently add API surface without changing behavior

`budget.zig` exposes:

- `lock` at `packages/static_memory/src/memory/budget.zig:38`
- `lockIn` at `packages/static_memory/src/memory/budget.zig:45`
- `isLocked` at `packages/static_memory/src/memory/budget.zig:49`

But `tryReserve` at `packages/static_memory/src/memory/budget.zig:98` does not consult the lock flag, and there is no API for mutating the limit after initialization anyway.

So today the lock bit appears observational rather than semantic.

That does not make the code incorrect, but it does make the API story weaker:

- examples emphasize `lockIn()`;
- callers may infer that lock state changes reservation behavior;
- but the type currently behaves the same whether locked or unlocked.

Recommendation:

- either document clearly that lock state is metadata only;
- or remove the lock API;
- or make the lock materially affect the intended policy.

## Finding 3: The package's adopted core is narrower than the public surface

Real observed adoption in this pass is concentrated in:

- `budget`
- `pool`
- `capacity_report`

The rest of the package may still be useful, but many public modules currently have no external consumers.

Recommendation:

- prioritize the adopted core for polish and stability;
- treat the less-adopted modules as still proving themselves.

## Finding 4: `SoftLimitAllocator` is intentionally partial and should be treated that way in docs/examples

`soft_limit_allocator.zig` currently has allocator interface stubs that always reject:

- `resize` at `packages/static_memory/src/memory/soft_limit_allocator.zig:166`
- `remap` at `packages/static_memory/src/memory/soft_limit_allocator.zig:175`

That can be a valid choice, but it means the wrapper is not a drop-in allocator for clients that expect growth via `resize`/`remap`.

Recommendation:

- keep it if strict non-resizable semantics are intended;
- document that limitation more prominently;
- add example coverage if this allocator is expected to be used outside tests/dev tooling.

## Duplicate / Dead / Misplaced Code Review

### The core allocator family is coherent

`arena`, `stack`, `scratch`, and `frame_scope` are related and belong together.

They are not accidental duplication; they are a small hierarchy of increasingly ergonomic bounded allocation tools.

### The package edge is less cohesive

The modules most likely to warrant later boundary review are:

- `epoch`
- `profile_hooks`
- `debug_allocator`
- `soft_limit_allocator`
- `tls_pool`

These are not obviously bad, but they broaden the package away from "bounded allocator primitives" into a more mixed utility bucket.

Recommendation:

- if the package grows further, consider whether these remain under `static_memory` or whether some belong in a different shared layer.

### `slab` and policy wrappers are the main policy-overlap hotspot

There are multiple ways in this package to express:

- hard bounds;
- soft bounds;
- fallback behavior;
- budgeted growth;
- reporting of denied attempts.

This is useful, but it is also where conceptual overlap is highest.

Recommendation:

- keep semantics sharply differentiated;
- avoid adding yet another allocator policy wrapper unless a missing use case is concrete.

## Example Coverage

Example coverage is good for the package core, but weak for the package edge.

Covered well enough:

- `budget`
- `scratch`
- `arena`
- `TypedPool`

Missing examples for:

- `slab`
- `growth`
- `soft_limit_allocator`
- `debug_allocator`
- `tls_pool`
- `frame_scope`

Recommendation:

- if those modules are intended to remain public and stable, they need examples.
- otherwise, the current example set reinforces that the core package is really `budget` + bounded allocators, which may actually be the correct reading.

## Test Coverage

Coverage is solid and behavior-oriented.

Strengths:

- most modules have focused tests;
- overflow/high-water accounting is tested repeatedly;
- invalid-config and invalid-block paths are covered in several allocators;
- `tls_pool` has direct concurrency-oriented behavior checks.

Gaps:

- no direct zero-capacity `Scratch.init` test, which is exactly where the contract bug exists today;
- no integration-style tests showing how the different allocator wrappers compose;
- no clear adoption tests for the less-used policy modules.

Recommendation:

- add a direct `Scratch.init` invalid-config test;
- keep the rest of the coverage focused rather than merely increasing count.

## Adherence to `agents.md`

Overall assessment:

- the package takes bounds and high-water accounting seriously;
- initialization-time allocation is separated from hot-path use;
- explicit capacity reports are a good match for the repo style;
- comments generally explain rationale and operational semantics clearly.

Good fits with the repo rules:

- fixed-capacity structures are common;
- hot-path allocation is usually avoided after initialization;
- compile-time and runtime assertions are used heavily;
- interfaces are explicit rather than magical.

Meaningful deviations or tensions:

- `Scratch.init` currently mixes assertion behavior with an advertised operating-error path;
- some wrappers (`slab` fallback, `soft_limit_allocator`) intentionally reintroduce dynamic fallback behavior into a static-first package;
- package cohesion gets weaker outside the adopted allocator core.

## Refactor Paths

### Path 1: Treat `budget` + bounded allocators as the stable core

Most clearly justified stable core:

- `budget`
- `capacity_report`
- `pool`
- `arena`
- `stack`
- `scratch`
- `frame_scope`

This is the package identity that already makes sense.

### Path 2: Fix the `Scratch.init` contract bug immediately

This is the clearest correctness issue found in this pass:

- remove the assert;
- return the advertised error;
- add the missing test.

### Path 3: Clarify the role of lock/fallback policy APIs

Highest-value documentation cleanup:

- explain whether `Budget.lock` is semantic or informational;
- explain when `Slab` fallback is acceptable in a static-first codebase;
- explain that `SoftLimitAllocator` is intentionally non-resizable.

### Path 4: Revisit package boundaries only after adoption data improves

Do not split the package yet.

But if unused modules stay unused, the first candidates for relocation or pruning are:

- `epoch`
- `profile_hooks`
- `debug_allocator`
- `soft_limit_allocator`

## Bottom Line

`static_memory` is a valuable package, and the adopted core looks good. The most justified parts are `budget`, `pool`, and the bounded allocator family around `arena` / `stack` / `scratch`.

The main recommendations are:

1. fix the `Scratch.init` error-handling bug;
2. clarify or simplify the `Budget.lock` story;
3. keep the public package identity centered on the adopted bounded-allocation core; and
4. be cautious about further expanding the policy-wrapper edge of the package until real consumers justify it.
