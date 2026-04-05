# `static_meta`

Compile-time type identity and bounded registry helpers for the `static`
workspace.

## Current status

- The root workspace build is the supported entry point; package-local
  `zig build` is not supported.
- `static_meta` stays intentionally narrow: runtime identity, stable identity
  opt-in, and a small caller-owned registry.
- The package has direct compile-time coverage plus one
  `static_testing.testing.model` suite for bounded runtime registry mutation
  and lookup sequences.
- The current closure record lives in
  `docs/plans/completed/static_meta_followup_closed_2026-03-31.md`.
- There is no package benchmark surface yet.

## Main surfaces

- `src/root.zig` exports the package API and documents the runtime-versus-stable
  identity split.
- `src/meta/type_name.zig` owns stable identity naming and version metadata.
- `src/meta/type_id.zig` owns deterministic type IDs.
- `src/meta/type_fingerprint.zig` owns runtime and stable fingerprint helpers.
- `src/meta/type_registry.zig` owns the bounded caller-provided registry.

## Validation

- `zig build check`
- `zig build test`
- `zig build examples`
- `zig build docs-lint`

## Key paths

- `tests/integration/root.zig` wires the package integration surface.
- `tests/integration/model_registry_runtime_sequences.zig` proves the bounded
  registry sequence behavior through `static_testing.testing.model`.
- `examples/type_id_basic.zig` shows runtime type-ID and fingerprint usage.
- `examples/type_registry_basic.zig` shows bounded registry construction and
  lookup.
- `docs/plans/completed/static_meta_followup_closed_2026-03-31.md` records the
  current closure posture and reopen triggers.

## Artifact notes

- No benchmark workflow is admitted yet.
- If runtime registry lookup or registration becomes hot enough to benchmark,
  keep the workload bounded and record the canonical artifact path here.
