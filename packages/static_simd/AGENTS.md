# `static_simd` package guide
Start here when you need to review, validate, or extend `static_simd`.

## Source of truth

- `README.md` for the package entry point and surface summary.
- `src/root.zig` for the exported API surface.
- `tests/integration/root.zig` for package-level deterministic regression coverage.
- `tests/integration/replay_fuzz_trig_differential.zig` for the retained trig differential proof.
- `examples/` for canonical usage and behavior examples.
- `docs/plans/active/workspace_operations.md` for workspace priority and sequencing.
- `docs/architecture.md` for package boundaries and dependency direction.

## Supported commands

- `zig build check`
- `zig build test`
- `zig build examples`
- `zig build docs-lint`

## Working agreements

- Use the root `build.zig` as the supported validation surface.
- Keep `static_simd` focused on lane-parallel math and memory helpers; scalar math and geometry conventions stay in `static_math`.
- Keep the package deterministic and allocation-free unless a change explicitly documents otherwise.
- Prefer direct integration coverage for numerical or convention drift; add shared testing surfaces only when the package genuinely needs them.
- Keep package docs aligned with the root command semantics and update them when the boundary or workflow changes.

## Package map

- `src/root.zig`: package export surface and module summary.
- `src/simd/vec_type.zig`: generic vector-type factory and wrapper generation.
- `src/simd/vec*.zig`: width-specific float and integer vector wrappers.
- `src/simd/masked.zig`: mask helpers.
- `src/simd/memory.zig`: load and store helpers.
- `src/simd/gather_scatter.zig`: gather and scatter helpers.
- `src/simd/compare.zig`: comparisons and selection helpers.
- `src/simd/horizontal.zig`: reductions and horizontal operations.
- `src/simd/math.zig`: elementwise math helpers.
- `src/simd/trig.zig`: SIMD trig helpers and the differential coverage target.
- `src/simd/shuffle.zig`: lane permutation helpers.
- `src/simd/platform.zig`: platform detection and capability gating.
- `tests/integration/`: package-level deterministic and replay-backed coverage.
- `examples/`: usage examples for the public SIMD surface.

## Change checklist

- Update `README.md`, `AGENTS.md`, and the relevant plan or reference doc when package behavior or workflow changes.
- Extend `tests/integration/root.zig` when you add new first-class package integration coverage.
- Add or refresh examples when a public surface needs a canonical usage path.
- Update root `README.md`, root `AGENTS.md`, and `docs/architecture.md` when package guidance or repository navigation changes.
