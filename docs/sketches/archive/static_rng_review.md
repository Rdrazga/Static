# Sketch: `static_rng` Package Review

Date: 2026-03-06 (America/Denver)  
Status: First review pass completed.

## Scope

Review `packages/static_rng/` for:

- adherence to `agents.md`;
- overlap with Zig standard library facilities and whether the package adds enough value;
- correctness and completeness at file and package scope;
- duplicate, dead, or misplaced code;
- example and test coverage; and
- practical refactor paths.

## Package Inventory

- Source files: 5 modules plus `root.zig` (6 total).
- Examples: 2 (`pcg32_basic`, `shuffle_basic`).
- Benchmarks: none.
- Inline unit/behavior tests: 18 plus root wiring coverage.
- Standalone package metadata: present (`build.zig`, `build.zig.zon`).
- Validation in this pass:
  - `zig build examples` passed.
  - `zig build docs-lint` passed.
  - `zig build test` passed.

Observed workspace usage in this pass:

- no package outside `static_rng` currently imports it;
- examples are the only direct usage proof I found;
- `build.zig` declares `static_core`, but the implemented source files do not import it.

## Package-Level Assessment

`static_rng` is small, cohesive, and technically clear.

Its implemented scope is narrow:

- deterministic PRNG engines;
- simple bounded distribution helpers;
- and Fisher-Yates shuffle over caller-owned slices.

That is a good package shape.

The main concerns are maturity and dependency discipline rather than algorithmic quality:

- there are no downstream consumers yet;
- std overlap is substantial because these are well-known engines;
- and the package currently carries a `static_core` dependency without implemented use.

## What Fits Well

### The package is tightly scoped

It does not try to become a general statistics or crypto package.

The current surface is small and coherent:

- seedable deterministic engines;
- value-range helpers;
- one shuffle primitive.

### Explicit-state design is correct

All generators hold their state in value types with no global RNG singleton.

That is the right fit for this repo's determinism goals.

### Distribution helpers stay allocation-free and bounded

`uintBelow`, `uintInRange`, `f32Unit`, `f64Unit`, and `shuffleSlice` all operate on caller-provided state and storage. That matches the repo rules well.

## STD Overlap Review

### Overlap with std is significant

Closest overlap:

- `std.Random` engines and helper APIs;
- standard shuffle and range-sampling patterns built on those engines.

Assessment:

- the algorithms themselves are not novel;
- but the package does provide workspace-local benefits:
  - explicit choice of a small deterministic engine set;
  - package-local docs and contracts about splitting/jumping;
  - no hidden global state;
  - and a stable, minimal API surface.

Recommendation:

- keep the package only as long as the repo wants a curated deterministic RNG surface rather than direct std usage.

### The main value is policy, not algorithm novelty

The strongest case for `static_rng` is:

- one repo-approved engine set;
- deterministic behavior for tests and simulations;
- explicit non-crypto positioning;
- and consistent helper semantics.

If that policy value weakens, std would be a viable replacement for much of this package.

## Correctness and Completeness Findings

## Finding 1: The implemented package is technically sound and bounded

The code is small enough to audit directly, and the main contracts look correct:

- deterministic seeding;
- explicit split/jump semantics;
- bounded rejection sampling;
- and in-place shuffle over caller-owned slices.

No obvious implementation bug stood out in this pass.

## Finding 2: `static_core` is currently an unused active dependency

Observed state:

- `packages/static_rng/build.zig` depends on `static_core`;
- `packages/static_rng/build.zig.zon` declares `static_core`;
- no source file currently imports or uses `static_core`.

That is unnecessary package coupling today.

Recommendation:

- remove `static_core` from the package dependency set unless a concrete source-level need is introduced.

This is the clearest package-completeness issue from this pass.

## Finding 3: Consumer maturity is still low

I found no downstream package imports of `static_rng`.

That means the package is currently:

- internally coherent;
- well-tested for its size;
- but still mostly self-validated.

Recommendation:

- keep the API small and resist adding more engines or distributions until a real downstream package needs them.

## Finding 4: `uintBelow` uses `unreachable` as a pathological-engine escape hatch

`distributions.uintBelow` retries up to 1024 times and then hits `unreachable`.

That is defensible if the package contract is:

- RNG engines must make progress and provide suitably distributed `nextU64()` output;
- failure to do so is a programmer error, not an operating error.

Still, this is one of the few places where the package relies on a liveness assumption about the RNG implementation.

Recommendation:

- keep the current behavior if that contract is intentional;
- otherwise document it more explicitly at the function boundary.

I would not broaden this into an operating-error path unless the package intends to support arbitrary user-defined RNG types with weak guarantees.

## Duplicate / Dead / Misplaced Code Review

### No obvious dead code

The package is small and everything present appears intentional.

### No serious internal duplication

The modules are distinct and minimal.

### No misplaced functionality

The current helpers fit the package. None of them look like they belong in another reviewed package more naturally than they do here.

## Example Coverage

Example coverage is adequate but thin.

Current examples show:

- basic `Pcg32` output;
- basic shuffle behavior.

Missing examples:

- `Xoroshiro128Plus` jump/split behavior;
- distribution helpers (`uintBelow`, `uintInRange`, `f32Unit`, `f64Unit`);
- explicit explanation that the package is non-cryptographic.

Recommendation:

- add one example centered on `Xoroshiro128Plus.split` or `jump` if the package gains real consumers;
- otherwise the current examples are acceptable for a small, not-yet-adopted package.

## Test Coverage

Coverage is good for the package size.

Strengths:

- deterministic-seed tests for all engines;
- split/jump behavior coverage;
- distribution bound checks;
- shuffle determinism and preservation checks.

Gaps:

- no cross-package consumer tests because there are no consumers yet;
- no explicit negative test for pathological custom RNG behavior in `uintBelow`;
- no statistical-quality tests, which is reasonable for this repo but worth noting.

Recommendation:

- keep the current tests;
- do not add heavyweight statistical batteries unless a package actually depends on stronger RNG quality guarantees.

## Adherence to `agents.md`

Overall assessment:

- control flow is simple and bounded;
- comments explain algorithm choices and intended use;
- all state is explicit;
- and the package stays narrowly scoped.

This package aligns well with the repo rules.

The main watch item is unnecessary dependency weight, not unsafe implementation style.

## Refactor Paths

### Path 1: Remove the unused `static_core` dependency

This is the simplest concrete cleanup and would make the package more honest about its current implementation needs.

### Path 2: Keep the package policy-focused

Do not compete with std by adding many engines or probability distributions.

Keep the package as a curated deterministic RNG subset.

### Path 3: Let adoption decide whether the package remains distinct from std

If downstream packages begin using it, the package is justified as the repo's RNG policy layer.

If not, the overlap with std becomes harder to defend over time.

## Bottom Line

`static_rng` is clean, small, and correct-looking, but it is still mostly a policy package rather than a uniquely powerful implementation package.

The highest-value recommendations are:

1. remove the unused `static_core` dependency;
2. keep the API small and deterministic;
3. avoid adding more engines until real consumers appear; and
4. treat the package's long-term justification as a curated std-adjacent policy layer, not as a replacement for std RNG breadth.
