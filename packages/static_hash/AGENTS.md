# `static_hash` package guide
Start here when you need to review, validate, or extend `static_hash`.

## Source of truth

- `README.md` for the package entry point and commands.
- `src/root.zig` for the exported surface.
- `tests/integration/root.zig` for the package-level deterministic regression surface.
- `benchmarks/` for canonical benchmark entry points and artifact names.
- `docs/plans/active/workspace_operations.md` for workspace priority and sequencing.
- `docs/architecture.md` for package boundaries and dependency direction.

## Supported commands

- `zig build test`
- `zig build examples`
- `zig build bench`
- `zig build docs-lint`

Command intent:

- Use the root workspace build as the supported validation surface; standalone `zig build` from this directory is not the supported entry point.
- Keep `zig build bench` review-only unless a workflow explicitly opts into gating.
- Keep benchmark review artifacts on shared `baseline.zon` plus bounded binary history sidecars.

## Working agreements

- Keep hashing, fingerprinting, combiners, stable hashing, and budgeted hashing package-local.
- Prefer `static_testing` when a change needs replay, fuzz, modeling, or benchmark review support.
- Keep deterministic examples and benchmark workloads bounded and explicit.
- Add doc comments when an exported algorithm or contract changes and the behavior is not obvious from the name.

## Package map

- `src/root.zig` exports algorithm modules and convenience wrappers.
- `src/hash/fnv1a.zig`, `src/hash/wyhash.zig`, `src/hash/xxhash3.zig`, `src/hash/siphash.zig`, and `src/hash/crc32.zig` own the core algorithms and checksums.
- `src/hash/combine.zig` owns ordered and unordered combiners.
- `src/hash/fingerprint.zig` owns fingerprint helpers.
- `src/hash/stable.zig` owns canonical cross-architecture stable hashing.
- `src/hash/hash_any.zig` owns generic type-aware hashing.
- `src/hash/budget.zig` owns bounded-work controls for untrusted input.
- `tests/integration/` owns combine, streaming, and replay/fuzz proofs.
- `benchmarks/` owns canonical review workloads and shared benchmark helpers.
- `examples/` owns bounded user-facing usage samples.

## Change checklist

- Update `README.md`, `AGENTS.md`, and any relevant plan or decision doc when package behavior or workflow changes.
- Extend `tests/integration/root.zig` when adding new first-class regression coverage.
- Re-record benchmark baselines when workload shape or semantics change.
- Update root `README.md`, root `AGENTS.md`, and `docs/architecture.md` when package guidance or repository navigation changes.
