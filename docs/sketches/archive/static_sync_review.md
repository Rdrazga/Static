# Sketch: `static_sync` Package Review

Date: 2026-03-06 (America/Denver)  
Status: First review pass completed.

## Scope

Review `packages/static_sync/` for:

- adherence to `AGENTS.md`;
- overlap with Zig standard synchronization facilities and whether the package adds enough value;
- correctness and completeness at file and package scope;
- duplicate, dead, or misplaced code;
- example and test coverage; and
- practical refactor paths.

## Package Inventory

- Source files: 12 sync modules plus `root.zig`.
- Examples: 6 (`mutex_basic`, `once_basic`, `cancel_basic`, `event_wait_for_work`, `barrier_basic`, `grant_token_basic`).
- Benchmarks: 0.
- Inline unit/behavior tests: 69 plus root wiring coverage.
- Validation in this pass:
  - `zig build examples` passed.
  - `zig build docs-lint` passed.
  - `zig build test` passed.

Observed workspace usage in this pass:

- No external package usage was found under `packages/` or `docs/`.
- Current usage appears limited to `static_sync`'s own examples and tests.

## Package-Level Assessment

`static_sync` is useful, but it is not equally strong across its surface.

The strongest parts are the pieces that add policy Zig std does not package this way:

- `cancel.zig`
- `grant.zig`
- `wait_queue.zig`
- capability-gated waiting surfaces in `event.zig`, `barrier.zig`, and `semaphore.zig`

Those modules give the package a real identity:

- explicit single-threaded versus multi-threaded gating;
- bounded cancellation registration;
- explicit timeout and cancellation vocabulary;
- and fixed-shape capability tokens for authorization-like flows.

The weakest parts are the thin wrapper or near-wrapper surfaces:

- `root.zig` re-export of `std.Thread.Mutex`
- `root.zig` re-export of `std.Thread.RwLock`
- much of `condvar.zig`

Those are not broken, but they are harder to justify as stable public package surface.

So the package is best understood as a synchronization policy layer over std, not as a replacement for std synchronization primitives.

## What Fits Well

### Build-gated concurrency surface is the package's main value

The package consistently exposes compile-time capability gating around:

- `single_threaded`
- OS backend availability
- timeout support

That is valuable because it lets higher-level packages depend on a single explicit policy layer instead of open-coding `builtin` and build-option checks everywhere.

### `cancel.zig` is a strong package-local primitive

`CancelSource`, `CancelToken`, and bounded wake registrations fit the repo well:

- no allocation;
- explicit vocabulary;
- bounded registration capacity;
- and a clear cooperative cancellation model.

This is one of the clearest reasons for the package to exist.

### `grant.zig` is a distinct and justified utility

`Grant` is not a standard synchronization primitive, but it is useful and coherent:

- bounded capability tracking;
- explicit access levels;
- explicit write records;
- and deterministic token validation.

It belongs here if the package wants to be broader than raw thread primitives.

### `wait_queue.zig` adds a useful OS-backed waiting boundary

`wait_queue.zig` packages:

- futex-style wait semantics;
- explicit timeout handling;
- explicit cancellation integration;
- and capability gating.

That is materially better than leaving each caller to hand-roll those rules.

## STD Overlap Review

### `mutex` and `rwlock` are extremely thin wrappers

Closest std overlap:

- `std.Thread.Mutex`
- `std.Thread.RwLock`

Assessment:

- These exports add almost no behavior.
- They mainly centralize naming under the package root.
- That is a weak reason to widen public API.

Recommendation:

- Reconsider whether `mutex` and `rwlock` should remain explicit package exports, or whether callers should use std directly.

### `condvar.zig` is a light wrapper with capability gating

Closest std overlap:

- `std.Thread.Condition`

Assessment:

- The wrapper adds some value through compile-time gating and a zero-size unavailable branch.
- But it is still close to std, and its surface should remain narrow.

Recommendation:

- Keep it only as a capability-gated adapter, not as a place to grow extra API.

### `event`, `barrier`, `semaphore`, and `once` are more justified

Closest std overlap:

- standard synchronization building blocks

Assessment:

- Even where std has nearby primitives, this package adds explicit build-mode gating, timeout vocabulary, and uniform package-local contracts.
- That is enough justification for these modules.

Recommendation:

- Keep these modules centered on explicit policy and portability rules, not just alternate naming.

## Correctness and Completeness Findings

## Finding 1: The package is strongest as a policy layer, not as a blanket std wrapper

The package currently exports both:

- genuinely package-specific pieces (`cancel`, `grant`, `wait_queue`, `caps`);
- and almost direct std re-exports (`mutex`, `rwlock`).

That makes the boundary fuzzy.

Recommendation:

- Treat std-wrapper exports as the most removable surface.
- Keep the package focused on what it adds beyond std: gating, boundedness, cancellation, timeout semantics, and capability tokens.

## Finding 2: Several contention paths use bounded CAS loops that end in panic

Examples include:

- `Latch.countDown`
- `Semaphore.post`
- `Semaphore.tryWait`

These panic when bounded retry loops exhaust.

This is defensible as a liveness/invariant assertion only if the package really means:

- "persistent CAS failure beyond this bound indicates pathological contention or a deeper bug, not an operating condition."

That is a valid stance, but it is a strong contract choice and should remain explicit.

I do not consider these immediate defects in the same way as the `IncrementalBVH.remove` OOM case was, because these are not allocator failures. They are liveness assertions.

Recommendation:

- Keep the current behavior only if the package intends these bounds as hard liveness assertions.
- Avoid silently changing these loops into unbounded retries.

