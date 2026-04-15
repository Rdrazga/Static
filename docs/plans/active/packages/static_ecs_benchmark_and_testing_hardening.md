# `static_ecs` benchmark and testing hardening plan

Scope: reopen `static_ecs` to harden benchmark observability and adversarial
validation until the package can explain likely performance cliffs and
reproduce the main hostile-input, pressure, and partial-failure classes inside
the current world-local typed ECS boundary.

## Inputs

- `docs/sketches/static_ecs_benchmark_and_testing_review_2026-04-11.md`
- `packages/static_ecs/README.md`
- `packages/static_ecs/AGENTS.md`
- `packages/static_ecs/benchmarks/`
- `packages/static_ecs/tests/`
- `packages/static_ecs/src/ecs/`
- `docs/plans/completed/static_ecs_benchmark_review_and_expansion_closed_2026-04-05.md`
- `docs/plans/completed/static_ecs_benchmark_matrix_expansion_closed_2026-04-05.md`
- `docs/plans/completed/static_ecs_benchmark_truthfulness_followup_closed_2026-04-05.md`
- `docs/plans/completed/static_ecs_allocator_strategy_review_closed_2026-04-06.md`
- `docs/plans/completed/static_ecs_cleanup_followup_closed_2026-04-05.md`
- `docs/plans/completed/static_ecs_performance_and_memory_followup_closed_2026-04-05.md`
- `docs/plans/active/workspace_operations.md`

## Scope guardrails

- Keep the package world-local and typed-first. Do not pull runtime-erased
  queries, import/export, scheduler ownership, replication, transport, GPU, or
  spatial-adapter ownership into this plan.
- Keep `static_testing` as the first shared harness surface. Only broaden the
  shared testing or benchmark workflow when the ECS-local need is concrete and
  the existing shared surface cannot express it truthfully.
- Keep benchmark workloads deterministic and bounded. New benchmark owners
  must stay review-only under `zig build bench` unless the shared workflow
  explicitly opts into gating later.
- Keep retained failures on the canonical `static_testing` artifact contract
  rather than inventing package-local sidecars.
- Treat host instability through deterministic failing allocators, budget
  denial, malformed bytes, reduced crash reproducers, and bounded sequence
  exploration first. Do not broaden into OS-thread or process-boundary harness
  work unless a concrete ECS-local bug class demands it.

## Reopen trigger

The active review in
`docs/sketches/static_ecs_benchmark_and_testing_review_2026-04-11.md`
identified concrete package-local gaps that are not covered by the 2026-04-05
and 2026-04-06 closure records:

- elapsed-time-only benchmark reporting is too weak to explain many ECS
  regressions;
- the admitted benchmark matrix is thin on capacity-edge, removal-heavy,
  relocation-heavy, and config-sweep workloads;
- `static_testing` adoption is narrow and does not yet cover retained replay,
  generated malformed input, or broader bounded sequence exploration;
- allocator-failure, budget-pressure, and hard-bound proof remains selective
  rather than systematic.

## Current decision note

Default recommendation:

- accept a large package-local hardening slice;
- keep the existing benchmark owners and direct tests as the reopen baseline;
- add observability and hostile-testing depth in layers instead of replacing
  the current suite wholesale.

Pinned design direction:

- benchmark observability should report the structural and memory-shape facts
  needed to interpret timing, not just raw elapsed time;
- negative-path testing should start from the package's explicit bounded and
  same-process input contracts, especially encoded bundles, allocator use, and
  world config limits;
- direct deterministic tests still own small sharp contracts;
- `testing.model`, replay, fuzz, and retained failures should own the broader
  mutation and malformed-input exploration where they fit better than bespoke
  fixtures.

Rejected shortcut:

- do not treat broader benchmark count or a larger random action loop by
  itself as "robustness." The plan should add attribution and reproducibility,
  not only more elapsed-time rows or bigger random seeds.

## Ordered SMART tasks

