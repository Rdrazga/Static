# `static_profile` package guide
Start here when you need to review, validate, or extend `static_profile`.

## Source of truth

- `README.md` for the package entry point and current status.
- `src/root.zig` for the exported surface.
- `tests/integration/root.zig` for the package-level deterministic regression
  surface.
- `docs/plans/completed/static_profile_followup_closed_2026-03-31.md` for the
  current closure posture and reopen triggers.
- `docs/plans/active/workspace_operations.md` for workspace priority and
  sequencing.
- `docs/architecture.md` for package boundaries and dependency direction.

## Supported commands

- `zig build test`
- `zig build examples`
- `zig build docs-lint`

## Working agreements

- Use the root `build.zig` as the supported validation surface.
- Keep `static_profile` focused on trace capture, counters, hooks, zones, and
  capability checks.
- Keep export formats explicit and bounded. Add new trace or counter surfaces
  only when the package has a concrete consumer and a documented export shape.
- Keep hooks package-local and zero-dependency for emitters; callers should
  wire integration at the top level.
- Keep benchmark work out of the package unless a real instrumentation-overhead
  review needs durable baselines.

## Package map

- `src/root.zig`: package root and export surface.
- `src/profile/trace.zig`: bounded trace capture and Chrome trace export.
- `src/profile/counter.zig`: counter event type and counter JSON export.
- `src/profile/hooks.zig`: zero-dependency counter emission helpers.
- `src/profile/zone.zig`: zone token type for begin/end pairing.
- `src/profile/caps.zig`: build-option mirror for capability gating.
- `tests/integration/`: package-level export-shape and lifecycle coverage.
- `examples/`: small usage examples for zone, counter, and hook emission.

## Change checklist

- Update `README.md`, `AGENTS.md`, and the relevant plan or closure record
  when package behavior or workflow changes.
- Extend `tests/integration/root.zig` when you add new first-class package
  integration coverage.
- Update root `README.md`, root `AGENTS.md`, and `docs/architecture.md` when
  package guidance or repository navigation changes.
