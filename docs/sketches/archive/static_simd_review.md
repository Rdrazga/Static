# Sketch: `static_simd` Package Review

Date: 2026-03-06 (America/Denver)  
Status: First review pass completed.

## Scope

Review `packages/static_simd/` for:

- adherence to `AGENTS.md`;
- overlap with Zig standard SIMD/vector facilities and whether the package adds enough value;
- correctness and completeness at file and package scope;
- duplicate, dead, or misplaced code;
- example and test coverage; and
- practical refactor paths.

## Package Inventory

- Source files: 17 SIMD modules plus `root.zig`.
- Examples: 3 (`vec4f_basic`, `memory_load_store`, `horizontal_reduction`).
- Benchmarks: 0.
- Inline unit/behavior tests: 125 plus root wiring coverage.
- Validation in this pass:
  - `zig build examples` passed.
  - `zig build docs-lint` passed.
  - `zig build test` failed again because the `static_queues` lock-free stress test remains flaky at `packages/static_queues/src/testing/lock_free_stress.zig:105`.

Observed workspace usage in this pass:

- No external package usage was found under `packages/`.
- Current usage appears limited to `static_simd`'s own examples and tests.

## Package-Level Assessment

`static_simd` is coherent, but it is also one of the packages most exposed to std overlap risk.

Zig already gives the underlying primitive through `@Vector` and the usual arithmetic/comparison builtins. That means this package only stays justified if it keeps adding policy and structure that raw std usage does not provide as cleanly:

- named, width-typed vector APIs instead of raw `@Vector(N, T)` spellings;
- typed masks with consistent helpers;
- bounds-checked memory and gather/scatter entry points;
- a portable scalar baseline;
- and a curated package-local convention for what is supported.

That value is real, but it is narrower than the current export surface sometimes implies.

The package is strongest where it makes policy explicit:

- `memory.zig`
- `gather_scatter.zig`
- `masked.zig`
- `trig.zig`

It is weakest where it mostly republishes existing vector operations under multiple parallel names.

The package also remains self-validated. I did not find downstream consumers outside its own package. That matters here more than in some other packages, because SIMD APIs often look clean until real call sites force clarity about width policy, fallback policy, and which helpers are actually worth carrying.

## What Fits Well

### Typed masks and bounds-checked memory are the clearest package value

`masked.zig`, `memory.zig`, and `gather_scatter.zig` add a meaningful policy layer over raw vectors:

- they make lane masks explicit;
- they treat out-of-bounds access as an operating error;
- and they encode all-or-nothing write guarantees at the API boundary.

That is better than leaving every caller to reconstruct the same safety and semantics locally.

### The scalar-baseline story is well-shaped

The package does not require architecture-specific intrinsics to be useful. It stays on top of Zig vector semantics and lets the compiler scalarize when needed.

That is a good fit for this repository's deterministic, bounded design goals.

### `trig.zig` is a legitimate package-specific add

Approximate SIMD trig with documented range and error bounds is not something Zig std hands over as a ready, package-local API.

This is one of the clearest places where `static_simd` is doing real library work rather than just renaming builtins.

## STD Overlap Review

### Raw vector arithmetic has high std overlap

Closest std overlap:

- `@Vector`
- vector arithmetic and comparisons
- builtins like `@sqrt`, `@mulAdd`, `@select`, `@reduce`

Assessment:

- `vec_type.zig` is mostly a structured wrapper around std vector primitives.
- That is acceptable if it is the single authoritative place for package conventions.
- It becomes weak value if the package keeps layering more wrappers and aliases on top of the same primitive operations.

Recommendation:

- Keep `vec_type.zig` central.
- Resist expanding thin wrapper surface unless a real downstream caller needs the dedicated type/module.

### `memory.zig` and `gather_scatter.zig` have lower std overlap and stronger justification

Closest std overlap:

- slice indexing
- manual caller-side loops

Assessment:

- Zig std does not provide this exact bounded SIMD load/store/gather/scatter policy with package-local error contracts.
- These modules are justified.

Recommendation:

- Keep them as the package's core differentiators.

### `trig.zig` is justified, but only as a narrow module

