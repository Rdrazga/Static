# Sketch: `static_math` Package Review

Date: 2026-03-06 (America/Denver)  
Status: First review pass completed.

## Scope

Review `packages/static_math/` for:

- adherence to `agents.md`;
- overlap with Zig standard library facilities and whether the package adds enough value;
- correctness and completeness at file and package scope;
- duplicate, dead, or misplaced code;
- example and test coverage; and
- practical refactor paths.

## Package Inventory

- Source files: 8 math modules plus `root.zig`.
- Examples: 1 (`math_basic`).
- Benchmarks: 0.
- Inline unit/behavior tests: 77 plus root wiring coverage.
- Validation in this pass:
  - `zig build examples` passed.
  - `zig build test` remains blocked by the unrelated `static_queues` stress-test failure at `packages/static_queues/src/testing/lock_free_stress.zig:105`.

Observed workspace usage in this pass:

- No external package usage was found under `packages/`.
- Current usage appears limited to `static_math`'s own example and tests.

## Package-Level Assessment

`static_math` is cohesive and internally consistent.

Its main value is not novelty of individual formulas. Its value is that it packages a single, explicit math convention set:

- right-handed coordinates;
- column-major matrices;
- column-vector multiplication;
- `[0, 1]` projection depth;
- `(x, y, z, w)` quaternion storage;
- `f32`-only layout-stable types.

That convention coherence is the reason for the package. Without it, users would otherwise have to rebuild the same policy from raw std math functions or ad hoc local types.

The package is also restrained in a good way:

- no allocation;
- no backend/platform coupling;
- no generic metaprogramming maze;
- no hidden global state.

The main concerns are package maturity rather than package correctness:

- no external adoption yet;
- very thin example coverage relative to the API surface;
- and some API overlap with std for scalar helpers.

## What Fits Well

### The shared convention layer is the package's real value

The package gives consumers a coherent answer to questions that often drift across codebases:

- what is "forward";
- how are matrices stored;
- what order are transforms composed;
- what projection depth convention is used;
- how are quaternions encoded.

That is more valuable than any single helper function here.

### `extern struct` + `f32` is a defensible design choice

Using `extern struct` fixed-layout types instead of generic vectors gives the package:

- ABI predictability;
- named fields;
- easier debugger readability;
- and consistent GPU/C interop expectations.

That is a real benefit over relying on raw `@Vector` or ad hoc arrays.

### The transform / quaternion / matrix integration is well-shaped

The strongest modules are:

- `quat.zig`
- `mat4.zig`
- `transform.zig`

Together they provide the main package-level value: composition, decomposition, view/projection, and transform application under one consistent convention set.

## STD Overlap Review

### `scalar.zig` has the highest std overlap

Closest std overlap:

- `std.math`
- builtins such as `@sin`, `@cos`, `@floor`, `@sqrt`

Assessment:

- constants and helpers like `toRadians`, `clamp`, `smoothstep`, `fract`, and `mod` are mostly policy/convenience wrappers around standard primitives.
- the main additional value is consistency of naming, epsilon choice, and shader-style semantics.

Recommendation:

- Keep `scalar.zig`, but keep it small and clearly documented as convenience/policy rather than unique math infrastructure.

### The vector/matrix/quaternion types have low direct std overlap

Closest std overlap:

- raw arrays or `@Vector`
- low-level numeric functions in `std.math`

Assessment:

- Zig std does not provide this exact package of named, layout-stable linear algebra types with explicit graphics/game conventions.
- These modules are justified.

Recommendation:

- Keep the typed linear algebra surface as the core of the package.

### `Transform` is especially justified

Closest std overlap:

- none directly

Assessment:

- `Transform` adds a higher-level semantic type over raw matrices and quaternions.
- This is one of the clearest cases where the package meaningfully improves ergonomics and correctness.

Recommendation:

- Keep `Transform` central to the package story.

## Correctness and Completeness Findings

## Finding 1: The package is coherent, but still unproven by workspace adoption

No external package usage was found in this pass.

That means:

- the package API is still largely self-validated rather than consumer-validated;
- the current surface may be broader than future adoption needs;
- and the most important convention choices have not yet been pressure-tested by real dependents.

This is not a code-quality problem. It is a package-maturity observation.

Recommendation:

- Keep the package, but let the first external consumers drive any API expansion.
- Avoid adding new convenience helpers until there is real usage.

## Finding 2: Example coverage is much too thin for the surface area

The package has one example for a surface that includes:

- scalar helpers;
- 2D/3D/4D vectors;
- 3x3/4x4 matrices;
- quaternions;
- decomposed transforms.

That is not enough to teach the intended conventions.

The current example is also not fully aligned with the package ergonomics story because it uses `std.math.degreesToRadians` instead of the package's own `toRadians`.

Recommendation:

- Expand examples before expanding API.
- Prefer examples that demonstrate package conventions, not just isolated formulas.

## Finding 3: `Transform.mul` contains an important approximation path that deserves explicit coverage

`transform.zig` correctly documents that combining non-uniform scale with rotation can introduce shear and that `Transform.mul` returns a best-effort TRS approximation in that case.

That is a reasonable design choice, but it is one of the most semantically surprising behaviors in the package:

- exact composition is not always representable as `Transform`;
- the fallback intentionally loses shear information;
- and callers may not realize they need `Mat4` for exactness.

