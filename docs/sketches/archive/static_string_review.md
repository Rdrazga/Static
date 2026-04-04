# Sketch: `static_string` Package Review

Date: 2026-03-06 (America/Denver)  
Status: First review pass completed.

## Scope

Review `packages/static_string/` for:

- adherence to `AGENTS.md`;
- overlap with Zig standard string/text facilities and whether the package adds enough value;
- correctness and completeness at file and package scope;
- duplicate, dead, or misplaced code;
- example and test coverage; and
- practical refactor paths.

## Package Inventory

- Source files: 4 string modules plus `root.zig`.
- Examples: 2 (`bounded_buffer_basic`, `intern_pool_basic`).
- Benchmarks: 0.
- Inline unit/behavior tests: 24 plus root wiring coverage.
- Validation in this pass:
  - `zig build examples` passed.
  - `zig build docs-lint` passed.
  - `zig build test` passed.

Observed workspace usage in this pass:

- No external package usage was found under `packages/` or `docs/`.
- Current usage appears limited to `static_string`'s own examples and tests.

## Package-Level Assessment

`static_string` is small, coherent, and easy to reason about.

Its best story is not "string utilities" in the broad sense. Zig std already provides a large amount of string-adjacent functionality. The package is justified where it makes boundedness and explicit policy the center:

- caller-provided storage for append buffers;
- allocation-free UTF-8 validation;
- explicit ASCII-only helpers;
- bounded deterministic interning.

That is a defensible package identity.

The main issues are not implementation breakage. They are package-boundary discipline:

- one unused package dependency;
- some high std overlap in `utf8.zig` and `ascii.zig`;
- and thin example coverage for half the exported surface.

## What Fits Well

### `BoundedBuffer` is the clearest package-local value

`bounded_buffer.zig` is a good fit for the repository:

- caller-owned storage;
- no allocation;
- explicit capacity failure;
- and atomic append behavior.

This is stronger and more aligned with the repo than relying on allocator-backed buffers at every call site.

### `InternPool` is justified despite std overlap elsewhere

Zig std has maps and string keys, but `InternPool` does something materially different:

- fixed entry capacity;
- fixed byte capacity;
- deterministic symbol assignment;
- and no allocation after initialization.

That is enough to justify the module.

### The package keeps encoding policy explicit

It is useful that the package does not blur:

- ASCII byte helpers;
- UTF-8 validation;
- and bounded storage/interning.

That separation is simple and correct.

## STD Overlap Review

### `utf8.zig` has the highest std overlap

Closest std overlap:

- `std.unicode` UTF-8 validation facilities

Assessment:

- The manual validator appears careful and technically reasonable.
- But the package is re-implementing a mature standard concern here.
- Its justification is mainly explicit package-local policy and zero-allocation predictability, not novel functionality.

Recommendation:

- Keep it only if the package wants this exact explicit contract and local auditability.
- Avoid expanding it into a larger Unicode toolkit without strong justification.

### `ascii.zig` also overlaps standard byte-slice utilities

Closest std overlap:

- simple byte iteration
- case folding and trimming that callers can write locally or approximate with std helpers

Assessment:

- The current module is small enough to be acceptable.
- It should stay narrow and clearly ASCII-only.

Recommendation:

- Keep the current small surface.
- Do not let it drift into generic string manipulation utilities.

### `BoundedBuffer` and `InternPool` have stronger package-specific value

Closest std overlap:

- allocator-backed formatting and list/map utilities

Assessment:

- These modules are the package's core justification because they encode bounded-storage policy explicitly.

Recommendation:

- Keep them central to the package identity.

## Correctness and Completeness Findings

## Finding 1: `static_core` is an unused active dependency

`packages/static_string/build.zig` and `packages/static_string/build.zig.zon` declare `static_core`, but none of the reviewed source files import it.

That is package-metadata drift:

- it broadens the dependency surface without need;
- it makes the package look more integrated than it currently is;
- and it increases review and maintenance cost.

Recommendation:

- Remove the `static_core` dependency unless a real source import is added.

## Finding 2: The package is strongest where it is bounded, not where it re-implements generic text helpers

The strongest modules are:

- `bounded_buffer.zig`
- `intern_pool.zig`

The weaker-justified modules are:

- `utf8.zig`
- `ascii.zig`

This is not a correctness complaint. It is a package-boundary observation. If the package grows mainly by adding more text helpers, it starts competing with std for little gain.

Recommendation:

- Keep growth focused on bounded storage and explicit text-policy layers, not convenience text helpers.

## Finding 3: Example coverage is uneven

