# `static_math`

Linear algebra types and convention-bearing helpers for games, graphics, physics, and UI.

## Current status

- The root workspace build is the supported entry point; package-local `zig build` is not supported.
- `static_math` stays intentionally narrow: the package owns layout-stable vector, matrix, quaternion, and transform types plus a small set of scalar helpers that teach the package conventions.
- Package-level integration coverage currently proves camera/lookAt conventions and exact TRS roundtrips.
- The package has canonical usage examples for basic math, 2D transforms, camera conventions, and transform roundtrips.
- No package benchmark workflow is currently admitted.

## Main surfaces

- `src/root.zig` exports the package API and the package-wide convention summary.
- `src/math/scalar.zig` owns scalar helpers and convention constants such as `pi`, `tau`, `epsilon`, and degree/radian conversion helpers.
- `src/math/vec2.zig`, `src/math/vec3.zig`, and `src/math/vec4.zig` own the vector types.
- `src/math/mat3.zig` and `src/math/mat4.zig` own matrix types and matrix-space operations.
- `src/math/quat.zig` owns quaternion operations and camera-facing rotation helpers.
- `src/math/transform.zig` owns TRS transforms and the camera/lookAt helpers that are validated by package integration tests.

## Validation

- `zig build check`
- `zig build test`
- `zig build examples`
- `zig build docs-lint`

## Key paths

- `tests/integration/root.zig` wires the package-level deterministic regression coverage.
- `tests/integration/transform_camera_conventions.zig` proves the camera/lookAt and TRS roundtrip contracts.
- `examples/math_basic.zig` is the basic usage example.
- `examples/mat3_2d_transform.zig` demonstrates 2D transform composition.
- `examples/camera_look_at_conventions.zig` demonstrates camera conventions.
- `examples/transform_roundtrip.zig` demonstrates exact TRS roundtrips.
- `docs/plans/completed/static_math_followup_closed_2026-03-31.md` records the current monitor-only closure posture.

## Conventions

- Right-handed coordinates with `+X` right, `+Y` up, and `-Z` forward.
- Column-major matrix storage with column-vector multiplication.
- Projection depth range `[0, 1]`.
- Radians everywhere.
- Counter-clockwise positive rotation when looking down the axis toward the origin.
- Quaternion storage as `(x, y, z, w)` with `w` as the scalar part.
- TRS order as scale, then rotate, then translate, with matrix form `T * R * S`.

