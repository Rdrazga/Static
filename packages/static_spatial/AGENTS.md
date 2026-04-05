# `static_spatial` package guide
Start here when you need to review, validate, or extend `static_spatial`.

## Source of truth

- `README.md` for the package entry point and current package status.
- `src/root.zig` for the exported surface and allocation-model split.
- `tests/integration/root.zig` for the package-level deterministic regression
  surface.
- `benchmarks/` for canonical benchmark entry points and artifact names.
- `docs/plans/active/packages/static_spatial.md` for the current package work
  queue.
- `docs/plans/active/workspace_operations.md` for workspace priority and
  sequencing.
- `docs/architecture.md` for package boundaries and dependency direction.

## Supported commands

- `zig build check`
- `zig build test`
- `zig build examples`
- `zig build bench`
- `zig build docs-lint`

Command intent:

- Use `zig build test` for deterministic geometry and lifecycle coverage.
- Use `zig build examples` for bounded usage demonstrations.
- Treat `zig build bench` as review-only unless a benchmark workflow
  explicitly opts into gating.
- Use `zig build docs-lint` to keep package docs and cross-links mechanically
  aligned with the workspace source of truth.

## Working agreements

- Use the root `build.zig` as the supported validation surface.
- Keep bounded/build-once structures separate from dynamic mutation-heavy
  structures in docs and examples.
- Keep allocation behavior explicit in module selection and package guidance.
- Prefer shared `static_testing` surfaces for replay, model, retained failure,
  and benchmark workflow plumbing when the package needs them.
- Keep benchmark review artifacts on shared `baseline.zon` plus
  `history.binlog` rather than inventing package-local artifact formats.
- Keep examples as usage demonstrations, not the canonical regression surface.

## Package map

- `src/root.zig`: package export surface and family split.
- `src/spatial/primitives.zig`: geometry primitives, grid config, rays, and
  frusta.
- `src/spatial/morton.zig`: Morton encode/decode helpers.
- `src/spatial/uniform_grid.zig`: bounded 2D uniform grid queries.
- `src/spatial/uniform_grid_3d.zig`: bounded 3D uniform grid queries.
- `src/spatial/loose_grid.zig`: bounded loose-grid queries.
- `src/spatial/sparse_grid.zig`: dynamic sparse-grid mutation paths.
- `src/spatial/bvh.zig`: build-once BVH queries and truncation behavior.
- `src/spatial/incremental_bvh.zig`: dynamic BVH mutation and refit paths.
- `tests/integration/`: deterministic query, lifecycle, model, and replay
  coverage.
- `benchmarks/bvh_query_baselines.zig`: admitted BVH build/query baseline.
- `examples/`: bounded geometry, grid, and BVH usage demonstrations.

## Change checklist

- Update `README.md`, `AGENTS.md`, and the relevant plan record when package
  behavior or workflow changes.
- Extend `tests/integration/root.zig` when you add a new first-class package
  regression surface.
- Add or refresh examples when a public surface needs a canonical usage path.
- Re-record benchmark baselines when workload sizes or semantics change.
- Update root `README.md`, root `AGENTS.md`, and `docs/architecture.md` when
  package guidance or repository navigation changes.
