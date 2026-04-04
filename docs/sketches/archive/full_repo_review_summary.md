# Sketch: Full Repo Review Summary

Date: 2026-03-06 (America/Denver)  
Status: Consolidated after package-by-package review completion.

## Scope

This document consolidates the package reviews captured in:

- `docs/sketches/static_bits_review.md`
- `docs/sketches/static_collections_review.md`
- `docs/sketches/static_core_review.md`
- `docs/sketches/static_hash_review.md`
- `docs/sketches/static_io_review.md`
- `docs/sketches/static_math_review.md`
- `docs/sketches/static_memory_review.md`
- `docs/sketches/static_meta_review.md`
- `docs/sketches/static_net_review.md`
- `docs/sketches/static_net_native_review.md`
- `docs/sketches/static_profile_review.md`
- `docs/sketches/static_queues_review.md`
- `docs/sketches/static_rng_review.md`
- `docs/sketches/static_scheduling_review.md`
- `docs/sketches/static_serial_review.md`
- `docs/sketches/static_simd_review.md`
- `docs/sketches/static_spatial_review.md`
- `docs/sketches/static_string_review.md`
- `docs/sketches/static_sync_review.md`

It focuses on repo-level patterns:

- which packages are already part of the real workspace spine;
- which packages are still mostly self-validated;
- where package boundaries are fuzzy or duplicated;
- where build/package metadata drift is recurring;
- and where cross-package behavior coverage is still light.

Validation in this consolidation pass:

- `zig build examples` passed.
- `zig build docs-lint` passed.
- `zig build test` passed.

## Executive Summary

The repository already has a strong core.

The most credible package spine today is:

- `static_core`
- `static_hash`
- `static_memory`
- `static_sync`
- `static_bits`
- `static_serial`
- `static_net`
- `static_net_native`
- `static_queues`
- `static_collections`
- `static_io`

These packages show actual implementation-level reuse across the workspace and already form a coherent systems-library stack.

The main repo-wide weaknesses are not basic code quality. The main weaknesses are:

1. package-boundary drift;
2. public-surface breadth that exceeds current adoption;
3. build/package metadata drift;
4. too few cross-package behavior tests and examples;
5. a long tail of packages that are still mostly self-validated.

The right next step is not broad API expansion. The right next step is consolidation:

- trim or justify root re-exports;
- remove unused dependencies and dead error variants;
- resolve overlapping package boundaries;
- and add a small number of cross-package behavior tests/examples for the adopted spine.

## Strengths

### The repo has an identifiable adopted systems spine

Source-level import review shows these implementation relationships matter now:

- `static_bits` -> `static_core`
- `static_serial` -> `static_bits`, `static_core`, `static_hash`
- `static_net` -> `static_serial`, `static_core`
- `static_net_native` -> `static_net`
- `static_io` -> `static_net_native`, `static_net`, `static_sync`, `static_queues`, `static_collections`, `static_memory`, `static_core`
- `static_queues` -> `static_sync`, `static_memory`, `static_core`
- `static_scheduling` -> `static_sync`, `static_collections`, `static_core`
- `static_memory` -> `static_sync`, `static_core`
- `static_collections` -> `static_memory`, `static_hash`
- `static_string` -> `static_hash`
- `static_meta` -> `static_hash`

That spine is technically stronger than the rest of the repo because it is already being pressure-tested by real package reuse.

### The repo consistently prefers explicit contracts over hidden behavior

Across the stronger packages, the common pattern is good:

- bounded capacities;
- explicit error vocabularies;
- compile-time capability gating;
- and behavior-oriented tests.

The best packages are not the most abstract packages. They are the ones that keep contracts narrow and explicit.

### The package reviews show a coherent repo philosophy

The same values show up repeatedly in the better packages:

- deterministic memory use;
- explicit boundary types;
- fixed-shape runtime behavior;
- and a willingness to reject vague convenience surface.

That coherence is a real asset.

## Dependency And Adoption Snapshot

## Tier 1: Adopted core packages

These are already used by other packages at source level and should be treated as the main stable spine:

- `static_core`
- `static_hash`
- `static_memory`
- `static_sync`
- `static_bits`
- `static_serial`
- `static_net`
- `static_net_native`
- `static_collections`
- `static_queues`

## Tier 2: Integration / leaf packages

These packages depend on the core spine and matter, but they are currently leaf packages rather than shared lower-level utilities:

- `static_io`
- `static_scheduling`

These should still stay restrained, but lack of inbound package use is not itself a problem.

## Tier 3: Mostly self-validated packages

These packages currently have no identified downstream source-level consumers in the workspace:

- `static_math`
- `static_meta`
- `static_profile`
- `static_rng`
- `static_simd`
- `static_spatial`
- `static_string`

This does not mean they are bad packages. It means:

- public-surface growth should be slow;
- examples matter more;
- and package boundaries should be conservative until real use appears.

## Highest-Priority Repo Issues

## Priority 1: Fix build and package metadata drift

This is the most mechanical class of issue, and it is also the easiest to clean up quickly.

Concrete issues already identified:

- `static_net_native` lacks package-local `build.zig` / `build.zig.zon` completeness relative to sibling packages.
- `static_io` has package completeness drift around `static_net_native`.
- `static_scheduling` imports `static_collections` in source but omits it from package metadata.
- `static_rng` carries an unused `static_core` dependency.
- `static_string` carries an unused `static_core` dependency.

These issues are high priority because they create avoidable confusion without adding any value.

## Priority 2: Shrink or justify root re-export surfaces

Multiple packages expose dependencies or wrappers at the root that current usage does not justify.

Most notable cases:

- `static_serial` re-exports `static_core`, `static_bits`, and `static_hash`
- `static_profile` re-exports `static_serial` without implemented use
- `static_sync` re-exports `static_core` and thin std wrappers
- `static_scheduling` re-exports `static_queues` despite no package-local implementation use of that root alias

This is repo-wide surface drift. It makes package identity weaker and makes future cleanup harder.

## Priority 3: Resolve overlapping package boundaries

Several packages are now close enough in purpose that they risk duplicating or competing with one another.

The clearest overlaps are:

- `static_bits` vs `static_serial`
- `static_collections.min_heap` vs `static_queues.priority_queue`
- `static_sync` wrapper surface vs std synchronization types
- `static_spatial` static data structures vs dynamic ones inside the same package

These are not all equally severe, but they are the places where package ownership needs a clearer answer.

## Priority 4: Add cross-package behavior tests and examples

Most packages test themselves well in isolation.

The repo is weaker at proving cross-package behavior:

- `static_bits` + `static_serial`
- `static_serial` + `static_net`
- `static_sync` + `static_queues`
- `static_sync` + `static_io`
- `static_collections` + `static_scheduling`
- `static_memory` + `static_queues`

The highest-value test additions are integration-style behavior checks at those boundaries, not more single-function unit tests.

## Cross-Package Boundary Findings

## `static_bits` and `static_serial`

This is the clearest layered-boundary question in the repo.

What is working:

- `static_serial` already consumes `static_bits`.
- The repo has a real lower-level to higher-level relationship here.

What still looks fuzzy:

- both packages expose cursor/endian/varint-adjacent concepts;
- both risk becoming "serialization centers";
- and users may not know where the stable boundary is.

Recommended boundary:

- `static_bits` owns primitive byte/bit mechanics;
- `static_serial` owns structured encoding/decoding workflows and framing;
- thin overlap should either collapse downward or become an explicit adaptor layer.

Likely repo issue:

- keeping both packages broad will create long-term duplicate API and documentation burden.

## `static_collections` and `static_queues`

This is the clearest ownership conflict outside serialization.

What is working:

- `static_queues` already depends heavily on `static_memory` and `static_sync`, which fits its concurrency role.
- `static_collections` has a good ownership story for handles, pools, small vectors, and maps.

What still looks fuzzy:

- `static_collections.min_heap`
- `static_queues.priority_queue`

Those are close enough that one package likely owns the primitive and the other should adapt or consume it.

Likely repo issue:

- if both remain public first-class surfaces, the repo will carry two homes for priority ordering semantics.

## `static_sync` and std

`static_sync` is justified when it adds:

- capability gating;
- cancellation;
- wait-queue semantics;
- package-local timeout/error policy.

It is weak when it mainly renames std.

Likely repo issue:

- if `mutex`, `rwlock`, and other thin wrappers remain central public surface, the package boundary will stay blurry and downstream callers will not know when std should be used directly.

## `static_spatial` internal boundary

`static_spatial` mixes:

- bounded/static structures like `UniformGrid`, `UniformGrid3D`, and `BVH`;
- dynamic structures like `SparseGrid` and `IncrementalBVH`.