Closest std overlap:

- scalar trig in `std.math`

Assessment:

- The actual package value is the documented SIMD approximation, not a general trig abstraction.
- Today that value is specifically a `Vec4f` feature, not a generic whole-package trig layer.

Recommendation:

- Keep `trig.zig`, but keep its scope explicit and documented as a narrow specialization.

## Correctness and Completeness Findings

## Finding 1: The package is still self-validated rather than consumer-validated

I found no external package imports of `static_simd` in this pass.

That means:

- API shape is still mostly justified by internal taste rather than downstream pressure;
- there is no evidence yet about which widths and helper families are actually important;
- and compatibility shims may already outweigh proven usage.

This is not a correctness defect. It is a maturity and restraint signal.

Recommendation:

- Do not expand the public surface until a real consumer needs more.
- Let first downstream users decide whether the current width/type/module split is the right one.

## Finding 2: `memory.SimdError` is broader than the implemented contract

`memory.zig` exposes:

- `IndexOutOfBounds`
- `DivisionByZero`
- `DivisionOverflow`

In the reviewed implementation, only `IndexOutOfBounds` is actually used by `memory.zig` and by the gather/scatter APIs that depend on it.

That makes the public error contract misleading:

- callers are told to expect arithmetic failures from load/store helpers that do not perform arithmetic;
- docs and root re-exports imply a broader package-wide error domain than currently exists;
- and the extra names weaken the precision required by `AGENTS.md` error-handling rules.

Recommendation:

- Narrow `SimdError` to the errors the module actually returns today, or split package-local error sets by domain instead of centralizing unrelated names in `memory.zig`.

## Finding 3: The package has deliberate wrapper duplication that needs stronger discipline

There are two visible duplication layers:

- thin width/type modules such as `vec4f.zig` that mainly re-export `vec_type.zig`;
- backward-compatible alias families in `math.zig` and `compare.zig`.

This is not necessarily wrong. It can be a valid developer-experience tradeoff.

But because the package has no outside consumers yet, every extra alias or wrapper is currently speculative surface area. The risk is that `static_simd` turns into several overlapping ways to do the same thing:

- generic function names;
- width-suffixed names;
- `vec_type` aliases;
- and width-specific module wrappers.

Recommendation:

- Treat the current duplication as a compatibility ceiling, not a growth direction.
- Add more wrappers only when a real consumer proves the ergonomics win.

## Finding 4: Example coverage is too narrow for the current public surface

The three examples cover:

- basic `Vec4f` arithmetic;
- basic bounded load/store;
- basic horizontal reductions.

They do not teach several important parts of the package:

- mask semantics;
- gather/scatter semantics;
- compare/select workflows;
- trig approximation scope and limits;
- platform capability reporting.

Given the amount of exported surface, that is not enough.

Recommendation:

- Add examples before adding new APIs.
- Highest-value additions are:
  - `masked_gather_scatter_basic`;
  - `compare_select_basic`;
  - `trig4f_range_and_accuracy`.

## Finding 5: `trig.zig` is good, but the package should not imply broader SIMD trig support than it actually has

`trig.zig` is explicitly `Vec4f`-only today, and that is fine.

The risk is messaging and package identity:

- the root exports `trig` alongside generic-looking modules;
- the package reads like a broad SIMD toolkit;
- but trig support is currently one specialized `Vec4f` implementation.

Recommendation:

- Keep the implementation.
- Make its scope explicit in examples and package docs.
- Avoid introducing placeholder `Vec8f`/`Vec16f` trig names until they are actually implemented and justified.

## Duplicate / Dead / Misplaced Code Review

### The width-specific vector files are mostly wrapper duplication

`vec2f.zig`, `vec4f.zig`, `vec8f.zig`, `vec16f.zig`, `vec4d.zig`, `vec2i.zig`, `vec4i.zig`, `vec8i.zig`, and `vec4u.zig` mostly exist to re-export `vec_type.zig` under more direct names and to host width-specific tests.

That duplication is acceptable if:

- those files remain thin;
- they continue to carry focused behavior tests;
- and they do not start forking semantics away from `vec_type.zig`.

