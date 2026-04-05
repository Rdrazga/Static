# `static_spatial`

Geometry primitives plus spatial indexing structures for the `static` workspace.

## Current status

- The root workspace build is the supported entry point; package-local
  `zig build` is not supported.
- The package is split between bounded/build-once structures and dynamic
  mutation-heavy structures, and the package root documents that split
  explicitly.
- Deterministic package coverage currently includes BVH boundary and
  truncation proofs, `IncrementalBVH` lifecycle and mutation-sequence coverage,
  and a retained replay roundtrip for inclusive boundary-touching failures.
- The admitted benchmark surface is `benchmarks/bvh_query_baselines.zig`,
  which reviews one deterministic `BVH` geometry set across build plus the
  canonical query workloads.
- The bounded grid family still has an active contract-alignment follow-up in
  `docs/plans/active/packages/static_spatial.md`.

## Main surfaces

- `src/root.zig` exports the package API and names the bounded versus dynamic
  family split.
- `src/spatial/primitives.zig` owns geometry primitives, ray/frustum helpers,
  and grid configuration types.
- `src/spatial/morton.zig` owns Morton encode/decode helpers.
- `src/spatial/uniform_grid.zig`, `src/spatial/uniform_grid_3d.zig`, and
  `src/spatial/loose_grid.zig` own the bounded grid family.
- `src/spatial/bvh.zig` owns the build-once BVH path.
- `src/spatial/sparse_grid.zig` and `src/spatial/incremental_bvh.zig` own the
  dynamic mutation-heavy family.
- `tests/integration/root.zig` wires deterministic lifecycle, model, replay,
  and truncation coverage.
- `benchmarks/bvh_query_baselines.zig` owns the canonical admitted benchmark
  workload.
- `examples/` contains bounded usage examples for primitives, grids, BVH, and
  incremental BVH flows.

## Validation

- `zig build check`
- `zig build test`
- `zig build examples`
- `zig build bench`
- `zig build docs-lint`

Command intent:

- Keep `zig build test` as the main pass/fail surface for deterministic
  geometry and lifecycle coverage.
- Keep `zig build examples` for usage demonstrations.
- Treat `zig build bench` as review-only unless a benchmark workflow
  explicitly opts into gating.

## Key paths

- `tests/integration/bvh_boundary_touching_queries.zig` covers inclusive
  boundary-touching query semantics.
- `tests/integration/bvh_query_aabb_truncation.zig`,
  `tests/integration/bvh_query_ray_truncation.zig`,
  `tests/integration/bvh_query_ray_sorted_truncation.zig`, and
  `tests/integration/bvh_query_frustum_truncation.zig` cover BVH truncation
  behavior.
- `tests/integration/incremental_bvh_lifecycle.zig` covers insert, remove,
  refit, and reuse flows.
- `tests/integration/incremental_bvh_model_sequences.zig` covers mutation-heavy
  structural sequences.
- `tests/integration/replay_incremental_bvh_boundary_failures.zig` keeps
  retained boundary failures replayable.
- `benchmarks/bvh_query_baselines.zig` defines the admitted benchmark owner.
- `examples/spatial_basic.zig`,
  `examples/bvh_ray_aabb_frustum_basic.zig`,
  `examples/uniform_grid_3d_basic.zig`, and
  `examples/incremental_bvh_insert_remove_refit.zig` show the package's core
  usage paths.

## Benchmark artifacts

- Benchmark outputs live under `.zig-cache/static_spatial/benchmarks/<name>/`.
- Canonical review artifacts stay on shared `baseline.zon` plus
  `history.binlog`.
- Re-record baselines when geometry size, query mix, or truncation semantics
  change materially.