I did not find an explicit test in this pass that focuses on this approximation path itself.

Recommendation:

- Add one test and one example that make this behavior explicit.
- Show when callers should stay in `Mat4` rather than round-tripping through `Transform`.

## Finding 4: The package's strongest value is convention coherence, so convention cross-checks should be treated as first-class tests

The existing tests are strong in raw count and cover many module-local operations well.

What is still light relative to the package mission is explicit cross-module convention validation such as:

- `Quat.lookRotation` vs `Mat4.lookAt`;
- `Quat.forward` / `Vec3.forward` / `Mat4` camera direction agreement;
- `Transform.toMat4` / `Mat4.decompose` / `Transform.fromMat4` under the same handedness assumptions.

Some of this is covered indirectly, but the package would benefit from a few tests that read like convention proofs rather than algebra spot-checks.

Recommendation:

- Add a small set of cross-module convention tests and keep them near the top-value public workflows.

## Duplicate / Dead / Misplaced Code Review

### The biggest duplication is deliberate vector specialization

`vec2.zig`, `vec3.zig`, and `vec4.zig` repeat many patterns:

- arithmetic;
- normalization;
- component-wise min/max/clamp;
- approximate equality;
- array conversions.

This is clear duplication, but it is also the kind of duplication that keeps the API readable and predictable.

Recommendation:

- Do not replace this with generic metaprogramming unless maintenance becomes painful.
- In math libraries, explicit duplication is often the better tradeoff.

### `mat3.zig` and `mat4.zig` also mirror each other in useful ways

There is repeated structure between the matrix modules, but it mostly reflects legitimate domain parallelism rather than accidental copy-paste debt.

Recommendation:

- Keep them explicit.
- Only factor out shared helpers if a real bug-fix pattern starts repeating.

### No obvious misplaced code

The package boundary is correct.

- scalar helpers belong here;
- layout-stable vector/matrix/quaternion types belong here;
- transform composition/decomposition belongs here.

I did not find logic that clearly belongs in another static package.

## Example Coverage

Current example coverage:

- one mixed basic example touching `Vec3`, `Mat4`, and `Quat`.

Missing example coverage:

- `Transform` construction/composition/inversion;
- `lookAt` / camera-space convention;
- `fromMat4` / `decompose` behavior;
- 2D transforms via `Mat3`;
- scalar helper semantics and package-level conventions.

Recommendation:

- Add at least three more examples:
  - `transform_roundtrip`;
  - `camera_look_at_conventions`;
  - `mat3_2d_transform`.

## Test Coverage

Coverage is strong for a package of this size.

Strengths:

- every module has inline tests;
- vectors, matrices, quaternions, and transforms all have behavior-oriented checks;
- singular inverse and zero-normalization boundary cases are covered;
- decomposition and round-trip behavior are already tested in several places.

Gaps:

- no explicit shear-approximation test for `Transform.mul`;
- no clear package-level convention proof tests across multiple modules;
- no integration-style usage tests outside inline module blocks.

Recommendation:

- Keep the inline tests as the main fast loop.
- Add a few convention-focused tests rather than a large quantity of additional unit tests.

## Adherence to `agents.md`

Overall assessment:

- the package is simple and explicit;
- operations are allocation-free and deterministic;
- preconditions are mostly asserted rather than hidden;
- comments explain conventions and rationale well;
- the code avoids unnecessary abstraction.

Good fits with the repo rules:

- no dynamic allocation in steady-state math operations;
- fixed-size types;
- explicit control flow;
- compile-time layout assertions.

Valid divergences:

- large explicit modules with repeated patterns across dimensions.

That is acceptable here because generic math metaprogramming would likely reduce readability and make convention auditing harder.

## Refactor Paths

### Path 1: Keep the package convention-first, not convenience-first

If the package grows, it should grow around:

- convention-bearing types;
- transform/camera workflows;
- interop guarantees.

It should not grow mainly by adding more scalar wrappers unless consumers clearly need them.

### Path 2: Add example coverage before adding new APIs

The package already has enough API to justify more documentation by example.

Highest-value examples:

- transform composition/inversion;
- `lookAt` and forward/up conventions;
- `Mat4` decomposition and `Transform` approximation limits.

### Path 3: Add a few cross-module convention proofs

The most valuable tests are no longer single-function arithmetic checks.

The next high-value tests are:

- camera/view convention agreement;
- quaternion/matrix orientation agreement;
- exact versus approximate transform composition boundaries.

### Path 4: Avoid generic refactors unless maintenance pain becomes real

The repeated `Vec2`/`Vec3`/`Vec4` structure is acceptable.

If maintenance cost rises, extract only the smallest shared helpers. Do not turn the package into a macro-heavy generic math framework without strong justification.

## Bottom Line

`static_math` is a good package. Its main value is a coherent, explicit linear algebra convention set with layout-stable `f32` types, not novel algorithms.

The package does not look under-tested or technically weak. The biggest improvements are:

1. add examples that actually teach the package conventions;
2. add explicit tests for the `Transform.mul` approximation boundary and cross-module convention coherence;
3. keep `scalar.zig` slim so std-overlap does not become the package identity; and
4. let real consumers shape any further API growth, because there is no external adoption yet.
