# Sketch: `static_serial` Package Review

Date: 2026-03-06 (America/Denver)  
Status: First review pass completed.

## Scope

Review `packages/static_serial/` for:

- adherence to `agents.md`;
- overlap with Zig standard library facilities and whether the package adds enough value;
- correctness and completeness at file and package scope;
- duplicate, dead, or misplaced code;
- example and test coverage; and
- practical refactor paths.

## Package Inventory

- Source files: 7 modules plus `root.zig` (8 total).
- Examples: 4 (`varint_roundtrip`, `reader_writer_endian`, `checksum_frame`, `parse_length_prefixed_frame`).
- Benchmarks: none.
- Inline unit/behavior tests: 23 plus root wiring coverage.
- Standalone package metadata: present (`build.zig`, `build.zig.zon`).
- Validation in this pass:
  - `zig build examples` passed.
  - `zig build docs-lint` passed.
  - `zig build test` remains blocked by the flaky `static_queues` lock-free stress failure at `packages/static_queues/src/testing/lock_free_stress.zig:105`.

Observed workspace usage in this pass:

- `static_net` is the main real consumer and uses `writer`, `varint`, and `checksum`.
- `static_profile` re-exports `static_serial` from its root, but I found no implemented `static_profile` source using it yet.
- the package root also re-exports `static_core`, `static_bits`, and `static_hash`.

## Package-Level Assessment

`static_serial` is cohesive and already justified by downstream use.

Its strongest value is not basic byte IO alone. Its strongest value is the combination of:

- bounded cursor-based serialization;
- atomic rollback semantics on failure;
- canonical varint policy;
- zigzag support;
- and checksum framing built for small protocol layers.

That makes it a real package rather than a loose set of helpers.

The main concerns are boundary discipline, not core correctness:

- there is visible overlap with `static_bits`, especially around varints and cursor/endian access;
- root re-exports broaden the surface more than current usage seems to require;
- and some panics represent internal-invariant assumptions that should stay very deliberate.

## What Fits Well

### The package has real downstream value

`static_net` already consumes this package for frame encoding and decoding. That is strong evidence the package boundary is useful.

### Atomic cursor semantics are a strong differentiator

The rollback-on-failure behavior in `reader`, `writer`, and `varint` is a real implementation value and fits the repo's safety goals well.

### The package layers are coherent

The current stack is sensible:

- `errors`
- `reader` / `writer`
- `varint` / `zigzag`
- `checksum`
- `view`

That is a clean serialization package shape.

## STD Overlap Review

### There is some std overlap, but the package adds clear policy

Closest overlap:

- `std.mem.readInt` / `writeInt`;
- basic byte-slice parsing;
- ad hoc varint and checksum code a caller could write directly.

Assessment:

- std provides primitives;
- `static_serial` provides package-local contracts and composition:
  - canonical encodings;
  - rollback semantics;
  - bounded cursor behavior;
  - common error taxonomy.

That is enough to justify the package.

### The bigger overlap pressure is inside the repo with `static_bits`

This is the main boundary question.

`static_bits` already contains:

- endian helpers;
- cursor types;
- a separate LEB128/varint implementation.

`static_serial` then builds:

- its own `reader` / `writer` on top of `static_bits.cursor`;
- its own varint layer with a different API and error vocabulary.

Recommendation:

- make `static_serial` the structured wire-format layer and keep `static_bits` as the lower-level primitive layer;
- avoid letting both packages grow independent serialization stories.

## Correctness and Completeness Findings

## Finding 1: The package is already justified by `static_net`

This package is not speculative. `static_net` uses it for frame encode/decode work, which is exactly the kind of downstream reuse that justifies the package.

Recommendation:

- treat the current `reader` / `writer` / `varint` / `checksum` path as the stable adopted core.

## Finding 2: The `static_bits` / `static_serial` boundary needs to stay explicit

The package currently depends on `static_bits` for:

- endian type aliases;
- byte cursors;
- integer casts.

It also duplicates some semantic territory through its own varint implementation while `static_bits` has its own LEB128 implementation.

This is not necessarily wrong, because the layers are different:

- `static_bits` provides lower-level primitives and broader bit/cursor tools;
- `static_serial` provides a wire-format-oriented public surface and error vocabulary.

