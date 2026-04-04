# Sketch: `static_scheduling` Package Review

Date: 2026-03-06 (America/Denver)  
Status: First review pass completed.

## Scope

Review `packages/static_scheduling/` for:

- adherence to `agents.md`;
- overlap with Zig standard library facilities and whether the package adds enough value;
- correctness and completeness at file and package scope;
- duplicate, dead, or misplaced code;
- example and test coverage; and
- practical refactor paths.

## Package Inventory

- Source files: 8 modules plus `root.zig` (9 total).
- Examples: 1 (`task_graph_topo`).
- Benchmarks: none.
- Inline unit/behavior tests: 30 plus root wiring coverage.
- Standalone package metadata: present (`build.zig`, `build.zig.zon`).
- Validation in this pass:
  - `zig build examples` passed.
  - `zig build docs-lint` passed.
  - `zig build test` remains blocked by the flaky `static_queues` lock-free stress failure at `packages/static_queues/src/testing/lock_free_stress.zig:105`.

Observed workspace usage in this pass:

- no package outside `static_scheduling` currently imports it;
- the package is still self-validated rather than consumer-validated;
- `root.zig` re-exports `static_queues`, but I found no implemented module in `static_scheduling/src/` importing that root alias.

## Package-Level Assessment

`static_scheduling` has a solid implemented core, but its public surface is ahead of its current maturity.

The strongest implemented pieces are:

- deterministic topo sort;
- task-graph planning;
- timer wheel scheduling;
- executor and thread-pool basics;
- and a useful fake poller abstraction.

Those parts fit together as a scheduling package.

The main weaknesses are package completeness and surface discipline:

- standalone package metadata is inconsistent with source dependencies;
- deferred placeholders are still exported publicly;
- some docs/rationale are stale;
- and there are no real downstream consumers yet.

## What Fits Well

### The deterministic planning core is strong

`topo.zig` and `task_graph.zig` are cohesive and already feel like stable package-core material.

The deterministic tie-breaking policy is well justified for this repo.

### Timer wheel belongs here

`timer_wheel.zig` is a good fit for the package theme and gives the package a concrete runtime scheduling primitive beyond pure graph planning.

### Fake poller is useful

The fake poller gives the package a deterministic testing/storytelling layer for readiness-driven scheduling without requiring OS backends.

## STD Overlap Review

### Standard-library overlap is limited

Closest overlap:

- threads and mutex/condvar primitives from `std` / `static_sync`;
- generic heap/graph building blocks elsewhere in the repo;
- ad hoc task execution patterns a caller could hand-roll.

Assessment:

- std does not provide this deterministic package-level combination of topo planning, timer wheel, poller abstraction, and bounded executor/thread-pool helpers;
- the value here is in the package-local policy and composition, not one isolated novel algorithm.

Recommendation:

- keep the package centered on deterministic scheduling composition rather than turning it into a generic concurrency toolkit.

## Correctness and Completeness Findings

## Finding 1: Standalone package metadata is inconsistent with the implemented source tree

Concrete issue:

- `src/scheduling/timer_wheel.zig` imports `static_collections`;
- `packages/static_scheduling/build.zig` does not declare or import `static_collections`;
- `packages/static_scheduling/build.zig.zon` also omits `static_collections`.

The root workspace `build.zig` already includes `static_collections` for `static_scheduling`, so the inconsistency is package-local, not theoretical.

Recommendation:

- add `static_collections` to `packages/static_scheduling/build.zig` and `packages/static_scheduling/build.zig.zon`.

This is the clearest concrete package-completeness defect from this pass.

## Finding 2: Public placeholders are still part of the shipped surface

Two public placeholder surfaces stand out:

- `command_buffer.zig` exports only a type alias placeholder;
- `parallel_for.zig` exports `runParallel` as a placeholder struct.

That creates the same problem seen in `static_profile`:

- the root module advertises more maturity than the implementation has;
- deferred design notes become part of the public library surface;
- and consumers can depend on placeholder symbols that are not real features.

Recommendation:

