# Sketch: `static_profile` Package Review

Date: 2026-03-06 (America/Denver)  
Status: First review pass completed.

## Scope

Review `packages/static_profile/` for:

- adherence to `agents.md`;
- overlap with Zig standard library facilities and whether the package adds enough value;
- correctness and completeness at file and package scope;
- duplicate, dead, or misplaced code;
- example and test coverage; and
- practical refactor paths.

## Package Inventory

- Source files: 7 modules plus `root.zig` (8 total).
- Examples: 3 (`chrome_trace_basic`, `counter_basic`, `hooks_emit_basic`).
- Benchmarks: none.
- Inline unit/behavior tests: 20 plus root wiring coverage.
- Standalone package metadata: present (`build.zig`, `build.zig.zon`).
- Validation in this pass:
  - `zig build examples` passed.
  - `zig build docs-lint` passed.
  - `zig build test` remains blocked by the unrelated `static_queues` stress-test failure at `packages/static_queues/src/testing/lock_free_stress.zig:105`.

Observed workspace usage in this pass:

- no package-local consumers outside `static_profile` were found;
- examples are the only current direct usage proof;
- `static_serial` is declared and re-exported, but no implemented module currently imports it.

## Package-Level Assessment

`static_profile` is partly mature and partly still speculative.

The implemented core is coherent:

- bounded in-memory Chrome trace capture;
- counter events sharing the same timeline;
- capability gating through `caps`;
- and dependency-inversion hooks for subsystems that should not import the package directly.

That implemented core fits the repo well. It is allocation-bounded after initialization, explicit about contracts, and technically stronger than ad hoc logging.

The main package-level weakness is that the public surface is broader than the implemented value:

- `thread_trace.zig` and `binary_trace.zig` are public placeholder stubs;
- `static_serial` is already a declared dependency for a deferred feature, not for active code;
- and I found no real package consumers yet, so the package is still mostly self-validated.

## What Fits Well

### The trace/counter core is cohesive

`trace.zig` and `counter.zig` clearly belong together.

The unified event buffer is the right design choice because it preserves one coherent exported timeline rather than splitting zone and counter streams.

### The hook pattern is justified

`hooks.zig` solves a real architectural problem:

- lower packages can emit profiling counters;
- applications can wire those counters to `static_profile`;
- and subsystem packages avoid downward dependencies.

That is a good package-specific abstraction rather than generic helper noise.

### Capability gating is simple and explicit

`caps.zig` mirrors build options without introducing policy complexity. That is the correct scale for the feature.

## STD Overlap Review

### Standard-library overlap is low

Closest overlap:

- generic JSON writing support in `std`;
- generic logging/printing facilities;
- external-profiler integrations outside this package.

Assessment:

- std does not provide this bounded trace-buffer abstraction;
- std does not provide the package-local hook pattern for downward-dependency avoidance;
- and the Chrome-trace export format is not merely a wrapper around std functionality.

Recommendation:

- keep the package focused on bounded profiling primitives rather than broad observability tooling.

### `static_serial` overlap is currently only hypothetical

`binary_trace.zig` explicitly plans to use `static_serial`, and the package build metadata already depends on it.

But today:

- no implemented module uses `static_serial`;
- the only binary-trace artifacts are placeholder constants and an empty struct;
- and `root.zig` re-exports `serial` without active package need.

Recommendation:

- if binary trace remains deferred, remove the live `static_serial` dependency and root re-export until the feature is promoted;
- otherwise implement enough binary-trace surface to justify the dependency.

## Correctness and Completeness Findings

## Finding 1: The implemented trace path is strong and bounded

The core `EnabledTrace` / `DisabledTrace` design is good:

- bounded capacity reserved during `init`;
- no hidden allocation during steady-state recording;
- explicit `NoSpaceLeft` behavior;
- and debug-only zone pairing assertions.

This is the package's strongest implemented value.

Recommendation:

- keep this core stable and treat it as the real package center of gravity.

## Finding 2: Public placeholder modules are the biggest package-scope weakness

`thread_trace.zig` and `binary_trace.zig` are exported from `root.zig`, but both are still documented placeholders with empty structs.

That creates avoidable surface-area problems:

- consumers can import symbols that are not real features;
- package docs imply more maturity than the implementation provides;
- and deferred design notes become part of the shipped API.

The issue is not that the ideas are bad. The issue is that deferred placeholders are living in the public library surface.

Recommendation:

- either remove these modules from the public root until they are promoted;
- or move the deferred design notes fully into planning/docs and keep only implemented APIs in `src/`.

This is the highest-value package-boundary correction from this pass.

## Finding 3: `static_serial` is currently an unjustified active dependency