That is not a topic mismatch, but it is a runtime-policy mismatch.

Likely repo issue:

- the package root currently overstates the static/allocation model and will keep confusing readers unless the static-versus-dynamic split is made explicit or separated.

## Cross-Package Usage Gaps And Likely Missing Reuse

## Missing or weakly justified dependency use

These are concrete current issues:

- `static_rng` depends on `static_core` without reviewed source usage.
- `static_string` depends on `static_core` without reviewed source usage.
- `static_profile` depends on and re-exports `static_serial` without implemented source use.

These should be cleaned up before new package growth.

## Likely missing consolidation at the queue / heap boundary

The strongest likely missing reuse is:

- `static_queues.priority_queue` versus `static_collections.min_heap`

Even if one remains a higher-level queue wrapper, the underlying heap ownership should probably converge.

## Likely missing consolidation at the bits / serial boundary

The second strongest likely missing consolidation is:

- low-level serialization helpers split across `static_bits` and `static_serial`

This is already a real dependency chain, so the problem is not lack of reuse. The problem is lack of a fully crisp ownership line.

## Likely missing cross-package examples for the adopted spine

The repo has enough package-local examples now, but it still lacks examples that show intended combinations such as:

- `static_serial` feeding `static_net` frame work;
- `static_sync` primitives inside queue coordination flows;
- `static_collections` and `static_scheduling` together;
- `static_memory` plus queue or runtime integration.

Those are likely missing usage artifacts rather than missing code.

## Packages Most At Risk Of Re-Implementing Stable Surface Without Strong Justification

These are not all equal problems, but they should stay under pressure:

- `static_simd`: Zig already provides `@Vector`; package value must stay in masks, bounded access helpers, and curated policy.
- `static_string.utf8` and `static_string.ascii`: std overlap is high; keep them small.
- `static_sync` thin wrapper surface: avoid becoming a renamed std namespace.
- `static_hash` algorithm catalog surface: avoid becoming mostly a re-export shelf.

## Repo-Wide Documentation And Validation Gaps

## Examples are still too package-local

A recurring pattern across reviews:

- examples exist, but many only show isolated primitives;
- examples are still thin in packages with larger conceptual surfaces;
- and examples rarely demonstrate intended package composition.

## Cross-package behavior tests are the biggest missing validation layer

The package-level test count is generally good.

The missing layer is integration tests that prove:

- `static_bits` / `static_serial` boundary contracts;
- `static_serial` / `static_net` framing behavior;
- `static_sync` / `static_queues` wake and coordination behavior;
- `static_sync` / `static_io` runtime behavior;
- `static_collections` / `static_scheduling` planning structures.

## Recommended Consolidation Plan

## Phase 1: Mechanical cleanup

Do these first:

- remove unused dependencies in `static_rng` and `static_string`
- fix `static_scheduling` package metadata drift
- fix `static_net_native` package completeness
- fix `static_io` package completeness around `static_net_native`
- remove dead public error variants and placeholder-root dependencies where already identified

## Phase 2: Boundary cleanup

Then decide ownership at the main overlap points:

- `static_bits` versus `static_serial`
- `static_collections` versus `static_queues` for priority semantics
- `static_sync` versus std wrapper exposure
- `static_spatial` static versus dynamic structures

## Phase 3: Integration proof

Then add a small number of high-value integration artifacts:

- one cross-package behavior test per major adopted boundary
- one or two examples that demonstrate intended package composition

## Phase 4: Freeze breadth on self-validated packages

For packages with no downstream consumers:

- do not grow broad new API surface yet;
- prioritize examples, docs, and focused adoption;
- let real consumers decide where expansion is warranted.

## Bottom Line

The repo does not have a general quality problem. It has a consolidation problem.

The adopted spine is already good enough to stabilize:

- `static_core`
- `static_hash`
- `static_memory`
- `static_sync`
- `static_bits`
- `static_serial`
- `static_net`
- `static_net_native`
- `static_collections`
- `static_queues`
- `static_io`

The main repo-level work now is:

1. clean up metadata and dependency drift;
2. shrink or justify root re-exports and wrapper surface;
3. resolve the few real overlap boundaries;
4. add cross-package tests/examples for the adopted spine; and
5. keep low-adoption packages restrained until real consumers appear.

If that consolidation happens, the repo gets substantially stronger without needing much new functionality.
