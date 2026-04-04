# Sketch: `static_queues` Package Review

Date: 2026-03-06 (America/Denver)  
Status: First review pass completed.

## Scope

Review `packages/static_queues/` for:

- adherence to `agents.md`;
- overlap with Zig standard library facilities and whether the package adds enough value;
- correctness and completeness at file and package scope;
- duplicate, dead, or misplaced code;
- example and test coverage; and
- practical refactor paths.

## Package Inventory

- Source files: large package spanning queue implementations, concepts, adapters, and test helpers.
- Examples: 12.
- Benchmarks: 3.
- Inline unit/behavior tests: 110 plus root wiring coverage.
- Standalone package metadata: present (`build.zig`, `build.zig.zon`).
- Validation in this pass:
  - `zig build examples` passed.
  - `zig build docs-lint` passed.
  - `zig build test` passed.

Observed workspace usage in this pass:

- `static_io` is the main real consumer and currently imports only `ring_buffer.RingBuffer(u32)`.
- `static_scheduling` re-exports `static_queues`, but I did not find direct package-local usage there in this pass.
- I found no external consumers for `concepts`, `adapters`, `testing`, `channel`, `broadcast`, `disruptor`, `priority_queue`, or the lock-free families.

## Package-Level Assessment

`static_queues` has a strong implemented core, but the package is much broader than current adoption.

The good part is real:

- bounded queue families are implemented with clear concurrency contracts;
- tests are extensive and include conformance helpers plus stress coverage;
- the package covers several genuinely different semantics rather than only renaming one queue shape.

The main concerns are package discipline rather than absence of work:

- the public surface is very large relative to observed use;
- there is visible wrapper and namespace duplication;
- standalone build wiring is inconsistent with package contents;
- and at least one stress test remains structurally flaky even though it passed on this pass.

## What Fits Well

### The package has a real adopted core

`RingBuffer` is already used by `static_io` across multiple backends. That gives the package one clearly justified, externally adopted primitive.

### The queue family distinctions are meaningful

The package is not just reimplementing the same queue repeatedly.

There are real semantic differences between:

- single-threaded storage (`ring_buffer`, `priority_queue`);
- mutex-protected queues (`mpsc`, `locked_queue`, `channel`, `broadcast`, `work_stealing_deque`);
- lock-free queues (`spsc`, `lock_free_mpsc`, `mpmc`, `disruptor`);
- and coordination/fanout forms (`channel`, `spsc_channel`, `wait_set`, `broadcast`, `disruptor`).

That is a legitimate package theme.

### Test infrastructure is unusually strong

The package has more serious behavior coverage than most packages reviewed so far:

- concept conformance checks;
- len-boundedness checks;
- registered-fanout semantics checks;
- work-stealing semantics checks;
- and stress tests for lock-free paths.

That is real engineering value.

## STD Overlap Review

### Standard-library overlap is low for queue primitives

Zig std does not provide this bounded queue family set with explicit concurrency contracts.

The package therefore adds real value around:

- fixed-capacity semantics;
- lock-free/mutex tradeoff choices;
- close and wait behavior;
- and package-local conformance vocabulary.

### `priority_queue.zig` is the strongest overlap pressure

Closest overlap:

- `std.PriorityQueue`
- `packages/static_collections/src/collections/min_heap.zig`

Assessment:

- overlap with std is partly justified because this version is fixed-capacity and allocation-front-loaded;
- overlap with `static_collections.min_heap` is more important inside this repo.

The best justification for keeping `static_queues.priority_queue` separate is not "it is a heap." The best justification is:

- queue-style naming and semantics within the package;
- explicit bounded `WouldBlock` behavior;
- and support for `update` / `remove` with index-tracking contexts.

Recommendation:

- keep it only if decrease-key/removal semantics are considered part of the queue package's remit;
- otherwise prefer `static_collections.min_heap` as the generic heap and avoid two bounded heap stories.

## Correctness and Completeness Findings

## Finding 1: The implemented core is strong, but current external adoption is narrow

Observed live usage is concentrated in `RingBuffer`.

That means the package currently has:

- one clearly adopted primitive;
- a large amount of self-tested but not yet externally proven surface.

This does not mean the other queues are wrong. It means the package should be careful about growing further before consumer pressure exists.

Recommendation:

- treat `ring_buffer`, `spsc`, `channel`, and perhaps one lock-free queue family as the likely stable core;
- let real downstream usage decide which advanced families deserve long-term surface permanence.

## Finding 2: Standalone package build wiring is incomplete

Concrete issue:

- `packages/static_queues/examples/priority_queue_basic.zig` exists;
- root workspace `build.zig` wires it;
- package-local `packages/static_queues/build.zig` does not.

Also:

- the package has 3 benchmarks in `benchmarks/`;
- package-local `build.zig` exposes no benchmark step.

That means the package contents and the standalone package build are out of sync.

Recommendation:

- add `priority_queue_basic` to `packages/static_queues/build.zig`;
- add a package-local benchmark step or explicitly document that benchmarks are workspace-only.

This is the clearest package-completeness bug from this pass.

## Finding 3: Wrapper and namespace duplication is high

Examples:

- `queues/lock_free_mpsc.zig` is a thin re-export of `queues/core/lock_free_mpsc.zig`;
- `queues/spsc_channel.zig` is a thin re-export of `queues/coordination/spsc_channel.zig`;
- `queues/wait_set.zig` is a thin re-export of `queues/coordination/wait_set.zig`;
- `queues/chase_lev_deque.zig` is a thin re-export of `queues/deques/chase_lev_deque.zig`.

