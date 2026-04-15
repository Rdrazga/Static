# `static_testing` benchmark baselines plan

Feature source:
`docs/sketches/archive/static_testing_feature_sketch_benchmark_baselines_2026-03-10.md`

## Goal

Add persisted benchmark baselines and explicit regression gating without
expanding `static_testing` into a broad benchmark-reporting framework, while
moving the canonical stored baseline format to `ZON` under the shared artifact
boundary.

## End-state design standard

- Assume unknown users need benchmark review artifacts that stay stable across
  teams, packages, and review cycles without inventing package-local compare
  wrappers.
- The durable boundary is a baseline and gating layer over existing benchmark
  measurements. It is not a new benchmark runner, dashboard engine, or broad
  analytics framework.
- Treat the canonical artifact shape, comparison semantics, and shared report
  output as long-lived review contracts now so later downstream migration does
  not require another artifact or threshold refactor.

## Validation

- Unit tests for baseline artifact encode/decode and comparison rules.
- One example that writes a baseline artifact and checks a new run against it.
- `zig build test`
- `zig build examples`

## Phases

### Phase 0: scope and format

- [x] Define the baseline artifact schema and version field.
- [x] Decide exact matching behavior for missing cases and new cases.
- [x] Decide whether median only or median plus tail percentiles are used for
  gating in the MVP.
- [x] Freeze the first consumer workflow: record baseline, compare new run,
  print plain-text summary, return machine-readable decision.

### Phase 1: current implementation

- [x] Add a `bench.baseline` module.
- [x] Implement a first version of baseline write/read helpers over derived
  stats only.
- [x] Implement a machine-readable compare result and explicit threshold config.
- [x] Add a plain-text summary helper for local and CI use.
- [x] Add one package-facing example that records and checks a bounded benchmark
  group without requiring a custom wrapper script.

### Phase 2: workflow hardening

- [x] Add per-case threshold overrides.
- [x] Add integration coverage for the file-backed baseline workflow and keep
  mismatch policy coverage in the `bench.baseline` unit tests.
- [x] Decide whether `zig build harness` should gain one narrow baseline-check
  entrypoint over the library API.
- [x] Add support for tagging unstable cases as informational rather than gating.

### Phase 3: canonical artifact migration

- [x] Move canonical baseline storage from JSON to `baseline.zon`.
- [x] Route baseline file/version handling through
  `docs/plans/completed/static_testing_artifact_formats_and_storage_2026-03-24.md`
  rather than leaving it as a bench-local encoder.
- [x] Keep baseline comparison logic schema-owned by `bench.baseline` while
  making future extraction of the storage helpers mechanical.

## Current status

- A first version of the artifact format is now implemented in
  `packages/static_testing/src/bench/baseline.zig`, and the canonical bounded
  document is now `baseline.zon`.
- The package-facing file workflow is exercised by
  `packages/static_testing/examples/bench_baseline_compare.zig`.
- The thin consumer workflow is now implemented in
  `packages/static_testing/src/bench/workflow.zig`.
- File-boundary round-trip coverage is in
  `packages/static_testing/tests/integration/bench_baseline_roundtrip.zig`.
- `zig build harness` now runs the baseline example as part of the deterministic
  harness smoke surface.
- `packages/static_sync/benchmarks/fast_paths.zig` is now the first real
  downstream benchmark suite using the shared workflow.
- `packages/static_io`, `packages/static_bits`, `packages/static_serial`,
  `packages/static_net`, `packages/static_net_native`, and `packages/static_string`
  now also use the same shared workflow, proving it across runtime,
  foundation, serialization, protocol, host-boundary adapter, and bounded text
  hot paths.
- `packages/static_testing/src/bench/baseline.zig` now also supports per-case
  threshold overrides and per-case regression decisions so unstable cases can be
  marked informational rather than gating.
- The shared workflow now also prints derived `ns/op`, `ops/s`, `p95`, and
  `p99` summaries by default through `packages/static_testing/src/bench/export.zig`
  and `packages/static_testing/src/bench/workflow.zig` rather than relying on
  package-local printers.
- `packages/static_testing/src/bench/baseline.zig` now also supports optional
  `p99` comparison/gating thresholds in the same shared compare surface, while
  still skipping that gate for legacy baselines that do not carry `p99`.
- Remaining work is broader downstream adoption plus one shared reporting
  hardening slice that real package suites now prove necessary:
  keep using the richer shared output and optional `p99` gating in more
  downstream suites before widening the benchmark API further.
- The right ownership for that reporting is `static_testing`, not package-local
  benchmark code. `static_io` and later adopters should consume a better shared
  report surface rather than cloning local formatting.
- Keep the base/default behavior small and review-oriented:
  print derived latency/throughput summaries by default,
  keep richer or domain-specific analytics behind explicit small report config,
  and avoid turning `bench.workflow` into a dashboard engine.

### Phase 4: report polish

- [x] Extend the shared text workflow to print derived `ns/op` and `ops/s`
  alongside the existing elapsed-sample report.
- [x] Add tail-latency reporting that includes `p95` and `p99` when the sample
  count and derived stats support those percentiles.
- [x] Keep the default report zero-config for common package review use, and
  add at most a small opt-in report config for extra derived analytics.
- [x] Reject package-specific counters at the library layer unless repeated
  downstream suites prove the same additional vocabulary is broadly reusable.
- [x] Add optional shared `p99` comparison/gating support without breaking
  legacy baselines that only carry earlier tail metrics.

### Phase 5: only if needed

- [ ] Evaluate a compact binary artifact only if `ZON` becomes a real bottleneck
  for bounded baseline documents.
- [ ] Reject HTML dashboards and broad statistics work unless justified by a
  separate plan.