But the distinction must stay sharp or the repo will keep two overlapping serialization centers.

Recommendation:

- avoid adding new generic endian/cursor helpers here;
- keep `static_serial` focused on structured protocol serialization behavior.

## Finding 3: Root re-exports broaden the surface more than current usage proves

`src/root.zig` re-exports:

- `static_core`
- `static_bits`
- `static_hash`

Those are dependencies, but they are not the real package identity.

Current downstream use appears to target actual serial modules, not those dependency re-exports.

Recommendation:

- consider removing dependency re-exports from the root unless there is a deliberate package-composition reason to expose them.

This would make the package boundary cleaner.

## Finding 4: `reader` and `writer` rely on panic paths for impossible internal error translations

Examples:

- `reader.readVarint` panics if `varint.readVarint` reports `NoSpaceLeft`;
- `writer.writeVarint` panics if `varint.writeVarint` reports `EndOfStream`.

These are reasonable if the contract is:

- the cursor kinds are correct by construction;
- cross-domain error variants indicate an internal bug, not an operating condition.

That is defensible, but these are important internal assumptions.

Recommendation:

- keep the panic paths if they remain truly impossible by construction;
- avoid adding new ones without the same level of proof.

## Duplicate / Dead / Misplaced Code Review

### No obvious dead code

Everything present appears intentional and connected to a real serialization story.

### The main duplication is conceptual, not literal

The duplication pressure is mainly:

- `static_bits.varint` versus `static_serial.varint`;
- `static_bits.endian` / `cursor` primitives versus `static_serial.reader` / `writer`.

That is acceptable as long as the layering stays explicit.

### `view.zig` is the least proven module

`view.zig` is harmless and small, but it is also the least obviously essential part of the package compared with the reader/writer/varint/checksum core.

That is not a removal recommendation. It is just the weakest-justified edge surface today.

## Example Coverage

Example coverage is good.

Strengths:

- roundtrip varint example;
- reader/writer endian example;
- checksum framing example;
- length-prefixed frame parsing example.

That gives better breadth than many other packages in this review sequence.

Remaining gap:

- no example for zigzag signed-value handling;
- no example explicitly showing failure rollback semantics.

Recommendation:

- add one signed zigzag example only if a consumer starts relying on that path more heavily.

## Test Coverage

Coverage is strong for the package size.

Strengths:

- end-to-end serial roundtrip test;
- canonical varint validation;
- rollback and buffer-bleed tests;
- zigzag boundary checks;
- checksum positive and negative cases.

Gaps:

- no external integration test beyond the fact that `static_net` uses the package;
- no behavior test directly tying `static_net` framing invariants to `static_serial` expectations.

Recommendation:

- keep the current tests;
- if a new consumer appears, add one cross-package behavior test instead of many more package-local unit tests.

## Adherence to `agents.md`

Overall assessment:

- control flow is explicit;
- bounds are checked consistently;
- rollback semantics encode safety expectations clearly;
- and comments explain the rationale behind canonical encoding and buffer-bleed protection.

This package aligns well with the repo rules.

The main watch item is package-boundary discipline with `static_bits`, not implementation quality.

## Refactor Paths

### Path 1: Keep `static_serial` as the structured wire-format layer

Let `static_bits` own:

- primitive cursor and bit/endian tools;

and let `static_serial` own:

- structured reader/writer behavior;
- canonical varint policy;
- checksum framing;
- shared serial error vocabulary.

### Path 2: Trim root re-exports if they are not intentional API

If consumers do not need `static_serial.core`, `static_serial.bits`, or `static_serial.hash`, remove them from `src/root.zig`.

### Path 3: Keep `view` small unless it proves itself

Do not expand `view.zig` into a larger byte-slice abstraction unless a real consumer needs it.

## Bottom Line

`static_serial` is one of the more mature utility packages in the repo: cohesive, adopted, and well tested.

The highest-value recommendations are:

1. keep it as the structured serialization layer above `static_bits`;
2. guard the boundary so `static_bits` and `static_serial` do not become competing serialization centers;
3. consider trimming root dependency re-exports; and
4. otherwise keep the package narrow and stable around the already-adopted reader/writer/varint/checksum core.
