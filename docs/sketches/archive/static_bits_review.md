# Sketch: `static_bits` Package Review

Date: 2026-03-06 (America/Denver)  
Status: First review pass completed.

## Scope

Review `packages/static_bits/` for:

- adherence to `agents.md`;
- overlap with Zig standard library facilities and whether the package adds enough value;
- correctness and completeness at file and package scope;
- duplicate, dead, or misplaced code;
- example and test coverage; and
- practical refactor paths.

## Package Inventory

- Source files: 6 (`root.zig`, `bitfield.zig`, `cast.zig`, `cursor.zig`, `endian.zig`, `varint.zig`).
- Examples: 4 (`byte_reader`, `byte_writer`, `bit_cursor`, `varint`).
- Benchmarks: 0.
- Validation run in this pass:
  - `zig build test`
  - `zig build examples`

Public surface grouped by concern:

- `endian`: slice-based integer loads/stores plus compile-time fixed-array helpers.
- `cast`: checked integer casts with classified failures.
- `cursor`: byte and bit readers/writers with rollback checkpoints.
- `varint`: canonical ULEB128/SLEB128 encode/decode over slices and cursors.
- `bitfield`: bit extraction, insertion, and two-field pack/unpack helpers.

## What Fits Well

### Strong package-level shape

`static_bits` stays mostly at the right abstraction level: allocation-free primitives over caller-owned memory. That fits the workspace goals well and keeps hot-path behavior explicit.

### Good boundedness and failure behavior

The package consistently:

- checks slice and cursor bounds before mutating state;
- preserves cursor positions on failure;
- uses explicit error sets instead of panics for operating errors; and
- covers boundary cases such as zero-width operations, arithmetic overflow, canonical varints, and signed/full-width bit payloads.

### The non-STD value is mostly in composition, not raw novelty

Much of the package wraps standard Zig facilities, but several wrappers are still justified because they add one or more of:

- workspace-standard error vocabulary (`EndOfStream`, `NoSpaceLeft`, `Overflow`, `Underflow`);
- cursor rollback semantics that the raw std helpers do not package together;
- compile-time fixed-layout helpers (`readIntAt`, `writeIntAt`, `extractBitsCt`, `insertBitsCt`);
- canonical varint enforcement, not just decode ability; and
- a consistent allocation-free API surface across related low-level tasks.

## STD Overlap Review

### `endian.zig`

Closest std overlap:

- `std.mem.readInt`
- `std.mem.writeInt`

Assessment:

- The runtime-offset wrappers are thin, but still useful because they add explicit bounds checking and stable errors around `offset + @sizeOf(T)` math.
- `readIntAt` and `writeIntAt` add a real package-specific feature: compile-time validation for fixed binary layouts.

Recommendation:

- Keep the generic `readInt` / `writeInt` / `readIntAt` / `writeIntAt` surface.
- Consider pruning the fixed-width convenience wrappers (`readU16Le`, `readU16Be`, `readU32Le`, `readU32Be`, `writeU16Le`, `writeU16Be`, `writeU32Le`, `writeU32Be`) unless cross-package usage appears. In this pass they only show up inside `endian.zig` tests.

### `cast.zig`

Closest std overlap:

- `std.math.cast`

Assessment:

- `castInt` adds deterministic `Overflow` versus `Underflow` classification, which is a meaningful policy difference from `std.math.cast` returning `?T`.
- `checkedCast` is only a naming alias for `castInt` and is currently only referenced inside the file's own test.

Recommendation:

- Keep `castInt`.
- Remove or de-emphasize `checkedCast` unless there is a clear call-site readability need across the workspace. Right now it widens the public surface without adding behavior.

### `varint.zig`

Closest std overlap:

- `std.leb`
- `std.Io.Reader.takeLeb128`

Assessment:

- The package adds real value over raw std usage by enforcing canonical encodings, returning bytes-consumed metadata, and integrating rollback-safe cursor APIs.
- The compile-time encode/decode helpers are also useful for fixed-format tables and protocol constants.

Recommendation:

- Keep this module in `static_bits`.
- Avoid growing it into a higher-level serialization layer; that belongs in `static_serial`.

### `cursor.zig`

Closest std overlap:

- byte readers/writers available through std I/O readers/writers and fixed-buffer patterns;
- ad hoc bit readers/writers in some std subsystems.

Assessment:

- The byte cursor layer is not novel by itself, but the explicit checkpoint/rewind semantics and package-local error vocabulary justify it.
- The bit cursor layer is the strongest differentiator in the package because it offers allocation-free, caller-owned, LSB-first bit I/O with compile-time fixed-width variants.

Recommendation:

- Keep the cursor layer.
- Keep it primitive: byte/bit movement and atomic failure semantics are the right package boundary.

### `bitfield.zig`

Closest std overlap:

- direct bitwise operators and manual masking/shifting;
- partial overlap with what callers can sometimes model through packed structs.

Assessment:

- The value here is not replacing std; it is centralizing range validation, full-width signed semantics, and common pack/unpack patterns.
- This is a reasonable primitive package fit.

Recommendation:

- Keep the module.
- Be careful not to grow past primitive range operations into protocol-specific field schemas.

## Correctness and Robustness Findings

## Finding 1: No correctness failures found in this pass

The current `static_bits` implementation looks internally consistent. The tests cover:

- range and arithmetic overflow handling;
- cursor rollback and no-advance-on-failure behavior;
- canonical varint rejection;
- signed full-width bit preservation;
- zero-width edge cases; and
- deterministic pseudo-property coverage for bitfield and varint round trips.

This is a good baseline for a low-level package.

## Finding 2: Thread-safety docs are currently misleading

Several modules describe pure or stateless helpers as "not thread-safe" while also describing them as pure/stateless. For:

- `bitfield.zig`
- `cast.zig`
- `endian.zig`

that wording is misleading. Pure functions over caller-provided values are thread-safe as long as callers manage aliasing on shared mutable buffers. The current comments undersell the real contract and create avoidable confusion.

Recommendation:

- Rewrite these module docs to say what the actual constraint is:
  - pure helpers are safe for concurrent use;
  - mutable slice/cursor APIs require caller-managed synchronization when buffers are shared.

## Finding 3: A few public APIs look unproven rather than necessary

In this pass, the following public APIs had no usage outside their defining file's tests:

- `cast.checkedCast`
- `cursor.ByteReader.commit`
- `cursor.ByteWriter.commit`
- `cursor.BitReader.commit`
- `cursor.BitWriter.commit`
- fixed-width endian convenience wrappers

That does not prove they are dead, but it does mean the surface area is ahead of demonstrated demand.

Recommendation:

- Either trim this surface or add real examples/cross-package usage that justify keeping it public.
- If checkpoint commits remain, document clearly that `commit` is a validation barrier and not a state change.

## Finding 4: Some duplication is test-only today, but it is starting to repeat

The package repeats the same deterministic PRNG helper (`nextDeterministic`) in:

- `bitfield.zig`
- `cursor.zig`
- `varint.zig`

and it repeats similar integer-type assertion helpers across multiple files.

Recommendation:

- Do not rush to create a generic internal utilities file just to deduplicate two-line helpers.
- If this pattern spreads further across packages, move shared test-only helpers into a purpose-named testing support module rather than growing each file independently.

## Package-Boundary Review

`static_bits` mostly stays cleanly primitive, but there is visible overlap with `static_serial`:

- `static_serial.reader` and `static_serial.writer` wrap `static_bits.cursor`.
- `static_serial.varint` provides another varint surface on top of `static_bits`.

This is acceptable if the intended layering is:

- `static_bits`: primitive memory/bit/cursor building blocks;
- `static_serial`: serialization-oriented workflows and higher-level framing.

Recommendation:

- Preserve that split intentionally.
- Avoid adding checksum, framing, zigzag policy, or message/schema concepts into `static_bits`.
- During the later `static_serial` review, check whether both varint layers are still paying for themselves or whether one should become a thin re-export/adaptor of the other.

## Example Coverage

Coverage is currently adequate for discoverability but not for package breadth.

What exists:

- basic byte reader example;
- basic byte writer example;
- basic bit cursor example;
- basic varint round-trip example.

What is missing:

- an endian example for fixed binary layouts;
- a bitfield example showing extraction/insertion/pack/unpack;
- a checked-cast example showing overflow versus underflow classification;
- an example showing checkpoint/rewind semantics;
- an example or test-style walkthrough for compile-time APIs (`readIntAt`, `extractBitsCt`, `encodeUleb128Ct`).

Recommendation:

- Add at least two more examples:
  - `examples/endian_layout.zig`
  - `examples/bitfield_layout.zig`
- Prefer examples that show why the package exists over examples that only restate one-byte operations.

## Test Coverage

The package has strong inline unit coverage:

- `root.zig`: 1 test
- `bitfield.zig`: 9 tests
- `cast.zig`: 3 tests
- `cursor.zig`: 13 tests
- `endian.zig`: 7 tests
- `varint.zig`: 9 tests

Strengths:

- clear boundary coverage;
- rollback behavior is explicitly tested;
- deterministic pseudo-random coverage is present for bitfield/cursor/varint paths.

Gaps:

- no higher-level behavior test proving `static_bits` interoperability with `static_serial`;
- no compile-time negative tests for documented compile-time failures;
- no example-backed tests to keep usage docs honest.

Recommendation:

- Add one cross-package behavior test once the serial review starts, using `static_bits` primitives under a realistic serialization flow.
- Add compile-fail coverage only where the compile-time APIs are central to the package value.

## Prioritized Recommendations

### High priority

1. Fix misleading thread-safety documentation in the pure/stateless modules.
2. Decide whether `checkedCast`, `commit`, and the fixed-width endian helpers are permanent public API or removable surface-area drift.
3. Preserve `static_bits` as the primitive layer and keep higher-level serialization policy in `static_serial`.

### Medium priority

1. Add examples for endian layouts, bitfield usage, and rollback/checkpoint semantics.
2. Add at least one behavior-level test spanning `static_bits` and `static_serial`.

### Low priority

1. Consolidate repeated deterministic test helpers only if the pattern continues across more packages.
2. Revisit whether some thin convenience wrappers should become documentation patterns instead of public APIs.

## Bottom Line

`static_bits` is in good shape. The core implementations look correct, bounded, and well-tested. The main risks are not correctness defects; they are API drift and package-boundary blur:

- too many thin wrappers over std or over the package's own generic APIs;
- slightly misleading documentation contracts; and
- possible duplication pressure with `static_serial`.

The package is worth keeping, but it should stay sharply primitive and resist higher-level convenience growth unless real workspace usage demonstrates that the extra surface area earns its cost.
