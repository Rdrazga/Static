# Sketch: `static_net` Package Review

Date: 2026-03-06 (America/Denver)  
Status: First review pass completed.

## Scope

Review `packages/static_net/` for:

- adherence to `agents.md`;
- overlap with Zig standard library facilities and whether the package adds enough value;
- correctness and completeness at file and package scope;
- duplicate, dead, or misplaced code;
- example and test coverage; and
- practical refactor paths.

## Package Inventory

- Source files: 6 modules plus `root.zig` (7 total).
- Examples: 2 (`address_parse_format_basic`, `frame_codec_incremental_basic`).
- Benchmarks: 1 (`frame_encode_decode_throughput`).
- Inline unit/behavior tests: 28 plus root wiring coverage.
- Validation in this pass:
  - `zig build examples` passed.
  - `zig build test` remains blocked by the unrelated `static_queues` stress-test failure at `packages/static_queues/src/testing/lock_free_stress.zig:105`.

Observed workspace usage in this pass:

- `Endpoint` is used by `static_io` and re-exported by `static_net_native`.
- `static_net_native` also depends on the address/endpoint value layer.
- No external usage was found in this pass for the frame codec modules.

## Package-Level Assessment

`static_net` is cohesive and reasonably well-scoped.

It currently has two clear halves:

- OS-free networking value types (`address`, `endpoint`, `errors`);
- a bounded frame codec layer (`frame_config`, `frame_encode`, `frame_decode`).

Those two halves are related enough to live together because they both provide transport-adjacent, syscall-free building blocks for higher layers.

The package's strongest properties are:

- deterministic formatting rules;
- strict parsing behavior;
- bounded incremental decoding;
- and explicit error vocabularies.

The main concerns are not implementation quality. The main concerns are:

- overlap with std in address parsing/formatting;
- the fact that only the value-type half is currently adopted by other packages;
- and making sure the frame codec remains clearly justified rather than becoming a speculative protocol layer.

## What Fits Well

### The value-type layer is clearly justified

`Address` and `Endpoint` are already useful across the workspace.

They give higher layers:

- OS-free endpoint values;
- deterministic string formatting;
- explicit parse/format errors;
- stable opt-in type identity declarations.

This is good package-core material.

### The frame codec is bounded and disciplined

The codec layer does the right things for this repo:

- caller-provided output buffers;
- explicit maximum payload bounds;
- incremental decode with deterministic state;
- no heap allocation;
- deterministic checksum behavior when enabled.

That is a strong fit for the repo's design goals.

### The package boundary with `static_net_native` is sound

`static_net` owns the portable value types.

`static_net_native` can then own OS/socket translation without re-solving endpoint semantics. That split is clean.

## STD Overlap Review

### `address.zig` and `endpoint.zig` overlap std the most

Closest std overlap:

- `std.net.Address`
- platform socket-address formatting/parsing helpers

Assessment:

- these modules do overlap standard networking concepts heavily;
- but their value is not just parsing itself;
- their value is deterministic package-local semantics:
  - full lowercase IPv6 expansion;
  - no scope ID support;
  - explicit literal formats;
  - OS-free value types reusable by other packages.

Recommendation:

- keep them as long as the project wants stricter, deterministic semantics than std's more general-purpose networking layer.

### The frame codec has little std overlap

Closest overlap:

- raw byte serialization helpers in `static_serial`

Assessment:

- std does not provide this bounded protocol framing layer.
- the codec is justified if the workspace wants one canonical small-frame transport envelope.

Recommendation:

- keep it, but keep it protocol-specific and small.

### There is some overlap pressure with `static_serial`

The frame codec is built on `static_serial`, which is the correct dependency direction.

Still, it means `static_net` must be careful not to accumulate generic serialization features that really belong lower in `static_serial`.

Recommendation:

- keep `static_net` focused on transport framing semantics, not generic binary encoding helpers.

## Correctness and Completeness Findings

## Finding 1: The address/endpoint half is adopted; the frame codec half is not yet

Observed external usage is concentrated in:

- `Endpoint`
- the address/endpoint value layer transitively used by `static_io` and `static_net_native`

I did not find external consumers for:

- `frame_config`
- `frame_encode`
- `frame_decode`

That does not make the codec wrong. It means the package currently has one mature, adopted half and one still-proving-itself half.

Recommendation:

- keep the codec small and disciplined until real consumers appear;
- avoid turning it into a broader protocol toolkit prematurely.

## Finding 2: Deterministic IPv6 formatting is a valid divergence, but it should stay explicit in docs/examples

