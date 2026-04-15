# `static_testing` causality and provenance tracing plan

## Goal

Extend deterministic tracing so runs can explain not only what happened, but
what event, action, or decision caused each subsequent action, while leaving it
to callers to choose whether they want only bounded summaries, richer retained
trace artifacts, or both.

## End-state design standard

- Assume deterministic review must answer both what happened and why it
  happened across model, sim, exploration, swarm, and system surfaces.
- The durable boundary is a bounded provenance model that flows through the
  same retained artifact system as the rest of `static_testing`; it is not an
  observability platform or distributed tracing system.
- Keep provenance caller-selectable and storage-aware so short local runs,
  CI triage, and long deterministic campaigns can all use the same trace
  vocabulary without being forced into one retention cost profile.

## Validation

- Unit tests for lineage encoding and bounded storage behavior.
- One simulation example that emits causal links across scheduled actions.
- One integration test that persists provenance through a failure bundle.
- `zig build test`
- `zig build examples`
- `zig build harness`

## Phases

### Phase 0: causal model

- [x] Define the minimal lineage vocabulary: cause id, parent event/action id,
  run-local correlation id, and optional surface label.
- [x] Decide how provenance extends the current trace event format without
  breaking deterministic bounded storage.
- [x] Keep the first version single-run and local; reject distributed tracing
  scope.

### Phase 1: trace extension

- [x] Extend trace events or companion metadata with bounded causal links.
- [x] Add formatting helpers that summarize causal chains in deterministic text.
- [x] Add one failure-bundle path that preserves causal metadata.

## Current status

- `packages/static_testing/src/testing/trace.zig` now supports optional bounded
  lineage on each trace event: cause sequence, correlation id, and surface
  label.
- `TraceSnapshot.provenanceSummary()` now derives bounded causal summary data,
  and `TraceSnapshot.writeCausalityText()` now emits deterministic plain-text
  chain summaries.
- `packages/static_testing/src/testing/failure_bundle.zig` now preserves a
  bounded provenance summary in `trace.zon` when callers provide one through
  `FailureBundleContext.trace_provenance_summary`.
- `packages/static_testing/src/testing/trace.zig` now also supports a shared
  binary retained-trace sidecar format, and
  `packages/static_testing/src/testing/failure_bundle.zig` can now persist an
  optional `trace_events.binlog` sidecar when callers select retained trace
  artifacts and provide a `TraceSnapshot`.
- `packages/static_testing/examples/sim_timer_mailbox.zig` now demonstrates one
  simulation flow that emits causal links from scheduler decisions into mailbox
  handoff actions.
- `packages/static_testing/examples/model_sim_fixture.zig` and
  `packages/static_testing/tests/integration/model_sim_fixture_roundtrip.zig`
  now prove the package-owned model path can drive a real
  `testing.sim.fixture`, retain provenance through a failure bundle plus
  `actions.zon`, and replay the same sim-backed action trace.
- `packages/static_scheduling/tests/integration/replay_explore_timer_queue_provenance.zig`
  now proves the downstream retained-exploration path for timer-queue failures:
  schedule mode and seed are retained, recorded decisions round-trip through
  `exploration_failures.binlog`, and replay reproduces the chosen decision
  stream after the causal chain has been validated.
- Remaining work is now broader downstream adoption and on deciding whether the
  current retained-trace sidecar should stay sufficient for long-run campaign
  use.

### Phase 2: cross-surface integration

- [x] Integrate provenance with `testing.model`.
- [x] Integrate provenance with `testing.sim.fixture` consumers.
- [x] Integrate provenance with `testing.sim.explore` retained failures.
- [x] Integrate provenance with `swarm_runner` summaries and retained failures.
- [x] Add a caller-controlled retained-trace policy so bundle/sim/swarm/model
  users can choose among summary-only, richer retained binary trace sidecars,
  both, or no retained trace artifact.
- [x] Keep the first richer retained-trace artifact binary and shared-boundary
  based rather than turning `trace.zon` into a full event dump.

### Phase 3: only if justified

- [ ] Consider grouped/span-like summaries if causal chains become noisy.
- [ ] Keep hosted trace viewers and broad telemetry systems out of scope.

## Current direction

- `trace.zon` remains the bounded canonical summary surface for failure bundles.
- The next retained-trace expansion, when implemented, should be an optional
  shared binary sidecar for richer event/causal retention, not a mandatory
  replacement for the summary document.
- Callers should decide which retained trace artifacts they emit so short test
  flows, CI review paths, and long-running simulations can choose different
  storage/debug tradeoffs without forking framework code.
- `testing.model` now carries provenance summaries and optional retained trace
  snapshots through failed-case replay and failure-bundle persistence when the
  target exposes trace callbacks.
- `testing.sim.fixture` now exposes `traceSnapshot()` and
  `traceProvenanceSummary()`, and the deterministic swarm simulation flow now
  persists both bounded summary and retained-trace sidecars from that surface.
- `testing.sim.explore` retained failure records now also carry optional trace
  metadata plus bounded provenance summaries, so metadata-only reads and
  persisted decision-stream replays can keep causal context without requiring a
  full retained-trace sidecar.
- The first downstream retained-exploration provenance proof now exists in
  `static_scheduling` and validates that those retained records remain replayable
  after the causal chain is checked.
- `testing.system` already retains shared trace provenance through its bundle
  path, so the remaining provenance work is now downstream adoption and
  deciding whether long-run campaign tooling needs more than the current
  bounded summary plus retained-sidecar split.