1. `Benchmark observability contract`
   Record the package-owned observability fields that every admitted ECS
   benchmark owner should report when relevant, and wire the report path so
   those fields are emitted without polluting the measured callback.
   Exact surfaces:
   - `packages/static_ecs/benchmarks/support.zig`
   - admitted owners under `packages/static_ecs/benchmarks/*.zig`
   - shared `static_testing` benchmark workflow only if the current package
     report hook cannot truthfully emit the needed metadata
   Required observability set:
   - archetype count;
   - chunk count;
   - retained-empty-chunk count where meaningful;
   - row count or match count already implied by the case;
   - command count or payload bytes for command-buffer owners;
   - benchmark-owner-specific shape counters such as average live rows per
     chunk, bundle payload bytes processed, or relocation count when those
     facts can be measured without smuggling extra work into the timed path.
   Done when:
   - the plan pins which fields are required package-wide and which remain
     owner-specific;
   - the report path can emit those annotations for ECS owners;
   - each currently admitted ECS owner either emits its relevant fields or the
     plan records why a field is intentionally inapplicable.
   Validation:
   - `zig build query_iteration_baselines`
   - `zig build command_buffer_apply_only_baselines`
   - `zig build allocator_strategy_baselines`
   - `zig build bench`
   - `zig build docs-lint`

2. `Removal and relocation benchmark owners`
   Add the benchmark owners that the current matrix is missing for structural
   collapse, repeated archetype movement, and row-copy-heavy transitions.
   Exact surfaces:
   - `packages/static_ecs/benchmarks/despawn_collapse_baselines.zig`
   - `packages/static_ecs/benchmarks/row_relocation_baselines.zig`
   - `build.zig`
   Coverage targets:
   - despawn-heavy collapse from dense worlds back toward the empty archetype;
   - alternating insert/remove churn on already-live entities;
   - repeated archetype transitions that stress shared-column copy and swap
     reindexing;
   - at least one case that distinguishes relocation-dominated cost from
     archetype creation cost.
   Done when:
   - both owners exist with deterministic semantic preflight;
   - root bench wiring admits them as named benchmark steps and under
     `zig build bench`;
   - package docs name the new owners and their intended interpretation.
   Validation:
   - `zig build despawn_collapse_baselines`
   - `zig build row_relocation_baselines`
   - `zig build bench`
   - `zig build docs-lint`

3. `Capacity-edge and config-sweep benchmark owners`
   Add bounded benchmark owners that make explicit world-limit cliffs and
   config-shape tradeoffs visible instead of leaving them implicit.
   Exact surfaces:
   - `packages/static_ecs/benchmarks/capacity_edge_baselines.zig`
   - `packages/static_ecs/benchmarks/chunk_retention_baselines.zig`
   - `packages/static_ecs/benchmarks/bundle_size_scaling_baselines.zig`
   - `build.zig`
   Coverage targets:
   - near-`entities_max` and near-`chunks_max` growth and churn;
   - archetype proliferation close to `archetypes_max`;
   - retained-empty-chunk reuse versus no-retention under one stable churn
     family;
   - small, medium, and large bundle payload scaling on typed versus direct
     encoded routes;
   - `chunk_rows_max` sweeps that show occupancy versus traversal tradeoffs
     without inventing a new package policy.
   Done when:
   - each named owner exists or is explicitly rejected in the plan with a
     reason;
   - at least one owner exposes a visible config cliff that the current
     benchmark matrix could not explain;
   - root bench wiring and docs stay aligned.
   Validation:
   - `zig build capacity_edge_baselines`
   - `zig build chunk_retention_baselines`
   - `zig build bundle_size_scaling_baselines`
   - `zig build bench`
   - `zig build docs-lint`