Recommendation:

- Keep them thin.
- If they start accumulating behavior beyond tests and aliases, reconsider whether the generic type factory is still the real package center.

### The width-suffixed alias families are useful, but they are still duplicate API

`math.zig` and `compare.zig` both preserve width-suffixed compatibility names.

That is a valid compatibility choice, but it is still duplicated public surface.

Recommendation:

- Preserve the current aliases if compatibility matters.
- Do not add new alias families unless the package has real external users depending on them.

### No obvious misplaced code

The package boundary is broadly correct.

I did not find code that clearly belongs in another static package. The only boundary risk is not misplacement but overbreadth: exporting too many parallel names for the same SIMD primitive layer.

## Example Coverage

Current example coverage:

- `Vec4f` arithmetic;
- bounded contiguous load/store;
- horizontal reduction.

Missing example coverage:

- masks and select;
- gather/scatter with explicit all-or-nothing error behavior;
- compare workflows;
- approximate trig usage and valid-range expectations;
- platform/capability reporting.

Recommendation:

- Add examples that teach policy and contracts, not just arithmetic.

## Test Coverage

Coverage is strong in raw count and better than average in behavior focus.

Strengths:

- broad inline coverage across nearly every module;
- negative-space checks for bounds and masked gather/scatter behavior;
- special-value coverage for NaN/Inf cases;
- approximation tests for trig and math helpers;
- root wiring coverage.

Gaps:

- no downstream integration tests because there are no downstream consumers yet;
- examples do not currently act as good behavioral documentation for the package edge;
- no stronger package-level proof that the exported surface is worth its current breadth.

The most useful next tests are not more arithmetic spot-checks. They are tests that validate package policy:

- masked scatter all-or-nothing behavior under repeated or mixed-validity indices;
- clearer compile-time rejection tests around unsupported vector types;
- one example-backed behavior test for trig range assumptions.

## Adherence to `AGENTS.md`

Overall assessment:

- the package is explicit and bounded;
- it avoids allocation and shared mutable state;
- control flow is simple and easy to inspect;
- error returns are used for operating failures in memory access paths;
- comments generally explain intent well.

Good fits with the repo rules:

- no dynamic allocation in hot paths;
- fixed-size types;
- bounded loops;
- strong inline test coverage;
- narrow, explicit operating-error handling in access paths.

Valid divergences:

- deliberate wrapper duplication for developer experience.

That divergence is acceptable here if it remains tightly controlled. If it grows further without external adoption, it starts conflicting with the repo's simplicity and zero-debt goals.

## Refactor Paths

### Path 1: Keep `vec_type.zig` as the single semantic center

The package should have one real vector implementation layer.

That means:

- width-specific files stay thin;
- aliases stay compatibility-oriented;
- semantics do not drift across multiple entry points.

### Path 2: Narrow the public error surface

The cleanest immediate fix is to make `SimdError` describe real implemented failures instead of speculative ones.

This is the highest-confidence concrete cleanup from this pass.

### Path 3: Spend the next effort budget on examples, not API growth

The package already exports more than its examples teach.

Best next examples:

- masks plus select;
- masked gather/scatter;
- `Vec4f` trig with stated range/accuracy expectations.

### Path 4: Let real consumers decide whether the wrapper breadth is justified

If downstream users consistently prefer:

- width-specific modules;
- width-suffixed aliases;
- or only the generic modules,

then future cleanup can follow that evidence.

Until then, avoid growing parallel APIs further.

## Bottom Line

`static_simd` is technically solid and well-tested, but its justification depends on discipline.

The package's strongest value is not raw SIMD arithmetic. Zig already provides that substrate. The package earns its place where it adds explicit policy:

1. typed masks and bounded memory/gather/scatter contracts;
2. a portable, structured wrapper layer over `@Vector`;
3. a narrow but real approximate trig module; and
4. consistent package-local semantics.

The best next improvements are:

1. narrow `memory.SimdError` to the failures that actually occur;
2. keep wrapper and alias duplication from expanding further without real consumers;
3. add examples for masks, gather/scatter, and trig;
4. let downstream adoption, not internal taste, determine any further surface growth.
