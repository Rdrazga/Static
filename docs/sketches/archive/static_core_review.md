# Sketch: `static_core` Package Review

Date: 2026-03-06 (America/Denver)  
Status: First review pass completed.

## Scope

Review `packages/static_core/` for:

- adherence to `agents.md`;
- overlap with Zig standard library facilities and whether the package adds enough value;
- correctness and completeness at file and package scope;
- duplicate, dead, or misplaced code;
- example and test coverage; and
- practical refactor paths.

## Package Inventory

- Source files: 4 (`errors`, `config`, `options`, `time_budget`) plus `root.zig`.
- Examples: 2 (`config_validate`, `errors_vocabulary`).
- Benchmarks: 0.
- Inline unit tests: 10.
- Validation in this pass:
  - `zig build examples` passed.
  - `zig build test` is currently blocked by the unrelated `static_queues` stress-test failure at `packages/static_queues/src/testing/lock_free_stress.zig:105`.

Observed workspace usage:

- `errors` is widely used for vocabulary enforcement across packages.
- `time_budget` is used in `static_sync`, `static_scheduling`, and queue internals.
- `options` is used by package capability/config layers (`static_io`, `static_profile`, `static_queues`, `static_sync`).
- `config` has narrower but real usage in `static_net`.

## Package-Level Assessment

`static_core` is one of the most justified packages in the workspace.

It provides exactly the kind of shared foundation that should be centralized:

- canonical error vocabulary;
- consistent build-option access;
- small validation helpers; and
- a timeout-budget primitive reused by timed wait/retry code.

The package is small, focused, and already adopted by multiple other packages.

## What Fits Well

### `errors.zig` is the package anchor

This module is clearly valuable:

- it defines the shared error vocabulary;
- it gives packages a way to assert vocabulary compliance at compile time; and
- it keeps public error names consistent across the workspace.

This is foundational infrastructure, not wrapper noise.

### `time_budget.zig` is a good reusable primitive

The timeout-budget abstraction is small but meaningful. It centralizes:

- monotonic-clock use;
- timeout exhaustion checks; and
- consistent `Timeout` / `Unsupported` behavior.

Because timed waits exist in multiple packages, this belongs in `static_core`.

### `options.zig` keeps build-option access centralized

This module prevents packages from each reinterpreting the generated build options differently. It is a good single source of truth for feature gating and capability docs.

## STD Overlap Review

### `errors.zig`

Closest std overlap:

- none directly; std does not provide a project-wide canonical error vocabulary.

Assessment:

- very high value, low overlap.

Recommendation:

- Keep it central and keep other packages validating their module-specific error sets against it.

### `config.zig`

Closest std overlap:

- ordinary `if` checks at call sites

Assessment:

- This is the thinnest module in the package.
- It does provide a common `InvalidConfig` mapping and a tiny shared vocabulary for state-lock checks, but the abstraction is minimal.

Recommendation:

- Keep for now because it is small and already used.
- Revisit later whether it should remain a separate module or be folded into a broader validation/helpers surface if more helpers accumulate.

### `options.zig`

Closest std overlap:

- direct access to generated `static_build_options`

Assessment:

- The value is centralization and consistency, not new functionality.
- That is enough to justify the wrapper because the whole workspace depends on the same option names and meanings.

Recommendation:

- Keep it.

### `time_budget.zig`

Closest std overlap:

- `std.time.Instant`

Assessment:

- The module adds a real abstraction over raw std time handling by packaging timeout accounting and vocabulary-stable errors.

Recommendation:

- Keep it and continue using it from timed retry/wait paths.

## Correctness and Robustness Findings

## Finding 1: The repeated thread-safety wording is misleading here too

`errors.zig`, `config.zig`, and `options.zig` describe pure/stateless helpers as "not thread-safe" even though they do not own mutable shared state.

That wording is misleading. Pure functions and build-constant readers are safe for concurrent use.

Recommendation:

- Rewrite the docs to describe the real contract:
  - pure helpers are safe for concurrent use;
  - shared mutable state, if any, is the caller's responsibility.

## Finding 2: `errors.zig` has a strong runtime check but only a weak compile-time sync check

`packages/static_core/src/core/errors.zig:56` asserts only that `Tag` and `Vocabulary` have the same count. That does not fully prove the two remain synchronized by name.

The later tests and `has()` mapping help, so this is not a correctness bug today, but the stated compile-time guarantee is stronger than the actual assertion.

Recommendation:

- Strengthen the comptime invariant so it checks names/membership both ways, not just count.

## Finding 3: `time_budget` is good but missing one deterministic timeout-path test

The tests cover:

- zero timeout;
- positive timeout;
- unsupported clock on init;
- unsupported clock on remaining checks.

What is still missing is a deterministic fake-clock test for the actual timeout-expired path.

Recommendation:

- Add one test that uses `remainingOrTimeoutWithNowFn` with a fake clock value past the deadline and expects `error.Timeout`.

## Duplicate / Dead / Misplaced Code Review

There is little true duplication inside `static_core`, which is a good sign for a foundational package.

The only module that feels borderline is `config.zig`:

- it is very small;
- it mostly standardizes `InvalidConfig` checks;
- and it may or may not deserve to remain its own module long-term.

That said, it is not dead code and it does have real consumers.

## Example Coverage

The examples only cover:

- `config`
- `errors`

Missing example coverage:

- `options`
- `time_budget`

Recommendation:

- Add a small `time_budget` example showing timeout accounting with a loop budget.
- Add an `options` example only if package capability docs continue to rely on the public option names/types.

## Test Coverage

Coverage is appropriate for the package size:

- `errors`: 4 tests
- `config`: 1 test
- `options`: 1 test
- `time_budget`: 4 tests

Strengths:

- the central vocabulary path is tested;
- `time_budget` already tests unsupported-clock behavior from two code paths;
- the package is small enough that the current inline coverage is meaningful.

Gaps:

- no deterministic expired-budget test for `time_budget`;
- no compile-time proof that `Tag` and `Vocabulary` names remain synchronized, only count synchronization plus runtime tests.

## Prioritized Recommendations

### High priority

1. Fix misleading thread-safety wording in `errors`, `config`, and `options`.
2. Strengthen the compile-time `Tag`/`Vocabulary` synchronization invariant.

### Medium priority

1. Add a deterministic expired-budget test for `time_budget`.
2. Add a small `time_budget` example.

### Low priority

1. Revisit whether `config.zig` should stay as a standalone module if it remains this small.

## Bottom Line

`static_core` is in good shape and earns its place in the workspace.

Its main strengths are:

- strong shared error vocabulary;
- meaningful timeout-budget reuse;
- centralized build-option access; and
- clear adoption across other packages.

The review findings are mostly polish-level:

- documentation wording;
- a stronger compile-time invariant; and
- slightly better `time_budget` coverage.

This package should stay lean and foundational rather than expanding into a generic helper grab-bag.