4. `Allocator and control-plane benchmark expansion`
   Extend allocator and setup/control-plane review beyond the current
   spawn-plus-despawn allocator owner.
   Exact surfaces:
   - `packages/static_ecs/benchmarks/allocator_strategy_baselines.zig`
   - `packages/static_ecs/benchmarks/world_lifecycle_baselines.zig`
   - `packages/static_ecs/benchmarks/command_buffer_phase_baselines.zig`
   - `build.zig`
   Coverage targets:
   - world init/deinit and command-buffer init/clear/reset under page,
     slab, and budget-tracked allocator shapes where meaningful;
   - typed bundle helper setup cost versus direct encoded setup cost when the
     current owners do not already make the gap obvious;
   - allocator-sensitive long-lived control-plane behavior, not only one
     spawn-and-despawn loop.
   Done when:
   - `allocator_strategy_baselines` either widens to cover the named
     control-plane stories or the new owner carries them cleanly;
   - the package docs say whether allocator guidance remains caller policy or
     whether one allocator recommendation is now evidence-backed for a named
     workload family.
   Validation:
   - `zig build allocator_strategy_baselines`
   - `zig build world_lifecycle_baselines`
   - `zig build command_buffer_phase_baselines`
   - `zig build bench`
   - `zig build docs-lint`

5. `Encoded-bundle replay and fuzz hardening`
   Move encoded-bundle negative-path coverage from a fixed hand-written matrix
   to a retained and reducible adversarial surface.
   Exact surfaces:
   - `packages/static_ecs/tests/integration/encoded_bundle_runtime.zig`
   - `packages/static_ecs/tests/integration/encoded_bundle_replay_runtime.zig`
   - `packages/static_ecs/tests/integration/encoded_bundle_fuzz_runtime.zig`
   - `packages/static_ecs/tests/integration/root.zig`
   - package-owned retained failure inputs on the shared `static_testing`
     failure-bundle contract
   Coverage targets:
   - malformed headers, payload size mismatches, duplicate ids, unsorted ids,
     out-of-range ids, truncated buffers, misaligned caller slices, and
     malformed multi-entry combinations;
   - corpus growth from reduced failures rather than ad hoc random bytes;
   - retained reproduction of any reduced malformed-bundle failure.
   Done when:
   - replay-driven malformed-bundle coverage exists under the package test
     surface;
   - a bounded generated malformed-input campaign exists and can retain reduced
     failures through the shared artifact contract;
   - package docs describe the retained failure path instead of relying on raw
     reproduction notes.
   Validation:
   - `zig build test`
   - `zig build harness`
   - `zig build docs-lint`

6. `Allocator-failure and budget-pressure matrix`
   Add systematic partial-failure proof across the ECS allocation and staging
   paths instead of relying on one cleanup regression and a few direct
   `NoSpaceLeft` fixtures.
   Exact surfaces:
   - `packages/static_ecs/src/ecs/chunk.zig`
   - `packages/static_ecs/src/ecs/archetype_store.zig`
   - `packages/static_ecs/src/ecs/command_buffer.zig`
   - `packages/static_ecs/src/ecs/world.zig`
   - new package-owned integration fixtures if the failure matrix is too large
     for inline tests alone
   Coverage targets:
   - chunk init failure after budget reservation and allocator denial;
   - archetype creation and first-chunk append failure after partial progress;
   - command-buffer bundle staging under payload-byte and command-count
     exhaustion with rollback proof;
   - world bundle admission and structural move failure after partial setup;
   - post-failure reuse proof showing the world or buffer remains usable.
   Done when:
   - every allocation-sensitive ECS layer has at least one direct failing
     allocator or bounded-budget proof;
   - the touched tests prove rollback, accounting cleanup, and continued
     usability after the error;
   - the plan records which paths are still intentionally covered only by
     direct lower-level tests.
   Validation:
   - `zig build test`
   - `zig build docs-lint`

7. `World and store model expansion`
   Expand `testing.model` coverage beyond command buffers so world mutation,
   stale-entity reuse, chunk retention, and structural relocation are explored
   under bounded reproducible sequences.
   Exact surfaces:
   - `packages/static_ecs/tests/integration/command_buffer_runtime_sequences.zig`
   - `packages/static_ecs/tests/integration/world_runtime_sequences.zig`
   - `packages/static_ecs/tests/integration/archetype_store_runtime_sequences.zig`
   - `packages/static_ecs/tests/integration/root.zig`
   Coverage targets:
   - spawn/despawn/reuse cycles with stale handle rejection;
   - scalar insert/remove versus fused bundle transitions on already-live
     entities;
   - empty-chunk retention and reuse across repeated churn;
   - direct archetype-store transitions where package-local ownership is the
     real boundary;
   - cross-checks against a bounded shadow model rather than only against
     self-consistency.
   Done when:
   - ECS owns at least one additional model target beyond command buffers;
   - the new model target explores a bug class the current direct tests cannot
     cover compactly;
   - retained reduced failures can be replayed when the model surface finds a
     divergence.
   Validation:
   - `zig build test`
   - `zig build harness`
   - `zig build docs-lint`

