# `static_ecs` benchmark and testing review

Date: 2026-04-11

Scope: review the current `static_ecs` benchmarking and testing suites against
two stricter assumptions:

1. the benchmark suite should expose likely ECS performance hangups clearly and
   truthfully;
2. the test suite should push hard on fault injection, malformed input,
   pressure, unstable runtime assumptions, and failure surfaces rather than
   staying near deterministic happy-path proof only.

This is a sketch review. It records the current posture, the main strengths,
the main blind spots, and a concrete follow-up direction. It is not a request
to broaden package scope beyond the current world-local typed ECS boundary.

## Review method

- Read the workspace and package guidance:
  `README.md`, `docs/architecture.md`, `docs/plans/active/README.md`,
  `docs/plans/active/workspace_operations.md`,
  `packages/static_ecs/README.md`, and `packages/static_ecs/AGENTS.md`.
- Read the closed ECS benchmark follow-up records under
  `docs/plans/completed/`.
- Read the current ECS benchmark owners under `packages/static_ecs/benchmarks/`.
- Read the ECS integration, compile-fail, and in-module tests under
  `packages/static_ecs/tests/` and `packages/static_ecs/src/ecs/`.
- Run the supported validation surfaces that are relevant to the review:
  `zig build check`, `zig build test`, `zig build query_iteration_baselines`,
  `zig build command_buffer_apply_only_baselines`, and
  `zig build allocator_strategy_baselines`.

## Validation notes

- `zig build check` passed.
- `zig build test` did not complete cleanly on this machine, but the failure
  was outside `static_ecs`: `packages/static_sync/tests/integration/host_wait_smoke.zig`
  hit a timeout and then a child-thread segfault while waiting for a host wait
  handshake. That means the root pass/fail surface could not be used as an
  ECS-only certification signal for this review.
- The directly invoked ECS benchmark owners completed and produced reports:
  `query_iteration_baselines`, `command_buffer_apply_only_baselines`, and
  `allocator_strategy_baselines`.
- `zig build bench` remains a review-only aggregate surface. During this review
  it emitted non-ECS regressions elsewhere in the workspace, which is expected
  behavior for that command and not itself an ECS defect.

## Current benchmark posture

The current benchmark suite is broad by package standards and already avoids
several common benchmark mistakes.

Strengths:

- The suite is split into distinct workload families instead of one blended ECS
  benchmark:
  `query_iteration_baselines`, `query_scale_baselines`,
  `query_startup_baselines`, `structural_churn_baselines`,
  `command_buffer_staged_apply_baselines`,
  `command_buffer_phase_baselines`,
  `command_buffer_apply_only_baselines`,
  `micro_hotpaths_baselines`, `frame_pass_baselines`,
  `frame_workload_baselines`, and `allocator_strategy_baselines`.
- Several attribution problems were already corrected in earlier follow-ups and
  stay fixed in the current code:
  release-style build truthfulness, staged-apply naming, apply-only timing via
  benchmark prepare hooks, and bounded rerun budgets.
- Benchmark cases run deterministic semantic preflights before timing starts.
  The benchmark code checks expected entity counts, archetype counts, matching
  row counts, and representative postconditions before the real run.
- History and baseline artifacts use the shared `static_testing` workflow with
  bounded environment tags and release-fast metadata, which keeps comparison
  output consistent with the rest of the repo.

That said, the suite still falls short of the stronger requirement in this
review.

## Benchmark findings

### 1. The suite measures elapsed time well, but it does not expose enough of the memory and structural reasons behind that time

Evidence:

- The benchmark owners mainly report `ns/op`, `ops/s`, and tail latency through
  the shared workflow.
- The ECS cases assert expected entity and archetype counts, but they do not
  emit chunk occupancy, retained-empty-chunk counts, bytes allocated, bytes
  copied during row relocation, archetype creation count, chunk reuse count, or
  bundle payload bytes processed.

Impact:

- A slowdown can be detected, but the suite often cannot explain whether the
  cause is extra allocations, worse chunk fill, more archetype splits, more row
  copies, or more query startup scanning.
- This is acceptable for coarse regression review, but not for the stated goal
  of exposing "what is taking more time than it likely should."

### 2. The benchmark matrix is strong on query and command-buffer attribution, but weak on memory-shape and capacity-edge workloads

Covered well:

- dense versus fragmented query iteration;
- query startup versus full scan;
- spawn-heavy, insert-heavy, and mixed command-buffer apply;
- setup-only, stage-only, and apply-only command-buffer attribution;
- scalar versus fused bundle structural churn;
- frame-like pass mixes and branch-heavy versus write-heavy workloads;
- page allocator versus slab allocator on typed versus encoded bundle paths.

Missing or too shallow:

- near-capacity worlds where `entities_max`, `archetypes_max`, `chunks_max`, or
  `components_per_archetype_max` are approached aggressively;
- chunk fill-ratio sweeps, including low-occupancy and churn-heavy retained
  empty-chunk cases;
