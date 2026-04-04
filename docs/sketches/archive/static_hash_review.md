# Sketch: `static_hash` Package Review

Date: 2026-03-06 (America/Denver)  
Status: First review pass completed.

## Scope

Review `packages/static_hash/` for:

- adherence to `agents.md`;
- overlap with Zig standard library facilities and whether the package adds enough value;
- correctness and completeness at file and package scope;
- duplicate, dead, or misplaced code;
- example and test coverage; and
- practical refactor paths.

## Package Inventory

- Source files: 10 algorithm/helper modules plus `root.zig`.
- Examples: 5 (`hash_bytes`, `fingerprint_v1`, `hash_any`, `stable_hash`, `siphash_keyed`).
- Benchmarks: 0.
- Inline unit tests: 101 plus root wiring coverage.
- Validation in this pass:
  - `zig build examples` passed.
  - `zig build test` remains blocked by the unrelated `static_queues` stress-test failure at `packages/static_queues/src/testing/lock_free_stress.zig:105`.

Observed external usage in the workspace:

- `crc32` is used by `static_serial`.
- `fingerprint` / `stableFingerprint64` / `combineOrdered64` are used by `static_meta` and `static_string`.
- `wyhash` is used by `static_collections.flat_hash_map`.
- No external usage was found in this pass for `fnv1a`, `siphash`, `xxhash3`, `hash_any`, or `budget`.

## Package-Level Assessment

`static_hash` has two very different categories of code:

- thin wrappers over stable Zig std hashing primitives (`wyhash`, `xxhash3`, `crc32`, much of `siphash`);
- custom higher-level hashing policy (`fingerprint`, `combine`, `budget`, `hash_any`, `stable`).

The custom policy layer is where most of the package's unique value lives. The std-wrapping layer is useful mainly when it standardizes API shape, docs, and examples, but it also increases public surface area and maintenance cost.

## What Fits Well

### The unique policy modules are the strongest parts

The most workspace-specific modules are:

- `combine`
- `fingerprint`
- `budget`
- `hash_any`
- `stable`

These are the modules most worth owning because they encode repo-specific policy around:

- deterministic composition;
- cross-architecture stability;
- explicit work bounds;
- canonical float handling; and
- pointer hashing behavior.

### External adoption already justifies part of the package

Even in the current workspace state:

- `crc32` is clearly justified by `static_serial`;
- `fingerprint` / `stableFingerprint64` / `combineOrdered64` are justified by `static_meta` and `static_string`;
- `wyhash` has at least one real consumer in `flat_hash_map`.

So the package is not speculative overall, even if some individual modules still are.

## STD Overlap Review

### Thin std-overlap wrappers

Closest std overlap:

- `std.hash.Wyhash`
- `std.hash.XxHash3`
- `std.hash.Crc32`
- `std.hash.crc.Crc32Iscsi`
- `std.crypto.auth.siphash`

Assessment:

- `wyhash`, `xxhash3`, `crc32`, and much of `siphash` are mostly API wrappers and one-shot convenience helpers around std.
- That can still be useful when the project wants a uniform package-local surface, but the value is mostly consistency rather than unique behavior.

Recommendation:

- Keep wrappers that are actually consumed or that standardize a materially different API shape.
- Reassess the externally unused wrappers (`fnv1a`, `siphash`, `xxhash3`) if they remain unadopted.

### Low-overlap / high-value modules

Assessment:

- `combine` adds a clear, useful policy surface.
- `fingerprint` adds versioned and content-addressing oriented semantics beyond raw std hashers.
- `budget`, `hash_any`, and `stable` are custom policy layers, not std duplication.

Recommendation:

- Keep these modules, but keep them sharply documented because they encode important semantic policy.

## Correctness and Robustness Findings

## Finding 1: `hash_any` defaults to a footgun-prone pointer policy

`packages/static_hash/src/hash/hash_any.zig:23` documents that non-slice pointers default to address hashing, and the default public entry points (`hashAny`, `hashAnySeeded`) use that policy at `packages/static_hash/src/hash/hash_any.zig:49` and `packages/static_hash/src/hash/hash_any.zig:84`.

This is a meaningful API hazard:

- address hashing is process-local and nondeterministic across runs;
- it is easy for callers to expect content hashing when they see a generic hashing API;
- and the safer behavior already exists via `hashAnyStrict`.

Recommendation:

- Keep the capability, but de-emphasize address-based default entry points.
- Consider making the strict variant the recommended API in docs/examples, or renaming the address-based path so the footgun is more explicit.

## Finding 2: `hash_any` and `stable` both rely on recursive structural walkers

The package rule set strongly prefers non-recursive control flow, but both:

- `hashAnyImpl` in `packages/static_hash/src/hash/hash_any.zig:172`
- `writeAnyImpl` in `packages/static_hash/src/hash/stable.zig:246`

recurse through nested arrays/structs/unions/optionals.