The package exports four modules, but the examples only cover:

- `BoundedBuffer`
- `InternPool`

Nothing currently demonstrates:

- UTF-8 validation workflows;
- ASCII normalization or trimming behavior;
- or how the package expects callers to combine these modules.

Recommendation:

- Add one example for validation and one for ASCII-only normalization before adding more API.

## Finding 4: `InternPool` is intentionally linear and that is correct at current scale

`InternPool.intern` and `contains` linearly scan current entries, using `fingerprint64` plus byte equality.

That is acceptable here because:

- capacity is caller-bounded;
- determinism matters more than asymptotic cleverness at this scale;
- and the implementation stays easy to audit.

Recommendation:

- Keep the linear design unless real consumers demonstrate that bounded capacities are large enough for lookup cost to matter.

## Finding 5: The package is still self-validated

No downstream package consumers were found in this pass.

That means:

- the current API surface is mostly justified by internal design intent;
- there is not yet external pressure confirming which modules are actually valuable;
- and examples/documentation matter more than usual.

Recommendation:

- Keep the package restrained until real users show where it should grow.

## Duplicate / Dead / Misplaced Code Review

### No significant internal duplication

The package is small and each module has a distinct role.

I did not find meaningful copy-paste duplication that needs refactoring.

### The clearest dead item is the unused dependency

The main dead-surface issue is not code. It is package metadata:

- `static_core` is declared but unused.

### No obvious misplaced code

The current module split is sensible:

- bounded storage;
- ASCII byte helpers;
- UTF-8 validation;
- bounded interning.

The only boundary risk is future drift toward generic string helpers that are better left to std.

## Example Coverage

Current example coverage:

- bounded append buffer usage;
- deterministic interning.

Missing example coverage:

- UTF-8 validation;
- ASCII trim/lower/equality flows;
- combined workflows such as validate -> normalize -> intern.

Recommendation:

- Add:
  - `utf8_validate_basic`;
  - `ascii_normalize_basic`;
  - or one combined example if the package wants to teach a typical pipeline.

## Test Coverage

Coverage is decent for the package size.

Strengths:

- `BoundedBuffer` covers atomic failure behavior;
- `utf8.zig` covers truncation, overlong encodings, surrogates, and max scalar value;
- `ascii.zig` covers the main happy and boundary paths;
- `InternPool` covers duplicate interning, resolve failure, capacity failure, and byte accounting.

Gaps:

- no downstream behavior tests because there are no consumers yet;
- no example-backed tests covering package-level workflows;
- no tests that stress `InternPool` collision behavior beyond whatever the hash function happens to do naturally.

The highest-value next test is probably one deterministic collision-style test for `InternPool` semantics, but only if that can be done without distorting the simple current design.

## Adherence to `AGENTS.md`

Overall assessment:

- the package is simple and explicit;
- bounded storage modules fit the repo well;
- error handling is generally precise;
- and the code avoids unnecessary abstraction.

Good fits with the repo rules:

- no hidden allocation in the core bounded modules;
- explicit operating-error returns for capacity exhaustion;
- simple control flow;
- small, auditable modules.

Meaningful divergences:

- `utf8.zig` and `ascii.zig` re-implement standard-adjacent helpers rather than leaning on std.

That divergence is acceptable right now because the modules are small. It becomes weak if they grow much further without stronger package-specific policy value.

## Refactor Paths

### Path 1: Remove the unused `static_core` dependency

This is the cleanest immediate fix.

### Path 2: Keep the package centered on bounded storage and interning

If the package grows, it should grow around:

- bounded buffers;
- bounded string tables;
- explicit encoding-policy boundaries.

It should not become a general-purpose string helper package.

### Path 3: Add examples for the currently unillustrated modules

Highest-value additions:

- UTF-8 validation example;
- ASCII normalization example;
- one end-to-end bounded text pipeline example if real consumers appear.

### Path 4: Avoid over-optimizing `InternPool` before adoption exists

The linear scan is simple and defensible.

Do not replace it with a more complex indexing scheme until there is actual evidence that current bounded capacities are too large for it.

## Bottom Line

`static_string` is a good small package, but it should stay narrow.

Its strongest value is bounded string storage and deterministic interning, not generic text helpers. The main findings from this pass are:

1. `static_core` is an unused package dependency and should be removed;
2. `BoundedBuffer` and `InternPool` are the real package center;
3. `utf8.zig` and `ascii.zig` are acceptable but have high std overlap and should stay small;
4. example coverage is too thin for half the exported surface; and
5. there are still no downstream consumers.

The best next step is cleanup and examples, not broader API.