- despawn-heavy workloads and add/remove thrash that repeatedly create and
  collapse archetypes;
- explicit row-relocation copy pressure benchmarks;
- world init/deinit/reset benchmarks;
- bundle-size scaling benchmarks over small, medium, and very large payloads;
- config sweeps over `chunk_rows_max` and `empty_chunk_retained_max`.

Impact:

- The suite is much better at exposing ECS read-path and command-buffer issues
  than it is at exposing memory-shape pathologies and capacity cliffs.

### 3. The suite is intentionally single-threaded and world-local, which is truthful for package scope, but it leaves whole classes of likely production hangups invisible

Evidence:

- All current ECS benchmark owners operate on one world in one thread.
- There is no benchmark owner for concurrent readers, external synchronization
  overhead, false sharing around caller-owned orchestration, or multi-world
  throughput.

Impact:

- This is not a package-boundary bug. It is the correct narrow ownership for
  `static_ecs`.
- It does mean the suite cannot honestly claim to capture all potential ECS
  performance hangups in a broader engine/runtime sense.

### 4. Some of the micro/startup cases are now so small that they are better as tripwires than as explanatory performance models

Evidence:

- `micro_hotpaths_baselines` and `query_startup_baselines` land in very small
  ranges on this machine.
- The package already acknowledges this indirectly by using higher iteration
  counts and by keeping larger end-to-end owners alongside the micro cases.

Impact:

- These owners are useful for catching obvious regressions and validating
  experiments such as invariant-walk removal.
- They should not be treated as sufficient evidence for broader ECS behavior,
  cache pressure, or allocator cost.

### 5. The allocator strategy benchmark is useful, but still narrow

Evidence:

- `allocator_strategy_baselines` compares only page allocator versus slab, and
  only on typed or encoded spawn-plus-despawn loops.

Impact:

- It answers one important question well: the caller-supplied allocator
  boundary is observable and matters.
- It does not yet cover longer-lived worlds, chunk reuse, command-buffer
  control-plane cost, budget-tracked allocators, or failing allocators.

## Current testing posture

The test suite is robust for deterministic API-contract proof, but it is not
yet robust for hostile-environment or aggressive fault-injection work.

Strengths:

- There is real layering in the test surface:
  in-module tests in `src/ecs/*.zig`, integration tests under
  `tests/integration/`, compile-fail fixtures under `tests/compile_fail/`, and
  one `static_testing.testing.model` sequence proof.
- The package directly proves several non-trivial contracts:
  bundle-codec malformed input rejection, command-buffer payload rollback,
  large bundle handling, entity reuse semantics, stale-entity rejection,
  compile-time generic misuse, and fail-fast view invalidation after structural
  mutation.
- The suite includes both stable operating-error proof and crash-style child
  process proof for borrowed-view invalidation.

The weaker side is breadth under failure pressure.

## Testing findings

### 6. ECS uses `static_testing` only narrowly; most of the shared hostile-testing surface is currently unused

Observed usage:

- one `testing.model` sequence test in
  `tests/integration/command_buffer_runtime_sequences.zig`;
- shared benchmark workflow under `benchmarks/`.

Not observed anywhere under `packages/static_ecs/**/*.zig`:

- replay workflows;
- fuzz workflows;
- retained failure bundles;
- `testing.sim`;
- `testing.system`;
- `testing.swarm`;
- temporal assertions or liveness helpers.

Impact:

- The package has deterministic proof, but not adversarial exploration.
- Relative to the stated requirement, this is the single biggest testing gap.

### 7. Fault injection is present for malformed encoded bundles, but not generalized beyond a small hand-built matrix

Evidence:

- `tests/integration/encoded_bundle_runtime.zig` and
  `src/ecs/bundle_codec.zig` cover truncated data, bad component ids, bad
  payload sizes, duplicate ids, unsorted ids, misaligned caller slices, and
  foreign-entity rejection.

Gap:

- The malformed input space is still hand-authored and finite.
- There is no fuzzing or replay corpus for encoded bundles, archetype keys,
  entity mutation sequences, or command-buffer payload layout.

Impact:

- The encoded route has better negative-path coverage than the rest of ECS.
- It still does not approximate the review requirement of "robust fault
  injection" under malformed or surprising data.

### 8. Pressure and bound testing exists, but it is selective rather than systematic

Covered:

- `chunk.setRowCount()` above capacity;
- `EntityPool` exhaustion;
- command-buffer payload and entry rollback on failed staging;
- one world-init budget cleanup path.

Missing or weak:

- systematic `NoSpaceLeft` proof around `entities_max`, `archetypes_max`,
  `chunks_max`, and `empty_chunk_retained_max` under runtime churn;
- randomized near-capacity mutation sequences;
- command-buffer saturation sequences beyond the small fixed model world;
- world-level and archetype-store-level budget denial matrices;
- large-volume repeated insert/remove/despawn sequences at or near hard bounds.

Impact:

- The suite proves a few representative edge conditions.
- It does not yet prove that the whole ECS stays stable when every bound is
  exercised hard and repeatedly.