8. `Hard-bound saturation and misuse suites`
   Turn the package's explicit world bounds into systematic proof instead of
   one-off examples.
   Exact surfaces:
   - `packages/static_ecs/tests/integration/world_bound_pressure_runtime.zig`
   - `packages/static_ecs/tests/integration/command_buffer_bound_pressure_runtime.zig`
   - `packages/static_ecs/tests/integration/view_invalidation_runtime.zig`
   - `packages/static_ecs/tests/integration/root.zig`
   Coverage targets:
   - `entities_max`, `archetypes_max`, `chunks_max`,
     `components_per_archetype_max`, `command_buffer_entries_max`,
     `command_buffer_payload_bytes_max`, and `empty_chunk_retained_max`;
   - repeated saturation and recovery rather than single overflow attempts;
   - misuse sequences that combine stale entities, invalidated views, and
     structural mutation ordering without leaving the package boundary.
   Done when:
   - every explicit `WorldConfig` bound named above has a package-owned proof
     or a recorded reason why a lower-level test already owns it completely;
   - repeated pressure and recovery is directly proved for the command buffer
     and at least one world structural path.
   Validation:
   - `zig build test`
   - `zig build docs-lint`

9. `Docs, admission, and closure criteria`
   Keep package docs and root navigation truthful as the benchmark and testing
   surfaces broaden.
   Exact surfaces:
   - `packages/static_ecs/README.md`
   - `packages/static_ecs/AGENTS.md`
   - root `README.md`
   - root `AGENTS.md`
   - `docs/architecture.md`
   - this plan and the eventual completion record
   Done when:
   - every admitted benchmark owner and every first-class shared testing
     surface added by this plan is named in package docs;
   - the docs say which hostile-testing surfaces ECS now uses and which remain
     intentionally out of scope;
   - the completion record can close against explicit benchmark-observability,
     replay/fuzz/model adoption, allocator-failure proof, and hard-bound proof
     criteria instead of a vague "test suite improved" summary.
   Validation:
   - `zig build docs-lint`

## `static_testing` adoption map

### Primary coverage targets

- retained malformed encoded-bundle failures;
- bounded structural mutation sequences with shadow-model comparison;
- reproducible allocator-failure and bound-pressure regressions;
- benchmark history that now carries the ECS observability fields needed to
  interpret timing.

### Best-fit shared surfaces

- `testing.model` for bounded mutation sequences and shadow-state divergence;
- replay and retained failure bundles for reduced malformed-bundle and
  sequence failures;
- bounded generated malformed-input coverage for encoded-bundle hardening;
- shared benchmark workflow for stable benchmark artifacts and observability
  reports.

### Keep out of scope unless a new bug class appears

- `testing.system`, `testing.process_driver`, and broad process-boundary
  orchestration;
- scheduler or time-driven simulation work;
- host-thread concurrency modeling beyond child-process crash reproducers for
  fail-fast borrowed-view misuse.

## Work order

1. Freeze the benchmark observability contract so new benchmark owners do not
   immediately drift into one-off reporting.
2. Add the missing removal, relocation, capacity-edge, and allocator/control
   benchmark owners.
3. Harden encoded-bundle negative coverage through replay and generated
   malformed input.
4. Add allocator-failure and hard-bound pressure proof.
5. Expand model coverage from command buffers into broader world mutation.
6. Update package docs and close only after the new surfaces are admitted and
   reproducible.

## Ideal state

- ECS benchmark reports explain not only that a case got slower, but which
  structural or allocation shape changed.
- ECS correctness proof covers both direct contracts and reproducible hostile
  sequences instead of only happy-path plus hand-authored edge fixtures.
- The package still stays within its world-local typed boundary while using the
  shared `static_testing` surfaces in the places where they materially improve
  confidence.
