# Sketch: `static_meta` Package Review

Date: 2026-03-06 (America/Denver)  
Status: First review pass completed.

## Scope

Review `packages/static_meta/` for:

- adherence to `agents.md`;
- overlap with Zig standard library facilities and whether the package adds enough value;
- correctness and completeness at file and package scope;
- duplicate, dead, or misplaced code;
- example and test coverage; and
- practical refactor paths.

## Package Inventory

- Source files: 4 modules plus `root.zig`.
- Examples: 2 (`type_id_basic`, `type_registry_basic`).
- Benchmarks: 0.
- Inline unit/behavior tests: 18 plus root wiring coverage.
- Validation in this pass:
  - `zig build examples` passed.
  - `zig build test` remains blocked by the unrelated `static_queues` stress-test failure at `packages/static_queues/src/testing/lock_free_stress.zig:105`.

Observed workspace usage in this pass:

- No external package usage was found under `packages/`.
- Current usage appears limited to `static_meta`'s own examples and tests.

## Package-Level Assessment

`static_meta` is small, cohesive, and conceptually clear.

It solves one focused problem: deterministic type identity with an explicit split between:

- runtime/process-local identity derived from `@typeName(T)`;
- stable cross-binary identity opt-in via `static_name` + `static_version`;
- and a bounded registry for cataloging those identities at runtime.

That is a coherent package boundary.

The package is not large enough to hide much complexity. The main review questions are therefore:

- is this distinct enough from Zig builtins and `static_hash` to justify its own package;
- are the semantics sufficiently sharp and well-tested;
- and is the public surface broader than actual need.

The answer is mostly yes on semantics, but current adoption is still unproven.

## What Fits Well

### The runtime-vs-stable identity split is the package's core value

The package makes an important distinction explicit:

- `@typeName(T)` is useful for in-process identity and diagnostics;
- durable IDs should be opt-in and versioned, not accidentally tied to compiler-generated names.

That design is sound and worth centralizing.

### The package is disciplined about boundedness

`TypeRegistry` uses caller-provided storage and fixed capacity.

That is the right shape for this repo:

- no allocation;
- explicit `NoSpaceLeft`;
- deterministic insertion order;
- simple lookup semantics.

### The package composes naturally with `static_hash`

`static_meta` does not reimplement hashing machinery. It builds metadata policy on top of `static_hash`.

That separation is good:

- `static_hash` owns hashing primitives and stable byte hashing;
- `static_meta` owns type-identity policy.

## STD Overlap Review

### `type_name.zig`

Closest std overlap:

- `@typeName`
- `@hasDecl`
- `@field`

Assessment:

- the raw primitives are from Zig itself, but the stable-identity convention (`static_name` + `static_version`) is package-specific and meaningful.
- this module is justified because it standardizes a policy, not because it wraps builtins for convenience alone.

Recommendation:

- keep this as the package anchor.

### `type_id.zig`

Closest overlap:

- hashing `@typeName(T)` directly

Assessment:

- this module is thin, but still useful if the project wants a single canonical `u64` runtime type identifier policy.
- its value is standardization, not algorithmic uniqueness.

Recommendation:

- keep it as long as `TypeId` remains the canonical registry key type.

### `type_fingerprint.zig`

Closest overlap:

- direct calls into `static_hash`

Assessment:

- this module is mostly a policy adapter around `static_hash` plus `type_name`.
- that is still justified because it packages runtime-vs-stable type fingerprint semantics at one call site.

Recommendation:

- keep it, but resist expanding it into a large catalog of redundant aliases.

### `type_registry.zig`

Closest overlap:

- caller-written fixed arrays plus manual linear search

Assessment:

- this is a very small registry, but it usefully centralizes metadata entry shape and registration rules.
- its boundedness is a clear fit for the repo.

Recommendation:

- keep it if the workspace wants a standard type-catalog shape.

## Correctness and Completeness Findings

## Finding 1: The package is semantically justified but currently unproven by adoption

No external package usage was found in this pass.

That means:

- the API is still mostly self-validated;
- no cross-package consumer has yet forced awkward edge cases to surface;
- and some abstractions may be more stable-looking than they are battle-tested.

This is not a code-quality problem. It is a maturity/readiness observation.

Recommendation:

- keep the package small and disciplined until real consumers appear;
- avoid broadening the API surface preemptively.

## Finding 2: `TypeRegistry` is simple and correct, but currently linear and intentionally minimal

`TypeRegistry` uses:

- caller-provided storage;
- append-only insertion;
- linear duplicate checks and lookup via `findIndex`.

