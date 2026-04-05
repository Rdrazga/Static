# `static_math` package guide
Start here when you need to review, validate, or extend `static_math`.

## Source of truth

- `README.md` for the package entry point and command surface.
- `src/root.zig` for the exported API and convention-bearing types.
- `tests/integration/root.zig` for package-level deterministic regression coverage.
- `examples/` for canonical usage and convention examples.
- `docs/plans/completed/static_math_followup_closed_2026-03-31.md` for the current closure posture.
- `docs/plans/active/workspace_operations.md` for workspace priority and sequencing.
- `docs/architecture.md` for package boundaries and dependency direction.

## Supported commands

- `zig build check`
- `zig build test`
- `zig build examples`
- `zig build docs-lint`

## Working agreements

- Use the root `build.zig` as the supported validation surface.
- Keep the package root focused on convention-bearing linear algebra types and helper scalars that teach the package contract.
- Keep all operations pure, deterministic, allocation-free, and layout-stable unless a change explicitly documents otherwise.
- Keep coordinate-system, matrix-layout, transform-order, quaternion, and angle conventions aligned between code, examples, tests, and docs.
- Prefer direct package integration coverage for convention drift; add shared testing surfaces only if the package genuinely needs them.
- Keep benchmark policy explicit if benchmark work is ever introduced; do not invent package-local artifact formats without a concrete review use case.

## Package map

- `src/root.zig`: package export surface and convention summary.
- `src/math/scalar.zig`: scalar helpers and package convention constants.
- `src/math/vec2.zig`: 2D vector type and operations.
- `src/math/vec3.zig`: 3D vector type and operations.
- `src/math/vec4.zig`: 4D vector type and operations.
- `src/math/mat3.zig`: 3x3 matrix type and operations.
- `src/math/mat4.zig`: 4x4 matrix type and operations.
- `src/math/quat.zig`: quaternion type and operations.
- `src/math/transform.zig`: TRS transform type and camera helpers.
- `tests/integration/`: package-level convention and roundtrip coverage.
- `examples/`: usage examples that demonstrate the supported conventions.

## Change checklist

- Update `README.md`, `AGENTS.md`, and the relevant plan or closure record when package behavior or workflow changes.
- Extend `tests/integration/root.zig` when you add new first-class package integration coverage.
- Update or add an example when a convention or API change needs a canonical usage path.
- Update root `README.md`, root `AGENTS.md`, and `docs/architecture.md` when package guidance or repository navigation changes.
