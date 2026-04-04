# Sketch: `static_net_native` Package Review

Date: 2026-03-06 (America/Denver)  
Status: First review pass completed.

## Scope

Review `packages/static_net_native/` for:

- adherence to `agents.md`;
- overlap with Zig standard library facilities and whether the package adds enough value;
- correctness and completeness at file and package scope;
- duplicate, dead, or misplaced code;
- example and test coverage; and
- practical refactor paths.

## Package Inventory

- Source files: 4 modules plus `root.zig` (5 total).
- Examples: none.
- Benchmarks: none.
- Inline unit/behavior tests: 8 plus root wiring coverage.
- Standalone package metadata: missing `build.zig` and `build.zig.zon`.
- Validation in this pass:
  - `zig build examples` passed.
  - `zig build docs-lint` passed.
  - `zig build test` remains blocked by the unrelated `static_queues` stress-test failure at `packages/static_queues/src/testing/lock_free_stress.zig:105`.

Observed workspace usage in this pass:

- `static_io` is the only current package consumer.
- `static_io` uses the package heavily across runtime, threaded, BSD, Linux, and Windows backend code.
- No examples, benchmarks, or integration tests currently exercise the package directly.

## Package-Level Assessment

`static_net_native` is a small, cohesive adapter layer.

Its job is narrow and clear:

- keep `static_net` free of OS-native socket structs;
- translate portable `Endpoint` values into native sockaddr layouts;
- and convert native sockaddr storage back into portable endpoint values.

That boundary is correct. It keeps networking value semantics in `static_net` and syscall-facing ABI details here.

The package's strongest property is that it is already justified by real workspace use. `static_io` depends on it in multiple backends, so this is not speculative abstraction.

The main concerns are package maturity rather than algorithmic correctness:

- the package is the only workspace package without standalone build metadata;
- there are no examples showing the intended usage surface;
- and the POSIX/Linux split duplicates a lot of structure that could drift over time.

## What Fits Well

### The package boundary is well chosen

This package does not try to own:

- endpoint parsing;
- socket lifecycle management;
- or general networking APIs.

It only owns native layout translation. That is the right scope.

### The shared helper split is sensible

`common.zig` centralizes the byte-order and IPv4/IPv6 reconstruction rules, while the platform files own the ABI-specific struct layouts. That is a good separation.

### Real adoption already exists

Unlike some other reviewed packages, this one already has meaningful consumer pressure. `static_io` relies on it for:

- endpoint-to-sockaddr conversion before syscalls;
- storage-to-endpoint conversion after syscalls;
- and platform-specific socket inspection helpers.

That gives the package a clear reason to exist.

## STD Overlap Review

### Overlap exists, but it is mostly unavoidable

Closest std overlap:

- `std.posix` socket-address types and syscall shims;
- `std.os.linux` native sockaddr definitions;
- `std.os.windows.ws2_32` sockaddr definitions and socket APIs.

Assessment:

- the package is intentionally thin over those std facilities;
- but the value is not the raw wrappers themselves;
- the value is centralizing one portable translation policy between `static_net.Endpoint` and OS-native ABI layouts.

Recommendation:

- keep the package narrow;
- resist adding more wrappers unless they clearly reduce duplicated backend logic in `static_io`;
- and keep generic byte-order helpers in `common.zig`, not spread across backends.

## Correctness and Completeness Findings

## Finding 1: The package is justified by real backend use

`static_io` uses this package across:

- generic runtime code;
- threaded backend code;
- BSD kqueue code;
- Linux io_uring code;
- Windows IOCP code.

That is enough adoption to justify the package boundary.

Recommendation:

- keep `static_net_native` as the single workspace authority for sockaddr translation.

## Finding 2: Standalone package completeness is below the workspace standard

Every other package reviewed so far includes `build.zig` and `build.zig.zon`.

`static_net_native` currently does not.

That matters because it means:

- the package cannot be consumed or validated in the same standalone way as sibling packages;
- package-local examples or tests cannot be documented the same way;
- and the workspace package set is inconsistent.

Recommendation:

- add `packages/static_net_native/build.zig` and `packages/static_net_native/build.zig.zon`;
- mirror the dependency contract already expressed in the root workspace `build.zig`.

This is the highest-value concrete package-level fix from this pass.

## Finding 3: POSIX and Linux adapters duplicate a lot of logic

`posix.zig` and `linux.zig` have nearly identical shape:

- same `SockaddrAny` union pattern;
- same IPv4 and IPv6 conversion paths;
- same pointer and length helpers;
- same storage-to-endpoint reconstruction logic;
- same round-trip test shape.

Some duplication is justified because the native type namespaces differ.

Still, this is a drift risk because behavior can diverge accidentally. One visible asymmetry already exists:

- POSIX exposes `socketPeerEndpoint`;
- Linux does not.

That may be intentional for current backend needs, but the difference is not documented at the package surface.

Recommendation:

- either document why Linux intentionally exposes less helper surface;
- or align the helper surface where practical.

Do not force an abstraction that hides ABI differences, but do not let near-identical files drift silently either.

## Finding 4: The current tests prove layout round-trips, but not much behavior beyond that

The existing tests are useful:

- IPv4 round trips through each storage format;
- IPv6 round trips through each storage format;
- shared byte-order helpers round trip correctly.

What they do not cover:

- unsupported-family handling in `endpointFromStorage`;
- `anyForFamily` negative-space behavior on Windows;
- syscall-backed helpers such as `socketLocalEndpoint`, `socketPeerEndpoint`, and `socketFamily`;
- package-level examples showing intended usage from a caller's perspective.

Recommendation:

- add a small set of negative-space tests for unknown families and Windows helper contracts;
- add one behavior example that shows converting an `Endpoint` to a native sockaddr for bind/connect-style calls.

## Duplicate / Dead / Misplaced Code Review

### No obvious dead code

Everything present is small and connected to a current consumer.

### Some duplication is justified, but should stay watched

The current duplication is mostly structural and tied to native ABI type differences. That is acceptable today because the code remains easy to audit.

The watch item is not duplication alone. The watch item is undocumented divergence between near-identical adapters.

### Package placement is correct

These modules belong in their own package rather than `static_net` because they depend on OS-native ABI definitions.

That split should remain.

## Example Coverage

There are currently no examples.

That is the weakest part of the package.

Highest-value additions:

- endpoint-to-sockaddr conversion example;
- sockaddr-storage-to-endpoint round-trip example;
- one example that explains why callers should use `static_net.Endpoint` until the syscall boundary.

## Test Coverage

Coverage is decent for a tiny adapter package, but still narrow.

Strengths:

- all platform modules have positive round-trip tests;
- the shared helper module has direct IPv4 and IPv6 byte-layout tests;
- tests are deterministic and allocation-free.

Gaps:

- little negative-space testing;
- no behavior tests for syscall helper wrappers;
- no cross-package consumer test that explicitly proves `static_io` and `static_net_native` agree on endpoint translation.

Recommendation:

- keep the current round-trip tests;
- add a few targeted negative tests rather than a large test expansion;
- add one integration-style translation test if the package gains a second consumer or more public usage.

## Adherence to `agents.md`

Overall assessment:

- control flow is simple and explicit;
- the code stays allocation-free;
- platform boundaries are clean;
- comments explain the why at the module and API level;
- and the package remains bounded in scope.

This package aligns well with the repo rules.

The main deviation from the wider workspace standard is packaging completeness, not code style or safety discipline.

## Refactor Paths

### Path 1: Bring package metadata up to workspace standard

Add standalone `build.zig` and `build.zig.zon` files so the package can be consumed and validated consistently with sibling packages.

### Path 2: Keep the public API as small as real consumers require

The package is useful because it centralizes endpoint/native translation, not because it provides a large socket utility layer.

Before adding more helpers:

- confirm `static_io` actually needs them in more than one place;
- otherwise keep the wrapper close to the caller.

### Path 3: Clarify platform-surface asymmetry

Decide whether `linux.zig` intentionally omits `socketPeerEndpoint` or whether the helper surface should be aligned with `posix.zig` and `windows.zig`.

Either answer is acceptable, but it should be explicit.

### Path 4: Add one or two examples instead of expanding abstractions

The package does not need more genericity right now. It needs clearer usage proof.

Examples would provide that with much less risk than refactoring the adapter layer.

## Bottom Line

`static_net_native` is a good, justified adapter package.

Its core purpose is correct, its consumer is real, and the code is small enough to audit confidently.

The highest-value recommendations are:

1. add standalone package metadata;
2. add one or two examples and a few negative-space tests;
3. keep the API thin and tied to concrete `static_io` needs; and
4. document or reconcile the small POSIX/Linux surface asymmetry before it drifts further.