That is completely reasonable at current scale, but it means the package is explicitly optimized for simplicity rather than large registries.

Recommendation:

- keep it as-is unless a real consumer demonstrates meaningful registry sizes.
- do not add hashing or secondary indexing before that pressure exists.

## Finding 3: Stable identity typing is strict in a good way, but the policy surface is narrow

`type_name.zig` enforces:

- `static_name: []const u8`
- `static_version: u32`

This is good because it prevents fuzzy identity contracts.

The tradeoff is that the package currently supports only one stable identity convention and one version type.

That is probably correct for now, but it is worth noting that the package is opinionated rather than generic.

Recommendation:

- keep the policy narrow;
- if future needs arise, prefer explicit versioned alternatives rather than weakening the existing contract.

## Finding 4: The package's value is convention policy, so examples and tests should emphasize semantic differences more than raw determinism

Current tests mostly prove:

- determinism for same input;
- null-vs-required stable identity behavior;
- registry insertion/lookup basics.

Those are good, but the package's real semantic message is:

- runtime identity is not durable identity;
- stable identity is opt-in and versioned;
- registry entries intentionally store both.

That story could be made more explicit in examples/tests.

Recommendation:

- add one example or test that shows a type whose runtime name differs from its stable identity intent;
- add one example that demonstrates version bump behavior changing stable fingerprints while preserving the stable name.

## Duplicate / Dead / Misplaced Code Review

### No meaningful internal duplication

The package is small enough that duplication is minimal.

The modules each have a distinct role:

- naming;
- runtime ID;
- fingerprinting;
- registry.

### No obvious misplaced code

The package boundary is correct.

This code belongs in a metadata/type-identity package, not in `static_hash` or `static_core`.

### `type_id` and `type_fingerprint` are thin, but acceptably thin

They are mostly policy shells around other primitives, but they still help keep the package coherent.

The risk is not duplication inside the package. The risk is letting the package gradually become a bag of aliases.

Recommendation:

- keep these modules focused on canonical policy entry points only.

## Example Coverage

Current examples cover:

- basic runtime `TypeId` + runtime fingerprint derivation;
- bounded registry registration and listing.

Missing example coverage:

- stable identity optional-vs-required behavior;
- stable fingerprint version changes;
- registry entries that mix runtime and stable identity fields in a more explanatory way.

Recommendation:

- add one example specifically about stable identity/versioning, because that is the package's most important concept.

## Test Coverage

Coverage is appropriate for the package size.

Strengths:

- every module has tests;
- determinism, nullability, duplicate registration, capacity exhaustion, and insertion order are covered;
- the package avoids untested public surface.

Gaps:

- no explicit test that different `static_version` values produce different stable fingerprints for the same `static_name`;
- no explicit semantic test framing runtime identity as intentionally non-durable relative to stable identity;
- no consumer-side integration tests because there are no current consumers.

Recommendation:

- add a small number of semantic tests rather than more volume.

## Adherence to `agents.md`

Overall assessment:

- package scope is small and explicit;
- boundedness is respected in the registry;
- comments explain rationale clearly;
- no dynamic allocation occurs in the public runtime structures;
- control flow is simple and auditable.

This package matches the repo rules well.

The only real tension is that some modules are very thin wrappers around builtins or `static_hash`, so the package needs to stay disciplined to remain justified.

## Refactor Paths

### Path 1: Keep the package narrow and policy-focused

The correct package identity is:

- "type identity policy"

not:

- "generic reflection helpers"

Avoid adding broad compile-time utility APIs unless they directly support the existing identity story.

### Path 2: Add one stable-identity example and one version-change test

Highest-value additions:

- example showing `static_name` / `static_version` opt-in;
- test showing stable fingerprint change across version increments for the same stable name.

### Path 3: Let real consumers decide whether `TypeRegistry` should stay minimal

Do not optimize lookup now.

If a real consumer wants large registries or frequent queries, revisit:

- indexing strategy;
- sort/search tradeoffs;
- or an optional hashed registry layer.

### Path 4: Avoid alias creep

`type_id` and `type_fingerprint` are justified as canonical policy entry points.

Do not let them expand into many near-duplicate helpers that merely rename `static_hash` calls.

## Bottom Line

`static_meta` is a clean, coherent package. Its main value is making the runtime-vs-stable type identity split explicit and bounded.

The package does not appear technically weak. The main recommendations are:

1. keep it small and policy-focused until real consumers appear;
2. strengthen examples/tests around stable identity semantics, not just determinism;
3. keep `TypeRegistry` simple unless a real scaling need emerges; and
4. avoid turning the package into a generic reflection/alias layer.
