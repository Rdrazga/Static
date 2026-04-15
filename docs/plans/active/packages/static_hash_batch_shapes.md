# `static_hash` batch-shape plan

Scope: additive generic batch-shaped helpers inside `static_hash` that improve
ECS readiness without importing ECS-specific vocabulary or world-local policy.

## Inputs

- `docs/sketches/static_hash_dod_gpu_report_2026-03-17.md`
- `docs/sketches/static_ecs_package_sketch_2026-04-02.md`
- `docs/sketches/static_ecs_package_readiness_review_2026-04-04.md`
- `docs/plans/active/packages/static_hash_algorithm_portfolio_research.md`
- current `packages/static_hash/src/hash/combine.zig`
- current `packages/static_hash/benchmarks/`

## Scope guardrails

- Keep ECS-specific archetype-key wrappers, schema adapters, and world-local
  table hashing in a future `static_ecs` package unless a helper is clearly
  generic enough to stand on its own.
- Start with low-risk generic helpers over existing scalar building blocks
  before introducing any reflective or architecture-specific batch surface.
- Do not admit any helper that quietly reintroduces padding-sensitive,
  uninitialized-byte-sensitive, or target-layout-sensitive hashing under a new
  name. Representation safety must stay explicit.
- Keep algorithm-family research on
  `static_hash_algorithm_portfolio_research.md`; this plan is about generic API
  shape and implementation work, not candidate-hasher portfolio decisions.

## Current state

- `combine` already provides strong scalar pair combiners.
- `hash_any` and `stable` remain reflective, row-oriented, per-value entry
  points.
- The ECS readiness review found a real package-level opportunity below ECS:
  additive fold-many combiners and one possible non-reflective batch primitive
  over homogeneous caller-owned records.

## Current decision note

Default recommendation:

- accept fold-many `combine` helpers as the first implementation slice;
- reject fixed-width batch-record extraction unless the accepted surface can be
  phrased entirely in terms of caller-owned canonical bytes or otherwise proven
  representation-safe without ECS-specific assumptions.

Current candidate outcomes:

- `fold-many combine helpers`
  Current recommendation: accept.
  Reason:
  - they are straightforward left-fold generalizations of existing scalar
    combiners;
  - they are clearly generic and useful outside ECS;
  - they do not reopen the stable-vs-in-memory or padding-safety boundary.
- `fixed-width canonical-byte record primitive`
  Current recommendation: decision-only for now.
  Accept only if:
  - the input contract is already canonical bytes such as `[]const [N]u8`, or
    an equally explicit caller-owned representation;
  - duplicate and ordering semantics are fully pinned;
  - at least one non-ECS repeated-record workload is named alongside the ECS
    motivation.
  Otherwise reject and keep repeated-record adapters in higher layers.
- `raw struct byte batch primitive`
  Current recommendation: reject.
  Reason:
  - it would silently reintroduce padding- and layout-sensitive hashing under a
    new API shape;
  - that is the wrong durable end state for the package.

## Approval status

Approved direction for the current queue:

- approve task 1 and task 2 for implementation, with fold-many `combine`
  helpers as the first accepted package-local slice;
- keep task 3 decision-only until a representation-safe canonical-byte surface
  and a non-ECS caller story are both written down;
- do not block `static_ecs` shape planning on task 3.

## Ordered SMART tasks

1. `Generic batch-helper gate`
   Record the add/reject rules for a batch-shaped helper before implementation.
   Outcome:
   - accepted helpers must operate on generic slices, fixed-width records, or
     caller-owned buffers without ECS terms;
   - accepted helpers must pin whether they are stable/canonical or
     in-memory-only; they may not blur those policies;
   - helpers that only make sense as component-set, archetype, or world-local
     adapters remain out of `static_hash`;
   - the first implementation slice should prefer `combine`-family folds before
     new reflective hashing entry points.
   Add or reject using this gate:
   - fold-many helpers are acceptable if they are exactly specified as
     left-folds over existing scalar combiners from a named seed or identity;
   - fixed-width record helpers are acceptable only if the record
     representation is already caller-owned canonical bytes, such as `[N]u8`,
     or if the API proves unique representation instead of reading arbitrary raw
     struct bytes;
   - reject any helper whose only compelling use is ECS signatures or table
     rows without an equally strong non-ECS caller shape.
   Current smallest bounded slice:
   - refine the default decision note above only if new evidence overturns it;
   - list the exact first candidate helpers that survive the gate.
   Done when the plan records the accepted candidate set and why each one is
   generic.
   Validation:
   - `zig build docs-lint`
2. `Fold-many combine slice`
   Implement the lowest-risk clearly generic batch helpers in `combine.zig`.
   Current preferred candidate set:
   - `combineOrderedMany64(values: []const u64) u64`
   - `combineUnorderedMultisetMany64(values: []const u64) u64`
   Done when:
   - empty-slice semantics, seed or identity value, and equivalence to repeated
     binary combining are documented explicitly;
   - the helpers exist with doc comments and pinned semantic tests;
   - the root surface re-exports them if the package review still supports
     those convenience exports;
   - one benchmark row measures the fold-many workloads alongside the existing
     combine baselines.
   Validation:
   - `zig build test`
   - `zig build bench`
   - `zig build docs-lint`
3. `Fixed-width batch primitive decision`
   Decide whether one non-reflective batch fingerprint or hash surface over
   homogeneous caller-owned records is generic enough to belong in
   `static_hash`.
   Current candidate direction:
   - a fixed-width canonical-byte-record primitive over caller-owned records
     rather than a `[]const []const u8` wrapper that keeps the API row-oriented.
   Done when one explicit outcome is recorded:
   - accept one exact prototype surface and implement it; or
   - reject it for now and record that repeated-record adapters stay in
     `static_ecs`.
   Current default:
   - do not implement this slice unless the canonical-byte input contract and a
     non-ECS caller story are both written first;
   - otherwise close the slice as rejected for now.
   If accepted, the plan must also record:
   - whether duplicate records are treated independently in order;
   - whether the helper is stable or in-memory-only;
   - why its representation contract cannot read padding or uninitialized bytes.
   Validation:
   - `zig build docs-lint`
   - `zig build test`
   - `zig build bench`
4. `Benchmark matrix integration`
   Extend the shared benchmark scenario set with the ECS-readiness rows that can
   inform the package-boundary decision without importing ECS semantics.
   Outcome:
   - short fixed-schema signature-key rows are represented as generic
     many-short-key and fold-many workloads;
   - repeated homogeneous-record rows can compare scalar per-record hashing
     against any accepted batch primitive;
   - the results feed back into
     `static_hash_algorithm_portfolio_research.md` instead of duplicating that
     plan's candidate-family work.
   Done when each accepted helper has a named benchmark owner surface and the
   research plan can cite those results directly.
   Validation:
   - `zig build bench`
   - `zig build docs-lint`

## Work order

1. Freeze the gate for what qualifies as a generic batch helper.
2. Implement fold-many combiners first.
3. Decide whether a fixed-width batch primitive belongs here.
4. Extend the benchmark matrix around the accepted helper set.

## Ideal state

- `static_hash` owns a small truthful set of generic batch helpers.
- ECS-specific signature and archetype wrappers still live in `static_ecs`.
- The package avoids a false-generic middle ground where helpers look reusable
  but actually depend on raw record layout or one ECS-driven workload shape.
- The package can support future ECS and non-ECS callers better without
  collapsing into a domain-specific hashing layer.
