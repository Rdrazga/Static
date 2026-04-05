# `static_rng`

Deterministic pseudo-random number engines and bounded sampling helpers for the `static` workspace.

## Current status

- The root workspace build is the supported entry point; package-local `zig build` is not supported.
- `static_rng` is intentionally curated around a small deterministic surface: `SplitMix64`, `Pcg32`, `Xoroshiro128Plus`, `DistributionError`, and `shuffleSlice`.
- Stream-lineage modeling and retained seed replay are already covered under `tests/integration/`.
- The package follow-up is closed; see `docs/plans/completed/static_rng_followup_closed_2026-04-01.md` for the current boundary notes and reopen triggers.

## Main surfaces

- `src/root.zig` exports the package facade.
- `src/rng/splitmix64.zig` owns seeding support.
- `src/rng/pcg32.zig` owns a small-state multi-stream generator.
- `src/rng/xoroshiro128plus.zig` owns the high-throughput generator surface.
- `src/rng/distributions.zig` owns bounded sampling helpers.
- `src/rng/shuffle.zig` owns slice shuffling.
- `tests/integration/root.zig` wires the package-level deterministic regression suite.
- `benchmarks/` owns the admitted generator-throughput and distribution/shuffle review workloads.
- `examples/` owns the bounded usage examples.

## Validation

- `zig build test`
- `zig build examples`
- `zig build bench`
- `zig build docs-lint`

Command intent:

- `zig build test` covers the package's deterministic regression surface.
- `zig build examples` keeps the usage examples buildable and bounded.
- `zig build bench` is the review surface for the admitted throughput workloads; benchmark outputs are informative rather than gating unless a workflow explicitly opts in.

## Key paths

- `src/root.zig`
- `tests/integration/root.zig`
- `tests/integration/model_stream_lineage.zig`
- `tests/integration/replay_retained_seed_failure_bundle.zig`
- `examples/pcg32_basic.zig`
- `examples/shuffle_basic.zig`
- `examples/xoroshiro_split_distributions.zig`
- `benchmarks/generator_next_throughput.zig`
- `benchmarks/distribution_shuffle_hotpaths.zig`
- `docs/plans/completed/static_rng_followup_closed_2026-04-01.md`

## Benchmark artifacts

- Benchmark outputs are produced through the root workspace bench flow under `.zig-cache/static_rng/benchmarks/<name>/`.
- Keep benchmark naming aligned with the admitted workloads rather than adding package-local artifact formats.
- Re-record baselines when a workload, sampling shape, or generator contract changes materially.
