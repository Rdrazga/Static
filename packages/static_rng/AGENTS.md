# `static_rng` package guide
Start here when you need to review, validate, or extend `static_rng`.

## Source of truth

- `README.md` for the package entry point and current scope.
- `src/root.zig` for the exported surface.
- `tests/integration/root.zig` for the package-level deterministic regression surface.
- `benchmarks/` for the admitted benchmark review workloads.
- `examples/` for bounded usage examples.
- `docs/plans/completed/static_rng_followup_closed_2026-04-01.md` for the current closure posture.
- `docs/plans/active/workspace_operations.md` for workspace priority and sequencing.
- `docs/architecture.md` for package boundaries and dependency direction.

## Supported commands

- `zig build test`
- `zig build examples`
- `zig build bench`
- `zig build docs-lint`

Command intent:

- Keep `zig build bench` as the review surface for the admitted throughput and hot-path workloads.
- Keep examples bounded and deterministic; retain them as usage entry points, not feature dumps.
- Do not add a package-local harness command unless the package later owns an explicit smoke surface.

## Working agreements

- Keep the package centered on deterministic engines and bounded sampling helpers.
- Treat `SplitMix64` as the seeding helper, not a general-purpose generator surface.
- Keep `Pcg32`, `Xoroshiro128Plus`, `DistributionError`, and `shuffleSlice` on the curated root surface.
- Keep seeds, stream selectors, and replay inputs explicit in tests and examples.
- Avoid cryptographic or globally shared RNG semantics.
- Use `static_testing` only where deterministic replay, model coverage, or shared benchmark review is the right fit.

## Package map

- `src/rng/splitmix64.zig`: seeding helper.
- `src/rng/pcg32.zig`: small-state deterministic generator.
- `src/rng/xoroshiro128plus.zig`: high-throughput deterministic generator.
- `src/rng/distributions.zig`: bounded sampling helpers and distribution errors.
- `src/rng/shuffle.zig`: slice shuffling helper.
- `tests/integration/`: stream-lineage modeling and retained seed replay coverage.
- `examples/`: bounded usage examples for the exported generators and helpers.
- `benchmarks/`: generator throughput and distribution/shuffle hot-path review workloads.

## Change checklist

- Update `README.md`, `AGENTS.md`, and the relevant plan or closure record when package behavior changes.
- Extend `tests/integration/root.zig` when adding a new first-class regression surface.
- Update `examples/` or `benchmarks/` when a public surface needs a canonical usage or review path.
- Update root `README.md`, root `AGENTS.md`, and `docs/architecture.md` when package guidance or navigation changes.