- remove or hide these placeholders from the public root until implemented;
- or move the deferred design material fully into docs/plans.

## Finding 3: Some documentation/rationale is stale

Examples:

- `parallel_for.zig` says a thread-pool surface is not yet available, but `thread_pool.zig` now exists;
- several files reference missing docs such as `docs/packages/static_scheduling/spec.md`, `docs/packages/static_core/errors.md`, and `docs/roadmap/09_deferred_items_schedule.md`.

That weakens package clarity even though the code comments are otherwise decent.

Recommendation:

- remove stale references and update rationale to match current implementation state;
- make code comments self-contained again.

## Finding 4: `ThreadPool.Config.local_queue_capacity` is currently unused

`thread_pool.zig` accepts:

- `global_queue_capacity`
- `local_queue_capacity`

But the implementation explicitly ignores `local_queue_capacity` with `_ = cfg.local_queue_capacity;`.

That means the public config implies a design the implementation does not currently provide.

Recommendation:

- either remove `local_queue_capacity` until local queues exist;
- or implement the behavior it suggests.

Right now it is configuration surface without semantic effect.

## Finding 5: External adoption is still low, so surface growth should stop

I found no downstream package imports of `static_scheduling`.

That means the package is currently:

- technically promising;
- reasonably well tested;
- but still mostly proving itself internally.

Recommendation:

- treat `topo`, `task_graph`, `timer_wheel`, and perhaps `poller` as the real adopted-core candidates;
- keep the rest narrow until real consumers appear.

## Duplicate / Dead / Misplaced Code Review

### No obvious dead implementations in the core

The implemented modules look intentional and coherent.

### Placeholder exports are the closest thing to dead weight

They are not forgotten code, but they do inflate the public surface with non-features.

### Package boundary is otherwise sound

The implemented modules belong here more naturally than in any other reviewed package.

## Example Coverage

Example coverage is thin.

Current examples cover only:

- task-graph topo planning.

Missing examples:

- timer wheel scheduling and cancellation;
- fake poller registration/injection flow;
- executor sequential vs worker-pool behavior;
- thread-pool backpressure semantics.

Recommendation:

- add one timer-wheel example and one executor/poller example before expanding package scope further.

## Test Coverage

Coverage is good for the implemented core:

- topo/task-graph behavior;
- timer wheel scheduling;
- fake poller behavior;
- thread-pool backpressure;
- executor join/timeout/cancel semantics.

Gaps:

- no downstream integration tests because there are no consumers yet;
- examples are much thinner than the implementation surface;
- placeholders have only minimal type-contract tests, which is another sign they should not be public yet.

Recommendation:

- keep the current tests;
- add examples before adding more unit tests unless a new bug appears.

## Adherence to `agents.md`

Overall assessment:

- control flow is explicit;
- allocation is front-loaded in implemented modules;
- bounds are consistently enforced;
- and comments generally explain rationale.

The package aligns well with repo rules in its implemented core.

The main adherence gap is public-surface discipline and stale documentation, not unsafe implementation style.

## Refactor Paths

### Path 1: Fix package metadata first

Bring `build.zig` and `build.zig.zon` into sync with the actual source dependency graph by adding `static_collections`.

### Path 2: Reduce the public package to implemented features

Keep the real core visible:

- `topo`
- `task_graph`
- `timer_wheel`
- `poller`
- `thread_pool`
- `executor`

Hide or remove placeholder surfaces until they are implemented.

### Path 3: Remove stale config and docs

Clean up:

- dead doc links;
- stale comments about missing thread-pool support;
- `local_queue_capacity` if it remains semantically unused.

### Path 4: Let real users decide the broader shape

Do not expand the package based only on internal plans.

Wait for real downstream scheduling consumers before adding more abstractions.

## Bottom Line

`static_scheduling` has a strong deterministic core, but its packaging and public surface are ahead of its current maturity.

The highest-value recommendations are:

1. fix the missing `static_collections` standalone dependency;
2. remove or hide public placeholders;
3. clean up stale docs/comments and unused config surface; and
4. add a couple of examples before expanding the API further.
