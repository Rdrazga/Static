# Sketch: `static_io` Package Review

Date: 2026-03-06 (America/Denver)  
Status: First review pass completed.

## Scope

Review `packages/static_io/` for:

- adherence to `agents.md`;
- overlap with Zig standard library facilities and whether the package adds enough value;
- correctness and completeness at file and package scope;
- duplicate, dead, or misplaced code;
- example and test coverage; and
- practical refactor paths.

## Package Inventory

- Source files: 18 implementation modules plus `root.zig` (19 total).
- Examples: 2 (`buffer_pool_exhaustion`, `fake_backend_roundtrip`).
- Benchmarks: 2 (`buffer_pool_checkout_return`, `runtime_submit_complete_roundtrip`).
- Inline unit/behavior tests: 83 plus root wiring coverage.
- Validation in this pass:
  - `zig build examples` passed.
  - `zig build test` remains blocked by the unrelated `static_queues` stress-test failure at `packages/static_queues/src/testing/lock_free_stress.zig:105`.

Observed workspace usage in this pass:

- No external package usage was found under `packages/`.
- Current usage appears limited to `static_io`'s own examples and benchmarks.

## Package-Level Assessment

`static_io` is one of the more ambitious packages in the workspace. It is also one of the more technically coherent ones.

The strongest parts are:

- the bounded runtime facade in `runtime.zig`;
- the fake backend as a deterministic parity baseline in `fake_backend.zig`;
- the stable error/status vocabulary in `types.zig` and `error_map.zig`; and
- the explicit backend split between fake, threaded, and OS-native implementations.

This package does real work that Zig std does not package for you as one bounded, cross-backend abstraction. The main concerns are not basic implementation quality. The main concerns are package completeness, public-surface discipline, and how much API the workspace actually needs right now.

There is also one valid divergence from the local style rules: several orchestration files are large and some functions exceed the preferred size limit. In this package that is defensible because the control flow is intentionally centralized around explicit state machines, backend transitions, and cleanup rules. The complexity is real and mostly exposed rather than hidden.

## What Fits Well

### The fake backend is the package anchor

`fake_backend.zig` is a good design choice.

It gives the package:

- deterministic parity tests;
- a bounded in-memory execution model;
- a way to validate runtime semantics without requiring host-kernel behavior; and
- a clear baseline for completion ordering, timeout semantics, and handle lifecycle.

This is exactly the kind of scaffolding a package like `static_io` should own.

### The runtime API is materially more valuable than raw backend access

`runtime.zig` is where the package becomes useful rather than merely intricate.

The runtime centralizes:

- handle generation protection;
- typed operation helpers;
- cancellation and close behavior;
- backend capability selection; and
- stable completion cleanup rules.

That is a real abstraction layer, not a thin wrapper over std.

### The error/status normalization is justified

`error_map.zig` and the stable completion vocabulary in `types.zig` are good package-local policy.

They provide:

- backend-independent completion tags;
- control-plane error normalization; and
- a stable vocabulary for upper layers.

That belongs here.

## STD Overlap Review

### Low direct std overlap in the core runtime

Closest std overlap:

- raw file and socket APIs in `std.fs`, `std.posix`, and `std.os.windows`;
- threading primitives;
- `std.os.linux.IoUring`.

Assessment:

- std gives the package building blocks, not the bounded multi-backend runtime this package is trying to expose.
- The runtime, completion vocabulary, and deterministic fake backend are all package-specific value.

Recommendation:

- Keep the runtime and backend policy layer. That is the justified core of the package.

### `buffer_pool.zig` overlaps lower-level pools, but adds enough policy

Closest overlap:

- `static_memory.pool.Pool`;
- std pool-style allocation patterns.

Assessment:

- `BufferPool` is still justified because it adds `types.Buffer` integration, optional budget reservation, and byte/block reporting tailored to I/O buffers.
- This is a wrapper, but it is a useful one.

Recommendation:

- Keep `BufferPool`, but keep it narrow and avoid turning it into a second generic pool API.

### Several helper/wrapper modules are thin and mainly organizational

The thinnest modules are:

- `caps.zig`;
- `platform/selected_backend.zig`;
- `platform/windows_backend.zig`;
- parts of `platform/posix_backend.zig`.

Assessment:

- These are mostly organization and dispatch layers, not independent abstractions.
- That is acceptable internally, but it is weaker justification for public export.

Recommendation:

- Treat these as implementation structure first, public package surface second.

## Correctness and Completeness Findings

## Finding 1: The package build metadata is not self-consistent

`packages/static_io/build.zig.zon` declares only:

- `static_core`
- `static_memory`
- `static_queues`

But the actual source/build graph also depends on:

- `static_collections`
- `static_net`
- `static_sync`
- `static_net_native`

Also, `packages/static_io/build.zig` wires `static_collections`, `static_net`, and `static_sync`, but it does not wire `static_net_native` even though `src/root.zig`, `runtime.zig`, `threaded_backend.zig`, and the OS backends import it directly.

This is not a runtime bug in the current workspace flow, but it is a real package-completeness problem. The package metadata does not accurately describe what the package needs.

Recommendation:

- Make `build.zig`, `build.zig.zon`, and `src/root.zig` agree on the dependency set.
- If `static_io` is not intended to be consumable as a standalone workspace dependency, document that more explicitly and still keep manifests internally correct.

## Finding 2: The public surface is broader than current usage justifies

`src/root.zig` publicly exports:

- `backend`
- `fake_backend`
- `threaded_backend`
- `platform`
- `caps`

No external package usage was found for any of these in this pass. The only demonstrated ergonomic surface is:

- `Runtime`
- `RuntimeConfig`
- `BufferPool`
- the shared value types

This makes the package look more settled than it is. Exporting backend internals now increases API commitment and maintenance burden without evidence that consumers need those entry points.

Recommendation:

- Reassess which modules are intended to be stable public API.
- Prefer a smaller public surface centered on `Runtime`, `Config`, `BufferPool`, and value types unless low-level backend access is a deliberate product goal.

## Finding 3: The selector/wrapper stack adds maintenance cost for modest value

The platform layering currently includes:

- `platform/selected_backend.zig`
- `platform/posix_backend.zig`
- `platform/windows_backend.zig`

The Windows selector is especially thin: it mainly forwards to `windows/iocp_backend.zig`. The POSIX selector is more justified because it actually chooses between Linux and BSD backends, but it still duplicates a large forwarding surface.

This is not dead code, but it is wrapper-heavy.

Recommendation:

- Keep the layering while there are only a few backends if it improves readability.
- If more backend variants are added, either collapse some selectors or move to a more obviously shared forwarding pattern so the wrapper stack does not grow linearly.

## Finding 4: The package is technically strong but still unproven at workspace scope

No external package usage was found in this pass.

That means:

- the package may still be overexposing internals before consumers are known;
- some API choices have not been pressure-tested by other libraries; and
- the current package shape is still more of a platform foundation than a proven shared dependency.

This is not a criticism of code quality. It is a maturity/readiness observation.

Recommendation:

- Prioritize narrowing and polishing the public runtime-facing API before expanding the backend-facing one.
- Let real consumers drive which low-level pieces remain public.

## Duplicate / Dead / Misplaced Code Review

### No obvious dead implementation modules

Within the package itself, the modules appear to be live and connected. This is not a package full of speculative files with no internal callers.

### The main duplication risk is backend state-machine repetition

The package repeats similar categories of logic across:

- `fake_backend.zig`
- `threaded_backend.zig`
- `platform/linux/io_uring_backend.zig`
- `platform/bsd/kqueue_backend.zig`
- `platform/windows/iocp_backend.zig`

This includes recurring concerns such as:

- slot allocation/generation;
- completion queueing;
- cancellation and close behavior;
- handle registration and handle-in-use checks.

Some duplication is inevitable because the OS mechanics differ. Still, this is the main long-term maintenance hotspot in the package.

Recommendation:

- Do not force abstraction immediately.
- If backend count or feature count increases, consider extracting shared internal helpers for slot bookkeeping, completion formation, or handle lifecycle checks.

