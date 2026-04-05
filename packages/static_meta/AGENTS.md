# `static_meta` package guide
Start here when you need to review, validate, or extend `static_meta`.

## Source of truth

- `README.md` for the package entry point and commands.
- `src/root.zig` for the exported surface and identity split.
- `tests/integration/root.zig` for the package regression surface.
- `docs/plans/completed/static_meta_followup_closed_2026-03-31.md` for the
  current closure posture and reopen triggers.
- `docs/plans/active/workspace_operations.md` for workspace priority and
  sequencing.
- `docs/architecture.md` for package boundaries and dependency direction.

## Supported commands

- `zig build check`
- `zig build test`
- `zig build examples`
- `zig build docs-lint`

## Working agreements

- Use the root `build.zig` as the supported validation surface.
- Keep runtime identity, stable identity opt-in, and the bounded registry
  contract narrow and allocation-free.
- Use `static_testing` only for deterministic mutation/lookup sequence proofs
  when direct tests are no longer enough.
- Keep package guidance aligned with the root docs and update this file when
  the package boundary or supported workflow changes.

## Package map

- `src/root.zig`: package root exports and package-level identity guidance.
- `src/meta/type_name.zig`: stable identity naming and version metadata.
- `src/meta/type_id.zig`: deterministic type IDs.
- `src/meta/type_fingerprint.zig`: runtime and stable fingerprint helpers.
- `src/meta/type_registry.zig`: bounded caller-provided registry.
- `tests/integration/root.zig`: package regression entry point.
- `tests/integration/model_registry_runtime_sequences.zig`: runtime registry
  sequence proof using `static_testing.testing.model`.
- `examples/type_id_basic.zig`: basic type-ID and fingerprint example.
- `examples/type_registry_basic.zig`: bounded registry construction example.

## Change checklist

- Update `README.md`, `AGENTS.md`, and the relevant plan or closure record when
  package behavior or workflow changes.
- Extend `tests/integration/root.zig` when you add new first-class package
  regression coverage.
- Add or refresh package examples when a public surface needs a canonical
  usage path.
- Update root `README.md`, root `AGENTS.md`, and `docs/architecture.md` when
  package guidance or repository navigation changes.
