# `static_hash`

High-performance hashing, fingerprinting, and stable-hash utilities for the `static` workspace.

## Current status

- The root workspace build is the supported entry point; package-local `zig build` is not the supported validation surface.
- The package exports fast hash algorithms, checksums, type-aware hashing, combiners, fingerprints, stable hashing, and budgeted hashing controls.
- Package coverage includes combine invariants, streaming hasher modeling, and replay/fuzz invariants.
- Canonical benchmark review workloads cover byte hashing, combine, fingerprint, structural hashing, and quality samples.

## Main surfaces

- `src/root.zig` exports algorithm modules plus convenience wrappers.
- `src/hash/fnv1a.zig`, `src/hash/wyhash.zig`, `src/hash/xxhash3.zig`, `src/hash/siphash.zig`, and `src/hash/crc32.zig` own the core algorithms and checksums.
- `src/hash/combine.zig` owns ordered and unordered combiners.
- `src/hash/fingerprint.zig` owns fingerprint helpers.
- `src/hash/stable.zig` owns canonical cross-architecture stable hashing.
- `src/hash/hash_any.zig` owns generic hashing entry points.
- `src/hash/budget.zig` owns bounded-work controls for untrusted input.
- `tests/integration/root.zig` wires combine, streaming, and replay/fuzz proofs.
- `benchmarks/` owns shared benchmark baselines and history review.
- `examples/` owns usage samples for bytes, fingerprints, generic values, stable hashing, and SipHash.

## Validation

- `zig build test`
- `zig build examples`
- `zig build bench`
- `zig build docs-lint`

Command intent:

- Keep `zig build examples` as the place for runnable usage samples.
- Keep `zig build bench` review-only unless a benchmark workflow explicitly opts into gating.
- Treat benchmark comparisons as informative unless a workflow says otherwise.

## Key paths

- `tests/integration/combine_invariants.zig` covers combiners and composition invariants.
- `tests/integration/model_streaming_hashers.zig` covers streaming hasher behavior.
- `tests/integration/replay_fuzz_invariants.zig` covers retained malformed-input and replay cases.
- `tests/integration/seed_reducer_helpers.zig` supports replay and reduction workflows.
- `benchmarks/byte_hash_baselines.zig`, `benchmarks/combine_baselines.zig`, `benchmarks/fingerprint_baselines.zig`, `benchmarks/structural_hash_baselines.zig`, and `benchmarks/quality_samples.zig` define the canonical benchmark review surfaces.
- `benchmarks/support.zig` holds shared benchmark helper code and artifact naming.

## Benchmark artifacts

- Benchmark outputs live under `.zig-cache/static_hash/benchmarks/<name>/`.
- Canonical review artifacts use shared `baseline.zon` plus bounded binary history sidecars.
- Re-record baselines when workload shape, buffer sizing, or semantics change.