### The package boundary itself is correct

There was no obvious module in this pass that should live in a different package. The low-level backend code, runtime facade, error normalization, and I/O buffer pool do belong together.

## Example Coverage

Current examples cover:

- `BufferPool` exhaustion behavior;
- fake-backend `fill` roundtrip via `Runtime`.

This is too shallow for a package of this size.

Missing example coverage for important public behavior includes:

- `wait` with timeout and cancellation;
- `submitStreamRead` / `submitStreamWrite`;
- `submitConnect` / `submitAccept`;
- `openFile` / `listen`;
- adopted native handles;
- backend selection and capability reporting.

Recommendation:

- Add at least three more examples:
  - a runtime wait/cancel example;
  - a stream connect/read/write example;
  - an adopted-file read/write example for host backends.

## Test Coverage

Coverage is strong in breadth and much better than a typical early-stage systems package.

Strengths:

- `fake_backend`, `runtime`, `threaded_backend`, and host backends all have behavior-oriented tests.
- Timeout, cancellation, exhaustion, close, wrong-kind, stale-handle, and error-mapping paths are exercised.
- The tests are not limited to trivial unit checks; many are meaningful scenario tests.

Gaps:

- There are no separate `tests/integration/` cases even though this package is a good candidate for a small number of end-to-end runtime tests.
- Example coverage is much weaker than test coverage.
- Package-consumption completeness is not tested; the manifest/build inconsistency above was found by inspection, not by a package-level consumption test.

Recommendation:

- Keep the inline behavior tests.
- Add one or two workspace-level integration tests that exercise the public runtime API rather than backend internals.
- Add one package-consumption sanity check once the manifest/build dependency story is corrected.

## Adherence to `agents.md`

Overall assessment:

- boundedness is taken seriously;
- hot-path allocation appears to be avoided after initialization;
- control flow is explicit rather than clever;
- comments generally explain intent well;
- error vocabularies are explicit and normalized.

Valid divergences:

- large orchestration files and some long functions in backend/runtime code;
- dynamic allocation during initialization.

These divergences are acceptable here because:

- runtime/backend setup is naturally stateful and boundary-heavy;
- the package still keeps allocation out of the steady-state path; and
- most complexity is paid in explicit control flow rather than hidden indirection.

## Refactor Paths

### Path 1: Shrink the stable public API

Most likely public API:

- `Runtime`
- `RuntimeConfig`
- `BufferPool`
- `Buffer`, `Operation`, `Completion`, and typed handles

Possible internal-only or advanced API candidates:

- `caps`
- `backend`
- `fake_backend`
- `threaded_backend`
- `platform`

This would reduce surface area without weakening the package core.

### Path 2: Fix package-consumption completeness first

Before expanding features further:

- align `build.zig.zon` with real dependencies;
- wire `static_net_native` consistently where needed;
- verify the package can be consumed through its declared metadata.

This is the clearest completeness issue in the current package.

### Path 3: Add examples that mirror the intended adoption path

The examples should show how consumers are supposed to use the package:

- fake backend for deterministic tests;
- runtime helper methods for typed operations;
- wait/cancel behavior;
- host-backend file or socket adoption when enabled.

Right now the examples underrepresent the package.

### Path 4: Revisit wrapper layering only if the backend matrix grows

Do not refactor the selectors just for aesthetics.

If more backends or more forwarded methods are added, then:

- collapse thin wrappers;
- extract common forwarding helpers; or
- more clearly separate host selection from capability adapters.

For now this is a watch item, not a required rewrite.

## Bottom Line

`static_io` is a serious package with real technical value. Its main risks are not algorithmic weakness or lack of testing. Its main risks are:

- an over-broad public surface relative to current adoption;
- wrapper layering that can become expensive if the package grows further; and
- a concrete build/manifest completeness problem that should be fixed before treating the package as externally consumable.

The strongest near-term recommendations are:

1. fix the package dependency/build metadata so the package description matches reality;
2. narrow or clearly classify the public API surface;
3. add examples for the actual runtime adoption path; and
4. keep using the fake backend as the semantic reference point for the rest of the package.