## Finding 3: Example coverage is decent, but still incomplete relative to the surface

Examples exist for:

- mutex
- once
- cancel
- event
- barrier
- grant

Missing example coverage:

- semaphore
- seqlock
- wait queue
- condvar
- padded atomic
- backoff

Given the package size, this is not terrible, but the highest-value nontrivial modules still lack examples.

Recommendation:

- Add a `semaphore_basic` and `seqlock_basic` example before any further API expansion.
- Add a `wait_queue_basic` example only if the package wants to teach OS-backend-gated behavior explicitly.

## Finding 4: `root.zig` broadens surface by re-exporting `static_core`

`root.zig` exports:

- `pub const core = @import("static_core");`

That makes the sync package root a transitively broader import surface than its own identity really needs.

This is not necessarily wrong, but it weakens boundaries:

- callers importing `static_sync` gain unrelated `static_core` surface;
- package identity becomes less crisp;
- and the root starts acting as an umbrella rather than a focused module.

Recommendation:

- Reconsider whether `static_core` should be publicly re-exported from the root.

## Finding 5: The package is still self-validated

No downstream package consumers were found in this pass.

That means:

- there is not yet external evidence for which exported primitives matter most;
- the thin std-wrapper surface is especially unproven;
- and the package should stay restrained until higher-level packages force clearer boundaries.

Recommendation:

- Let real consumers determine whether the current breadth is justified.

## Duplicate / Dead / Misplaced Code Review

### The multi-threaded / single-threaded dual branches are deliberate duplication

Modules like:

- `event.zig`
- `barrier.zig`
- `semaphore.zig`

duplicate logic across capability branches.

That duplication is justified because:

- the API shape changes by build mode;
- the control flow remains easy to inspect;
- and the package avoids a metaprogramming maze.

Recommendation:

- Keep this duplication explicit unless maintenance pain becomes real.

### The clearest over-broad surface is wrapper exposure, not dead code

I did not find a strong dead-code equivalent like unused error variants here.

The bigger issue is public surface breadth:

- std wrapper exports;
- transitive `static_core` re-export;
- and modules with low current adoption evidence.

### `grant.zig` is unusual but not misplaced

It is not a classic sync primitive, but it still fits a broader "coordination/capability" package better than most other places in this repo.

I would keep it here unless the repo later creates a clearer auth/capability-oriented package.

## Example Coverage

Current example coverage is better than several recent packages:

- mutex
- once
- cancel
- event
- barrier
- grant

Missing example coverage:

- semaphore
- seqlock
- wait queue
- condvar

Recommendation:

- Prioritize examples for modules with real semantic weight, not helper modules.

## Test Coverage

Coverage is strong.

Strengths:

- cross-thread behavior tests exist for `once`, `event`, `condvar`, `barrier`, and `semaphore`;
- build-mode gating is explicitly tested with `@hasDecl`;
- timeout paths are covered;
- cancellation is tested;
- grant lifecycle and token semantics are tested.

Gaps:

- no downstream integration tests because there are no consumers yet;
- no example-backed tests for modules like `seqlock` and `wait_queue`;
- no stronger package-level tests proving which root exports are worth keeping public.

The current test suite is a package strength. The biggest next gains are documentation/examples, not raw test count.

## Adherence to `AGENTS.md`

Overall assessment:

- the package is explicit and bounded in its own chosen ways;
- comments generally explain rationale;
- loops are bounded;
- build-mode gating is clear;
- and tests cover behavior rather than only trivial units.

Good fits with the repo rules:

- bounded retry loops instead of silent infinite spinning;
- explicit timeout and cancellation vocabulary;
- capability-gated API shape;
- strong behavior tests for concurrency paths.

Meaningful divergences:

- thin std-wrapper exports broaden public API with little extra value;
- some modules intentionally expose placeholders or absent APIs by build mode;
- contention exhaustion uses `@panic`, which is a strong policy choice and should remain justified.

These divergences are acceptable if the package remains explicit about them. The weakest one is still the thin wrapper surface.

## Refactor Paths

### Path 1: Tighten the root surface

Highest-value cleanup:

- reconsider `mutex` and `rwlock` root exports;
- reconsider public `core` re-export from `root.zig`.

### Path 2: Keep the package centered on policy-rich primitives

The clearest package identity is:

- cancellation;
- gated waiting;
- bounded synchronization helpers;
- explicit timeout/capability policy.

That is stronger than trying to be a full replacement namespace for std sync primitives.

### Path 3: Add examples for the next-most-important modules

Best next examples:

- `semaphore_basic`
- `seqlock_basic`
- optionally `wait_queue_basic` if OS-backed waiting is meant to be part of the package story

### Path 4: Let downstream adoption decide whether wrapper breadth survives

If future packages only use:

- `cancel`
- `event`
- `barrier`
- `wait_queue`

then the std-wrapper exports should probably shrink.

## Bottom Line

`static_sync` is a good package when read as a synchronization policy layer over std, not as a wholesale replacement for std synchronization primitives.

The strongest modules are `cancel`, `grant`, `wait_queue`, and the build-gated waiting primitives. The weakest surface is the thin std-wrapper layer and the broad root export surface.

The main findings from this pass are:

1. the package's real value is policy and capability gating, not std renaming;
2. contention-path `@panic` sites are defensible but should remain explicitly justified as liveness assertions;
3. example coverage is decent but still misses `semaphore`, `seqlock`, and `wait_queue`;
4. `root.zig` likely exports more than the package identity requires; and
5. there are still no downstream consumers proving the current breadth is warranted.

The best next step is to tighten the root surface and expand examples for the policy-rich modules, not to broaden the wrapper layer.
