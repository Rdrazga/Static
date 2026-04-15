# `static_testing` replay failure bundles plan

Feature source:
`docs/sketches/archive/static_testing_feature_sketch_replay_failure_bundle_2026-03-10.md`

## Goal

Evolve replay artifacts into richer failure bundles that capture enough bounded
context to debug deterministic failures without rerunning immediately, while
shifting bounded structured sidecars away from JSON and onto the shared
artifact-format policy, without forcing every caller to emit the same retained
artifact set.

## End-state design standard

- Assume failure bundles are the canonical retained-debug surface for unknown
  users who need to triage deterministic failures locally or in CI without
  immediately rerunning the scenario.
- The durable boundary is a bounded replay-first bundle with explicit optional
  sidecars for trace and diagnostics. It is not a generic crash-dump format or
  an always-on logging sink.
- Keep replay payloads, manifests, violations, and optional retained detail on
  one stable contract so model, sim, swarm, and system workflows can all reuse
  the same failure bundle shape without forking retention logic later.

## Validation

- Unit tests for bundle encode/decode and manifest compatibility.
- Integration tests for bundle persistence and replay-artifact coexistence.
- `zig build test`
- `zig build harness`

## Phases

### Phase 0: compatibility and format

- [x] Define the directory-bundle MVP layout and manifest schema.
- [x] Define compatibility between phase-1 replay artifacts and bundles.
- [x] Decide which optional payloads are excluded from the MVP.

### Phase 1: MVP

- [x] Emit a directory bundle with manifest, binary artifact, trace summary,
  and checker violations.
- [x] Keep corpus naming stable and deterministic.
- [x] Add read/decode helpers for tooling and tests.

### Phase 2: bounded richness

- [x] Add optional checkpoint digests.
- [x] Add optional bounded stdout/stderr capture for process-driver cases.
- [x] Add runner-facing manifest fields for swarm campaign profile, scenario
  selection, and seed lineage.
- [x] Add integration coverage for roundtrip and storage behavior.

### Phase 3: canonical artifact cleanup

- [x] Move bounded structured sidecars such as manifest, trace summary, and
  violations to `ZON` (`manifest.zon`, `trace.zon`, `violations.zon`).
- [x] Route bundle file naming/versioning through the shared artifact boundary
  from
  `docs/plans/completed/static_testing_artifact_formats_and_storage_2026-03-24.md`.
- [x] Reassess retained trace output so the current bounded trace-summary
  document remains the right canonical artifact once richer provenance tracing
  lands.
- [x] Add caller-controlled bundle artifact selection so workflows can choose
  summary-only bundles, summary-plus-retained-trace bundles, or minimal replay
  retention without cloning bundle code.

Current direction:

- `writeFailureBundle()` should always remain explicit caller-owned persistence,
  not a hidden global artifact sink.
- `replay.bin`, `manifest.zon`, and `violations.zon` remain the default failure
  bundle core.
- trace retention is now the first caller-selected branch: callers should be
  able to emit no trace artifact, the bounded `trace.zon` summary, and later a
  richer retained binary trace sidecar when that exists.
- richer retained traces should add to the bundle contract via explicit policy,
  not by silently inflating every bundle.
- the current bounded `trace.zon` summary remains the canonical summary
  document, while optional `trace_events.binlog` remains the richer retained
  trace path when callers need deeper event detail.
- repair/liveness convergence blockers should remain in the canonical bundle
  contract as optional typed `manifest.zon` metadata, not as a new sidecar and
  not only as free-form violation-message text.

Remaining design work:

- Keep process-driver stdout absent because stdout remains reserved for protocol
  framing in the current driver contract.
- Treat further work here as hardening and cross-surface quality, not as a
  missing core bundle feature.

### Phase 4: only if needed

- [ ] Consider a hybrid or single-file artifact if CI upload friction is real.
- [ ] Keep viewer work out of scope unless justified by a new plan.