In addition, the package exports:

- top-level queue modules;
- `queue_families`;
- `concepts`;
- `adapters`;
- `testing`.

Some of this is justified for navigation and stable top-level names. Taken together, it still creates a lot of public surface for a package with limited external adoption.

Recommendation:

- keep the stable top-level queue entry points;
- consider whether `queue_families`, `concepts`, and `adapters` need to be root-exported yet;
- and avoid adding more wrapper files unless they materially simplify consumption.

## Finding 4: The lock-free stress test is genuinely flaky

During this broader review sequence, `static_queues` test behavior was inconsistent across runs:

- one earlier `zig build test` pass completed successfully;
- this pass reproduced the known failure at `packages/static_queues/src/testing/lock_free_stress.zig:105`.

That inconsistency confirms the test is genuinely flaky rather than simply misreported.

`src/testing/lock_free_stress.zig` has traits that make it timing-sensitive:

- wall-clock time budgets;
- repeated `Thread.yield()` scheduling assumptions;
- fixed iteration cutoffs;
- success conditions tied to whether producers finish before the budget expires.

That structure is useful as a stress probe, but weak as a deterministic correctness gate.

Recommendation:

- keep the stress test as a probe for concurrency regressions;
- but do not treat it as a deterministic mainline correctness gate until scheduler sensitivity is reduced or the test is isolated behind a separate stress step.

## Finding 5: `priority_queue` needs a sharper package-boundary story

`priority_queue.zig` is technically fine and better featured than a minimal heap.

The package-boundary question is whether it belongs here or in `static_collections`.

The strongest arguments for keeping it here are:

- queue-oriented API naming;
- `WouldBlock`-style bounded semantics aligned with sibling queues;
- index-aware mutation and removal for scheduling workloads.

The strongest argument against is duplication with `static_collections.min_heap`.

Recommendation:

- document the intended distinction explicitly;
- if the distinction is not important, collapse toward one bounded heap implementation.

## Duplicate / Dead / Misplaced Code Review

### No obvious dead implementations

Most code looks intentional and tested.

### Public breadth is the main risk

The package is not full of dead code. It is full of code that is still mostly self-validated rather than consumer-validated.

### Testing and concept modules are useful, but root-exporting them is optional

`src/testing/` belongs in this package and follows repo structure well.

The weaker point is exporting it as part of the main root surface before real downstream consumers appear.

## Example Coverage

Example coverage is good in absolute terms.

Strengths:

- basic examples for ring, SPSC, MPMC, broadcast, disruptor, intrusive, work stealing, and channel close;
- one priority queue example exists;
- examples cover several distinct concurrency models.

Gaps:

- package-local `build.zig` does not actually build all of them;
- there is no example that contrasts the mutex-protected and lock-free variants for the same usage shape;
- there is no example showing the `concepts` / `adapters` layer from a real consumer perspective.

Recommendation:

- fix build wiring first;
- then only add examples if consumer adoption starts using the concept/adapter surface.

## Test Coverage

Coverage is one of the package's strengths.

Strengths:

- 110 inline tests;
- deterministic semantics coverage for most queue families;
- conformance helpers that verify shared contracts;
- and explicit stress testing for lock-free paths.

Gaps:

- real downstream integration tests are still minimal;
- the strongest correctness signals remain package-internal;
- and the lock-free stress layer is not fully deterministic.

Recommendation:

- preserve the current conformance suite;
- add cross-package behavior tests only where a downstream package actually depends on a specific queue family.

## Adherence to `agents.md`

Overall assessment:

- control flow is generally explicit;
- bounds and capacities are enforced aggressively;
- memory is front-loaded to initialization;
- comments explain concurrency tradeoffs and semantics;
- and the package shows strong assertion discipline.

This package aligns well with the repo's safety and boundedness rules.

The main watch item is package sprawl, not unsafe coding style.

## Refactor Paths

### Path 1: Identify the stable adopted core

Treat the currently justified core as:

- `ring_buffer`
- `spsc`
- `channel`
- one mutex queue
- one lock-free queue

Then let the rest prove themselves through downstream use.

### Path 2: Tighten public root exports

Keep the top-level queue names, but reconsider whether these need root exports yet:

- `concepts`
- `adapters`
- `testing`
- `queue_families`

If they are mainly internal infrastructure today, surface them more narrowly.

### Path 3: Fix standalone build completeness

Make package-local `build.zig` reflect package contents:

- include `priority_queue_basic`;
- decide how benchmarks should be built;
- keep standalone package behavior aligned with workspace behavior.

### Path 4: Resolve the heap duplication story

Choose and document the distinction between:

- `static_collections.min_heap`
- `static_queues.priority_queue`

If both remain, they should have clearly different reasons to exist.

## Bottom Line

`static_queues` is technically strong but broader than current adoption justifies.

The package's best assets are:

1. a real adopted `ring_buffer` core;
2. unusually strong contract and behavior tests;
3. meaningful queue-family distinctions.

The highest-value recommendations are:

1. fix package-local build completeness;
2. reduce unnecessary public surface and wrapper noise;
3. treat the lock-free stress layer as flake-risk until it is made more deterministic; and
4. clarify why `priority_queue` lives here instead of collapsing toward `static_collections.min_heap`.
