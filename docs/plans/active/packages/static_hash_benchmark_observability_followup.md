# `static_hash` benchmark observability follow-up

Scope: tighten the benchmark-side `ReleaseFast` contract and review artifact
surface in `static_hash` where the dependency review found concrete gaps.

## Review focus

- No exported-library allocator or hot-path invariant leak was validated in
  `static_hash/src/hash/*`.
- The concrete issues are benchmark-surface problems:
  `ReleaseFast` benchmark entrypoints still run expensive semantic helpers
  unconditionally before timing, and `quality_samples` still lacks shared
  baseline/history artifacts.
- This follow-up stays benchmark-focused and does not reopen the separate
  algorithm-portfolio or batch-shape plans.

## Current state

- Several canonical benchmark owners already exist for byte, combine,
  fingerprint, and structural hashing.
- `quality_samples.zig` still prints summaries directly instead of persisting
  a reviewable artifact set.
- Downstream packages cannot compare bias, collision, or avalanche posture over
  time through the shared benchmark workflow.

## Approved direction

- Treat the benchmark entrypoint preflight issue and `quality_samples`
  observability gap as concrete active work now.
- Keep budgeted structural hashing benchmark expansion deferred unless a
  downstream hot-path need appears.
- Do not mix this slice with new hash-algorithm admission work.

## Ordered SMART tasks

1. `Benchmark preflight gating`
   Make the expensive semantic benchmark preflights debug/safety-only so
   `ReleaseFast` benchmark entrypoints do not keep doing untimed whole-input
   traversals by default.
   Done when:
   - the affected benchmark mains gate those helpers on runtime safety or an
     equivalent compile-time debug-only path;
   - `ReleaseFast` benchmark output remains unchanged except for the removed
     preflight cost;
   - semantic checks still exist for debug/safe benchmark runs.
   Validation:
   - `zig build bench`
2. `Quality-samples artifact admission`
   Move `quality_samples` onto the shared bounded artifact workflow or document
   an explicit rejection if stdout-only output remains intentional.
   Done when:
   - `quality_samples` either writes shared `baseline.zon` plus `history.binlog`
     artifacts with explicit comparison fields, or the docs are updated to say
     it is intentionally not a canonical review owner;
   - README / AGENTS reflect the accepted posture.
   Validation:
   - `zig build bench`
   - `zig build docs-lint`

## Ideal state

- `static_hash` benchmark entrypoints are truthful in `ReleaseFast`.
- Quality and bias regressions are reviewable through the same shared artifact
  contract as the package's other benchmark owners.
- Algorithm-portfolio work stays isolated from this observability slice.
