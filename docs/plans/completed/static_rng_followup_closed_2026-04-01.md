# `static_rng` follow-up plan

Scope: deterministic random number generators and sampling helpers.

Status: follow-up closed on 2026-04-01. The root export/std-overlap review,
cross-architecture portability notes, and generator-versus-sampling boundary
review are all recorded, so no concrete package-local follow-up remains today.

## Current posture

- Keep `SplitMix64`, `Pcg32`, and `Xoroshiro128Plus` as the package-owned
  generator surface: they are the curated deterministic engines the package
  explicitly centers, and they serve distinct roles for seeding, small-state
  multi-stream work, and high-throughput simulation workloads.
- Keep `DistributionError` and `shuffleSlice` on the root surface: the error
  type is the narrow package-owned contract for bounded sampling helpers, and
  `shuffleSlice` is the one generator-adjacent convenience helper that is
  still clearer as a root-level entry point than as a submodule-only path.
- Cross-architecture note: the shipped generators use fixed-width wrapping
  integer arithmetic, shifts, and rotates only. They do not depend on
  endianness-sensitive byte reinterpretation, SIMD intrinsics, or target-
  feature-specialized fast paths, so the current scalar implementations remain
  the portability baseline unless future code introduces architecture-specific
  variants.
- Generator-versus-sampling boundary: keep raw engines in `splitmix64`,
  `pcg32`, and `xoroshiro128plus`; keep higher-level helpers in
  `distributions` and `shuffle`; keep the package root as a thin curated facade
  rather than growing broader random-toolkit aliases.

## Open follow-up triggers

- Reopen only if a new generator implementation introduces architecture-specific
- or target-feature-specific behavior that needs explicit reproducibility proof.
- Reopen the boundary review only if additional sampling helpers or convenience
  exports make the root surface less self-explanatory.
- Add new replay/model/benchmark work only if downstream consumers expose a
  concrete sequence, reproducibility, or hot-path gap beyond the current seed-
  lineage and benchmark surfaces.