This may be a valid divergence for generic structural hashing, but it should be called out explicitly because:

- the unbudgeted paths do not bound nesting depth at runtime;
- the budgeted paths do bound depth, but only when callers opt in; and
- the recursion is central to the implementation, not incidental.

Recommendation:

- Document this as an intentional divergence and explain why it is acceptable here.
- Consider whether all public recursive entry points should eventually accept or internally impose explicit depth bounds, not just the budgeted variants.

## Finding 3: `hash_any` and `stable` appear to duplicate large amounts of traversal logic

The two large modules:

- `packages/static_hash/src/hash/hash_any.zig`
- `packages/static_hash/src/hash/stable.zig`

both implement broad type-dispatch, float canonicalization, structural traversal, pointer policy, and budget-aware walking.

This duplication is understandable because the output semantics differ, but it creates maintenance risk:

- adding support for a new Zig type shape may need mirrored changes in both modules;
- bug fixes in one traversal path may be forgotten in the other;
- and the package already has two of its largest files dedicated to similar control flow.

Recommendation:

- Do not force premature abstraction, but watch this closely.
- If either module grows further, consider extracting shared internal traversal helpers or a shared policy matrix for supported type categories.

## Finding 4: several modules are public but currently unproven by workspace use

No external usage was found in this pass for:

- `fnv1a`
- `siphash`
- `xxhash3`
- `hash_any`
- `budget`

That does not make them bad, but it does mean the package currently exposes more surface area than the workspace demonstrably needs.

Recommendation:

- Prioritize polish and maintenance around the externally used pieces first.
- Let real consumers justify keeping or expanding the unused modules.

## Duplicate / Dead / Misplaced Code Review

### Thin wrappers may be worth collapsing or de-emphasizing

`wyhash`, `xxhash3`, `crc32`, and `siphash` all provide value mainly through uniform packaging and examples. That is legitimate, but it is also where the package most resembles a re-export catalog rather than a focused static-library layer.

Recommendation:

- If the workspace eventually wants a slimmer public surface, the first candidates to trim or relegate are the thin std wrappers with no current consumers.

### The package is correctly placed

Despite the overlap concerns, the code that is here does belong in a hashing package. There was no obvious logic in this pass that should instead live in a different static library.

## Example Coverage

The current examples cover:

- FNV-1a streaming;
- fingerprint streaming;
- generic hashing;
- stable hashing;
- SipHash keyed hashing.

Missing example coverage for:

- `crc32`
- `combine`
- `budget`
- `wyhash`
- `xxhash3`

Recommendation:

- Add one `crc32` example because it has a real consumer path in `static_serial`.
- Add one `budget` example if the package wants budgeted hashing to become the recommended defensive pattern.

## Test Coverage

Coverage is strong in raw volume and breadth:

- `budget`: 12 tests
- `combine`: 9 tests
- `crc32`: 9 tests
- `fingerprint`: 8 tests
- `fnv1a`: 8 tests
- `hash_any`: 19 tests
- `siphash`: 6 tests
- `stable`: 17 tests
- `wyhash`: 6 tests
- `xxhash3`: 7 tests

Strengths:

- strong algorithm determinism coverage;
- golden-vector style checks are present;
- the custom policy modules have meaningful behavioral tests.

Gaps:

- no behavior-level tests showing how `budget` is used in a real caller flow;
- no cross-check tests that compare `hash_any` versus `stable` on representative value families where stability should or should not differ;
- no workspace integration tests for the actual externally used paths (`crc32` in `static_serial`, fingerprint/stable helpers in `static_meta` and `static_string`).

Recommendation:

- Add one integration-oriented test in a consumer package for CRC32-backed checksums.
- Add one behavior-level test around budgeted hashing on nested/large data if the budget API is intended to be a first-class safety feature.

## Prioritized Recommendations

### High priority

1. Revisit the default pointer-address hashing policy in `hash_any`.
2. Explicitly document the recursive-structural-walker divergence from the repo's normal non-recursion rule.
3. Focus maintenance on the modules already justified by real consumers.

### Medium priority

1. Add example coverage for `crc32` and `budget`.
2. Add one consumer-level integration test for a real adopted path.
3. Monitor `hash_any` / `stable` duplication and consolidate only if continued evolution justifies it.

### Low priority

1. Reassess whether unused std-wrapper modules should remain equally prominent in the public surface.

## Bottom Line

`static_hash` is valuable, but not every part of it is equally valuable.

The package earns its place mainly through:

- fingerprinting;
- stable hashing;
- hash combination;
- CRC32 integration; and
- the shared hashing-policy layer.

The main risks are:

- too much thin wrapper surface around std;
- a potentially surprising default pointer-hashing policy; and
- recursive generic walkers that deserve more explicit justification under the repo rules.

This package should remain, but it would benefit from stronger curation: emphasize the custom policy modules and real consumers, and be more selective about how much wrapper surface it wants to own long term.