`address.zig` deliberately formats IPv6 using full 8-hextet lowercase expansion rather than compression heuristics.

That is a good deterministic choice, but it is a real semantic decision:

- it differs from many human-facing networking tools;
- it is more stable for tests and round-trips;
- and it trades readability for determinism.

Recommendation:

- keep this behavior;
- make sure examples and docs continue to present it as intentional rather than incidental.

## Finding 3: The package is small and looks correct, but there is little consumer pressure yet on the frame protocol contract

The frame codec tests are strong:

- zero-length and max-length payloads;
- checksum mismatch handling;
- chunk-boundary determinism;
- malformed corpus bounds behavior.

What is still missing is evidence that other packages actually want this exact envelope shape and policy.

Recommendation:

- do not broaden the protocol surface until a second package depends on it;
- if adoption appears, add one integration-style consumer test rather than many more codec-local tests.

## Finding 4: `Endpoint` currently encodes only literal IP endpoints, which is the correct narrow scope

This package does not try to own:

- DNS names;
- service names;
- socket options;
- URI parsing.

That is good. It keeps `static_net` from becoming a grab bag of everything adjacent to networking.

Recommendation:

- preserve this narrow scope.
- if name resolution or richer endpoint forms are needed later, consider a separate layer rather than inflating `Endpoint`.

## Duplicate / Dead / Misplaced Code Review

### No obvious dead code

The package is small enough that everything appears intentional and connected.

### Minimal duplication

There is some expected structural mirroring between:

- IPv4 and IPv6 address parsing/formatting;
- IPv4 and IPv6 endpoint parsing/formatting.

That duplication is acceptable because the code paths are protocol-specific and easier to audit when explicit.

### The package boundary is correct

No obvious module in this pass looked misplaced.

- value types belong here;
- portable frame codec logic belongs here;
- OS/socket interop belongs elsewhere and already appears to be in `static_net_native`.

## Example Coverage

Current examples cover:

- address parse/format basics;
- incremental frame decode basics.

That is decent but still light.

Missing example coverage:

- endpoint parse/format;
- checksum-enabled frame encoding/decoding;
- malformed/truncated stream handling;
- deterministic IPv6 formatting policy.

Recommendation:

- add at least one endpoint example and one checksum-enabled frame codec example.

## Test Coverage

Coverage is strong for a package this size.

Strengths:

- address and endpoint parsers have both positive and negative tests;
- frame codec tests cover boundary sizes, malformed headers, checksum failures, and chunked decoding;
- the malformed-corpus test is especially valuable because it validates bounds behavior rather than only happy-path output.

Gaps:

- no consumer-side integration test for the frame codec because no consumer exists yet;
- examples are shallower than the test surface;
- no explicit cross-package test showing `Endpoint` interoperability with `static_net_native` or `static_io`.

Recommendation:

- keep the current inline tests;
- add one cross-package endpoint interoperability test once that coupling becomes more central.

## Adherence to `agents.md`

Overall assessment:

- the package is explicit and bounded;
- control flow is simple;
- allocation-free operation is maintained;
- comments explain the important conventions and tradeoffs;
- error handling uses explicit sets appropriately.

This package matches the repo rules well.

The only real watch item is keeping the frame codec layer from growing beyond its currently justified scope.

## Refactor Paths

### Path 1: Keep the value-type layer as the stable core

The most clearly justified stable core is:

- `Address`
- `Endpoint`
- parse/format error sets

These already have workspace value.

### Path 2: Let real consumers decide the future shape of the frame codec

The codec is good, but not yet externally adopted.

Before adding more protocol features:

- wait for at least one real consumer;
- then extend based on concrete transport needs.

### Path 3: Add examples that reinforce deterministic literal policy

Highest-value additions:

- endpoint parse/format example;
- checksum-enabled frame codec example;
- one example that makes canonical IPv6 formatting explicit.

### Path 4: Keep std overlap disciplined

Avoid letting `static_net` become a second general-purpose networking library.

If future features drift toward:

- name resolution;
- sockets;
- URI parsing;
- connection management,

they should probably live elsewhere.

## Bottom Line

`static_net` is a solid package. The address/endpoint layer is already justified by workspace use, and the frame codec layer is technically strong though not yet externally adopted.

The main recommendations are:

1. keep the package narrowly portable and deterministic;
2. treat `Address` / `Endpoint` as the stable adopted core;
3. keep the frame codec small until real consumers appear; and
4. add examples that better communicate deterministic endpoint and frame semantics.
