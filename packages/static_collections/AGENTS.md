# `static_collections` package guide
Start here when you need to review, validate, or extend `static_collections`.

## Source of truth

- `README.md` for the package entry point and command surface.
- `src/root.zig` for the exported surface.
- `tests/integration/root.zig` for the package-level deterministic regression
  surface.
- `tests/compile_fail/build.zig` for the package-owned compile-contract
  boundary checks.
- `benchmarks/` for canonical benchmark entry points and artifact names.
- `examples/` for bounded usage examples.
- `docs/architecture.md` for package boundaries and dependency direction.
- `docs/plans/active/workspace_operations.md` for workspace priority and
  sequencing when collections work intersects a broader slice.

## Supported commands

- `zig build check`
- `zig build test`
- `zig build bench`
- `zig build examples`
- `zig build docs-lint`

## Working agreements

- Use the root `build.zig` as the supported validation surface.
- Keep collection contracts explicit and bounded: capacity, aliasing,
  iterator exposure, handle invalidation, and comparator/hash constraints
  should be visible in code and docs.
- Keep `tests/compile_fail/` as the home for generic contract failures that are
  meant to be rejected at comptime.
- Prefer shared `static_testing` only when the behavior really needs model,
  replay, or benchmark workflow support; otherwise keep the proof local to the
  package.
- Keep benchmark review on shared `baseline.zon` plus bounded history
  sidecars; do not introduce package-local artifact formats.
- Update package docs and the relevant plan or reference doc in the same slice
  when behavior, boundaries, or workflow change.

## Package map

- `src/collections/bit_set.zig`: bounded bit-set operations and boundary cases.
- `src/collections/dense_array.zig`: dense storage and relocation bookkeeping.
- `src/collections/fixed_vec.zig`, `src/collections/vec.zig`, and
  `src/collections/small_vec.zig`: fixed-capacity and bounded vector variants.
- `src/collections/flat_hash_map.zig` and
  `src/collections/sorted_vec_map.zig`: map families with borrowed lookup,
  removal, and bounded `getOrPut` helpers.
- `src/collections/min_heap.zig`: heap and priority-queue ordering contracts.
- `src/collections/slot_map.zig`, `src/collections/index_pool.zig`, and
  `src/collections/handle.zig`: handle-based storage and stale-handle
  rejection.
- `src/collections/sparse_set.zig`: sparse/dense membership tracking.
- `tests/integration/`: deterministic runtime-sequence coverage.
- `tests/compile_fail/`: negative compile-contract fixtures for generic
  boundaries.
- `benchmarks/`: canonical review workloads.
- `examples/`: bounded usage examples only.

## Change checklist

- Update `README.md` and `AGENTS.md` when package behavior or workflow changes.
- Extend `tests/integration/root.zig` when adding first-class package
  integration coverage.
- Extend `tests/compile_fail/build.zig` when a generic rejection boundary
  changes.
- Re-record benchmark baselines when workload sizes or semantics change.
- Update root `README.md`, root `AGENTS.md`, and `docs/architecture.md` when
  package guidance or repository navigation changes.