`build.zig`, `build.zig.zon`, and `root.zig` all treat `static_serial` as an active dependency.

Observed usage in current implementation:

- no source file imports `static_serial`;
- only placeholder comments in `binary_trace.zig` mention it.

That means the package currently carries a real dependency for a deferred feature.

Recommendation:

- remove the dependency until binary trace is implemented;
- or promote a real binary trace slice that actually uses `static_serial`.

Keeping dormant dependencies increases package surface and muddies the package's true implemented core.

## Finding 4: Documentation references are stale

Several source files reference:

- `docs/packages/static_profile/spec.md`;
- `docs/roadmap/09_deferred_items_schedule.md`.

Those paths do not currently exist in the repo.

The module docs are still mostly self-contained, so this is not a catastrophic documentation failure. It is still a completeness problem because:

- readers are pointed at missing artifacts;
- deferred-feature rationale looks less grounded than intended;
- and code comments appear to depend on documentation that is no longer present.

Recommendation:

- remove or update the dead references;
- if the design context still matters, point to existing plan documents or restate the rationale directly in code comments.

## Finding 5: The package still lacks external consumer pressure

I found no package outside `static_profile` importing it yet.

That means:

- the package is technically solid but not yet proven by cross-package adoption;
- `hooks.zig` solves a real architectural problem, but the current repo has not yet demonstrated that problem with live consumers;
- and placeholder surface is especially risky when consumer pressure is still low.

Recommendation:

- keep the implemented API narrow until one or two real subsystem integrations exist.

## Duplicate / Dead / Misplaced Code Review

### Implemented code looks intentional

The active modules (`trace`, `counter`, `hooks`, `caps`, `zone`) all fit the package.

### The placeholder modules are the closest thing to dead weight

They are not dead in the sense of being forgotten. They are still misplaced as public API because they are design placeholders, not functioning library features.

### No obvious package split is needed yet

The implemented package core is cohesive enough to stay together.

If binary export eventually becomes substantial, it may justify a clearer sub-layer, but not a separate package yet.

## Example Coverage

Example coverage is decent for the implemented core:

- one basic zone-trace example;
- one mixed zone/counter example;
- one hook-emission example.

That is better than several previously reviewed packages.

Current gaps:

- no example showing `Trace` alias behavior under tracing-enabled versus disabled builds;
- no example of bounded-buffer overflow handling with `NoSpaceLeft`;
- no example clarifying that thread-local and binary export features are not implemented.

Recommendation:

- keep the current examples;
- add one explicit bounded-overflow example if this package becomes externally adopted.

## Test Coverage

Coverage is strong for the implemented core.

Strengths:

- deterministic JSON export tests;
- buffer-boundary and `NoSpaceLeft` coverage;
- mixed counter/zone event coverage;
- hook callback behavior tests;
- and one deterministic stress/property-style test for export stability.

Gaps:

- no integration test for a real downstream package using `hooks.zig`;
- no build-configuration test that proves the `Trace` alias flips correctly under both tracing settings;
- no tests for deferred modules, which is expected but also reinforces that they are not real features.

Recommendation:

- the next highest-value test is one behavior test proving a downstream subsystem can emit through `hooks.zig` into a real trace.

## Adherence to `agents.md`

Overall assessment:

- implemented code is explicit and bounded;
- allocation is front-loaded to initialization;
- comments usually explain rationale, not just mechanics;
- and the assertion density is high.

This package follows the repo rules well in its implemented core.

The main adherence issue is package-surface discipline:

- deferred placeholders and dormant dependencies violate the repo's preference for clear, minimal, production-ready structure.

## Refactor Paths

### Path 1: Reduce the package to its implemented core

Make the public package surface match what is actually real today:

- `trace`
- `counter`
- `hooks`
- `caps`
- `zone`

That would immediately improve clarity.

### Path 2: Remove dormant dependencies until promoted

If binary export remains deferred, remove `static_serial` from active package dependencies and from `root.zig`.

### Path 3: Replace dead doc links with live references

Point deferred rationale to existing completed plans, or keep the rationale fully inline.

Dead references should not remain in code comments.

### Path 4: Let real consumers drive expansion

Do not add thread-local or binary-trace implementation because the idea is interesting.

Promote those paths only when:

- a concrete blueprint requires them;
- and one or more packages actually need the functionality.

## Bottom Line

`static_profile` has a solid implemented core, but its public surface is ahead of its real maturity.

The strongest recommendation is to tighten the package around the implemented trace/counter/hooks core by:

1. removing or hiding public placeholder modules;
2. dropping the dormant `static_serial` dependency unless binary trace is promoted;
3. fixing stale documentation references; and
4. waiting for real package consumers before expanding the API further.
