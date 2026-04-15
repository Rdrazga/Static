# `static_testing` benchmark history and environment metadata plan

## Goal

Make benchmark comparisons defensible across time by persisting bounded
environment, build, and run-history metadata next to baseline artifacts, while
moving append-only canonical history storage onto a shared binary record path.

## End-state design standard

- Assume benchmark review must remain defensible across machines, targets, and
  time without requiring a separate warehouse or ad hoc operator memory.
- The durable boundary is explicit bounded compatibility metadata and append-
  only run history that travel with the benchmark artifacts. It is not a
  dashboard, agent, or host-probing subsystem.
- Keep metadata explicit, portable, and caller-owned wherever possible so the
  long-lived comparison model stays stable without OS-specific feature growth.

## Validation

- Unit tests for metadata encode/decode and compatibility rules.
- One package-facing example that records baseline plus environment metadata.
- One downstream benchmark consumer that persists history metadata through the
  shared workflow.
- `zig build test`
- `zig build examples`

## Phases

### Phase 0: artifact boundary

- [x] Decide the minimum environment/build vocabulary: package, target,
  optimize mode, benchmark mode, timestamp, and optional caller-supplied host
  label.
- [x] Decide whether history stays as a sidecar artifact rather than folding
  into the baseline document.
- [x] Explicitly reject broad dashboard or warehousing work.

Implemented shape:

- `packages/static_testing/src/bench/history_binary.zig` now persists bounded
  binary `history.binlog` sidecars through the shared record-log helper rather
  than keeping append-only benchmark history on text encodings.
- The persisted metadata vocabulary is: package name, baseline path, target
  arch/os/abi, build mode, benchmark mode, timestamp, optional host label,
  optional environment note, bounded caller-supplied environment tags, and the
  recorded derived benchmark stats for that run.
- Compatibility matching for retained benchmark history now keys on package,
  baseline path, target/build tuple, benchmark mode, optional host label, and
  bounded environment tags; the environment note remains informational.
- Dashboard/server work remains explicitly out of scope.

### Phase 1: bounded metadata implementation

- [x] Add environment/build metadata to the shared benchmark workflow.
- [x] Persist one bounded history record per benchmark artifact update.
- [x] Keep history size bounded and caller-controlled.
- [x] Add plain-text summary output that shows the current comparison against
  the most recent compatible prior record.

Implemented in:

- `packages/static_testing/src/bench/workflow.zig`
- `packages/static_testing/examples/bench_baseline_compare.zig`
- `packages/static_sync/benchmarks/fast_paths.zig`

### Phase 2: review usefulness

- [x] Add compatibility filtering so incompatible targets/build modes are not
  compared as if they were equivalent.
- [x] Add one downstream package benchmark consumer beyond `static_sync` fast
  paths.
- [x] Add one helper for emitting machine-readable comparison metadata suitable
  for CI log scraping.
- [x] Move canonical history storage onto the shared binary append-only
  artifact boundary.

Current downstream consumers:

- `packages/static_sync/benchmarks/fast_paths.zig`
- `packages/static_sync/benchmarks/contention_baselines.zig`
- `packages/static_io/benchmarks/buffer_pool_checkout_return.zig`
- `packages/static_io/benchmarks/runtime_submit_complete_roundtrip.zig`
- `packages/static_queues/benchmarks/spsc_throughput.zig`
- `packages/static_queues/benchmarks/ring_buffer_throughput.zig`
- `packages/static_queues/benchmarks/disruptor_throughput.zig`
- `packages/static_memory/benchmarks/pool_alloc_free.zig`

Remaining design work:

- Keep widening package-suite adoption where benchmarks still use ad hoc
  reporting or package-local artifact handling.
- Decide whether any richer cross-machine metadata is still justified beyond
  the current host label, environment note, and bounded tag surface.
- Keep automatic CPU, governor, thermal, or machine-profile probing out of
  scope unless a bounded portable need becomes unavoidable; prefer explicit
  caller-supplied notes over platform-specific auto-detection.

### Phase 3: hardening

- [x] Move canonical history storage to a shared binary append-only record log.
- [x] Keep plain-text review summaries as derived output rather than canonical
  storage.
- [x] Add a bounded caller-supplied environment-tag surface for stronger
  cross-machine comparison when host label plus target/build metadata is not
  enough.
- [x] Keep the environment-tag surface explicit, caller-owned, and portable,
  with a bounded decode/encode surface and legacy compatibility preserved for
  earlier history records.
- [ ] Keep any richer environment metadata explicit, bounded, and caller-owned
  rather than adding platform-specific host introspection to `static_testing`.
- [ ] Keep dashboard/report server work out of scope.