### 9. The model-based proof is valuable but too narrow to represent overall ECS correctness

Evidence:

- `tests/integration/command_buffer_runtime_sequences.zig` uses
  `static_testing.testing.model` over a three-slot, eight-command world and
  focuses on command-buffer alignment with a shadow model.

Impact:

- This is a good first model target.
- It does not cover archetype relocation, chunk retention/reuse, query/view
  consistency after many structural transitions, encoded bundle staging, stale
  entity reuse under heavier churn, or hard-bound exhaustion behavior.

### 10. There is effectively no allocator-failure injection inside the main ECS mutation paths

Evidence:

- The code has explicit allocator- and budget-sensitive paths in
  `chunk.zig`, `archetype_store.zig`, `command_buffer.zig`, and `world.zig`.
- The tests do not drive those surfaces with a failing allocator matrix.
- The only meaningful budget-failure proof found in ECS-local tests is the
  world-init reservation cleanup case in `src/ecs/world.zig`.

Impact:

- The current suite cannot answer whether partial allocation failures during
  archetype creation, chunk growth, command staging, or bundle application
  leave the world in a clean and recoverable state.

### 11. The suite does not address unstable runtime assumptions of the sort named in this review

Not covered:

- allocator instability beyond one init-time budget failure;
- memory corruption or data-bit flips outside the encoded-bundle parsing path;
- OS scheduling instability, clock variance, or host-thread disturbance;
- partial process failure or retained crash reproduction;
- CPU- or build-mode-sensitive invariant drift outside the normal debug versus
  release-fast benchmark comparison posture.

Impact:

- Some of these are intentionally outside package scope.
- Even within package scope, the current suite is still much closer to
  deterministic contract proof than to hostile-environment stress testing.

### 12. Compile-fail and runtime invalidation proof are good, but still focused on a narrow front door

Evidence:

- The compile-fail suite covers six fixture classes.
- The child-process invalidation suite covers two panic cases:
  invalidated `ChunkBatch` access and invalidated iterator advance.

Impact:

- These are useful, durable tests.
- They do not broaden into a wider misuse matrix for query/write aliasing,
  repeated invalid access patterns, or broader public-surface generic misuse.

## Overall assessment

If the standard is "good package-local ECS proof for a first typed world-local
implementation," the current `static_ecs` suites are in respectable shape.

If the standard is the one used in this review, the result is mixed:

- the benchmark suite is already broad, disciplined, and much better than a
  typical microbenchmark-only setup, but it still lacks the structural and
  memory-shape observability needed to explain many performance failures;
- the testing suite is solid for deterministic contract verification, but it is
  not yet a robust hostile-input or hostile-runtime suite.

Short version:

- benchmarks: good breadth, incomplete observability;
- tests: good contract proof, insufficient adversarial depth.

## Recommended follow-up order

### Benchmark follow-ups

1. Add structural observability to ECS benchmark reports.
   Minimum additions: chunk count, archetype count, retained-empty-chunk count,
   average chunk fill, and optionally allocation count or bytes moved when the
   benchmark owner can report them cheaply and truthfully.
2. Add capacity-edge benchmark owners.
   First candidates: near-`chunks_max` churn, near-`archetypes_max` archetype
   explosion, chunk-retention reuse versus no-retention, and bundle-size
   scaling.
3. Add despawn-heavy and relocation-heavy workloads.
   The current suite is much stronger on read and insert paths than on removal
   and collapse behavior.
4. Expand allocator strategy review.
   Compare page, slab, and budget-tracked allocation on longer-lived worlds and
   command-buffer-heavy loops, not only spawn-plus-despawn.

### Testing follow-ups

1. Add retained malformed-bundle replay/fuzz coverage using `static_testing`.
   This is the cleanest next step because ECS already has a defined encoded
   boundary with stable operating errors.
2. Add a failing-allocator matrix for ECS-local mutation paths.
   Priority targets: archetype creation, chunk creation, command-buffer bundle
   staging, world bundle admission, and row relocation.
3. Expand model-based testing beyond command buffers.
   Priority targets: world structural mutation sequences, entity reuse/stale-id
   behavior under churn, and chunk retention/reuse.
4. Add pressure suites for every explicit world bound.
   At minimum: `entities_max`, `archetypes_max`, `chunks_max`,
   `command_buffer_entries_max`, `command_buffer_payload_bytes_max`, and
   `empty_chunk_retained_max`.
5. Add retained failure artifacts for the new adversarial campaigns.
   If ECS starts using replay/fuzz/model more heavily, the package should keep
   the resulting failures reproducible through the shared `static_testing`
   bundle contract rather than through ad hoc notes.

## Bottom line

`static_ecs` already has one of the stronger benchmark surfaces in the repo and
has respectable deterministic correctness proof for a first ECS slice. It does
not yet meet a "capture all likely performance hangups" bar, and it is still
well short of a "robust fault-injection under unstable runtime assumptions"
testing bar.
