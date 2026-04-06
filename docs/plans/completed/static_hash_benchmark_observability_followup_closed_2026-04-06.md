# `static_hash` benchmark observability follow-up

Scope: close the 2026-04-06 reopen that validated benchmark-only semantic
preflight cost leaking into `ReleaseFast` runs and the missing shared artifact
surface for `quality_samples`.

Status: follow-up closed on 2026-04-06. The benchmark semantic preflights now
stay safety-mode-only, and `quality_samples` now records canonical review
artifacts through the shared benchmark workflow.

## Validated issue scope

- The canonical `static_hash` benchmark entrypoints still ran expensive
  semantic preflight helpers even when runtime safety was off, polluting
  `ReleaseFast` timing.
- `quality_samples.zig` only printed human-readable output and did not emit the
  shared `baseline.zon` plus `history.binlog` artifact pair.

## Implemented fixes

- The benchmark semantic preflights in
  [byte_hash_baselines.zig](/C:/Users/ryan/Desktop/Forbin%20Solutions/Library%20Dev/static/packages/static_hash/benchmarks/byte_hash_baselines.zig),
  [combine_baselines.zig](/C:/Users/ryan/Desktop/Forbin%20Solutions/Library%20Dev/static/packages/static_hash/benchmarks/combine_baselines.zig),
  [fingerprint_baselines.zig](/C:/Users/ryan/Desktop/Forbin%20Solutions/Library%20Dev/static/packages/static_hash/benchmarks/fingerprint_baselines.zig),
  and
  [structural_hash_baselines.zig](/C:/Users/ryan/Desktop/Forbin%20Solutions/Library%20Dev/static/packages/static_hash/benchmarks/structural_hash_baselines.zig)
  now short-circuit when `std.debug.runtime_safety` is off.
- [quality_samples.zig](/C:/Users/ryan/Desktop/Forbin%20Solutions/Library%20Dev/static/packages/static_hash/benchmarks/quality_samples.zig)
  now exports its bounded quality metrics through the shared benchmark
  workflow, recording `baseline.zon` and `history.binlog` while retaining the
  human-readable stdout summary.
- The shared helper in
  [support.zig](/C:/Users/ryan/Desktop/Forbin%20Solutions/Library%20Dev/static/packages/static_hash/benchmarks/support.zig)
  now accepts a report-config parameter so `quality_samples` can suppress
  irrelevant sample-detail text while still writing canonical artifacts.
- Root bench wiring now exposes a named `static_hash_quality_samples` step.
- Package docs now describe the new artifact posture.

## Proof posture

- `zig build check`
- `zig build static_hash_quality_samples`
- `zig build bench`
- `zig build docs-lint`

## Current posture

- `ReleaseFast` benchmark timing for the canonical `static_hash` owners no
  longer includes the old semantic preflight tax.
- `quality_samples` is now longitudinally observable through the same shared
  benchmark review workflow as the other admitted `static_hash` owners.

## Reopen triggers

- Reopen if benchmark semantic preflights start executing again in
  non-runtime-safety builds.
- Reopen if `quality_samples` needs stronger pass/fail semantics than the
  current review-only artifact posture.
