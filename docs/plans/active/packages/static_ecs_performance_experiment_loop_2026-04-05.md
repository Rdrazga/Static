# `static_ecs` performance experiment loop

Scope: run a long-lived local-only experiment loop against `static_ecs`
performance, including minor, radical, and cross-package changes, while
keeping the main workspace anchored to one stable commit between experiments.

Status: local plan created on 2026-04-05 after commit `867c910`
(`Expand and harden static_ecs benchmarks`), then rebased to stable commit
`db55c19` (`Cache scalar archetype transitions in static_ecs`) after the first
promoted ECS performance experiment, then rebased again to stable commit
`585a3f5` (`Add command-buffer phase benchmarks for static_ecs`) after
promoting `EXP-014`, then rebased again to stable commit `cbe02d6`
(`Speed up static_ecs command buffer staging`) after promoting `EXP-016`,
then rebased again to stable commit `4a5a34b`
(`Add static_ecs frame workload benchmarks`) after promoting `EXP-015`, then
rebased again to stable commit `74f66a0`
(`Short-circuit static_ecs invariant scans in ReleaseFast`) after promoting
`EXP-022`, then rebased again to stable commit `63c733c`
(`Harden ECS dependency benchmarks and allocator review`) after the
cross-package dependency follow-up and ECS allocator strategy benchmark work,
then rebased again to stable commit `75cee81`
(`Add apply-only ECS benchmark attribution`) after promoting `EXP-023`, then
rebased again to stable commit `845a920`
(`Add ECS query startup benchmarks`) after promoting `EXP-024`.

## Stable baseline

- Stable commit: `845a920`
- Stable branch: `master`
- Rule: the main workspace stays on `845a920` between experiments unless one
  experiment is explicitly promoted and committed as the next baseline.
- Rule: every experiment runs in an isolated throwaway worktree or branch, not
  in the main workspace.
- Rule: only adopt an experiment back into the main tree after it proves a
  worthwhile benchmark shift and survives correctness validation.
- Rule: never stack multiple experiment hypotheses on one throwaway branch.
- Rule: every throwaway branch must be deleted after the result is logged,
  whether the result is `discard`, `revisit`, or `promote`.
- Rule: every throwaway worktree must end at a clean `git status --short`
  before removal so unlogged changes do not get stranded.

## Baseline benchmark snapshot

Collected under the corrected `ReleaseFast` benchmark graph. The current stable
baseline for new experiments is `845a920`; the figures below still record the
last validated ECS-local stable readings from the post-`EXP-022` promotion
sweep and remain the comparison anchor until a later ECS experiment is
explicitly promoted and committed as the next baseline.

### `micro_hotpaths_baselines`

- `component_ptr_const_hit`: median `1.416 ns/op`
- `has_component_hit`: median `3.076 ns/op`
- `iterator_startup_first_batch_dense`: median `2.869 ns/op`
- `command_buffer_stage_spawn_bundle_single`: median `7.874 ns/op`

### `query_iteration_baselines`

- `dense_required_reads_single_archetype`: median `1.839 us/op`
- `mixed_optional_health_exclude_tag`: median `652.441 ns/op`
- `fragmented_optional_exclude_scan`: median `2.450 us/op`

### `query_scale_baselines`

- `dense_1k_entities_1_archetype`: median `594.531 ns/op`
- `dense_16k_entities_1_archetype`: median `9.521 us/op`
- `fragmented_16k_entities_8_archetypes`: median `15.057 us/op`
- `fragmented_16k_entities_16_archetypes`: median `7.331 us/op`

### `command_buffer_staged_apply_baselines`

- `spawn_bundle_stage_and_apply`: median `2.032 ms/op`
- `insert_bundle_stage_and_apply`: median `2.491 ms/op`
- `mixed_spawn_insert_remove_stage_and_apply`: median `3.213 ms/op`

### `command_buffer_phase_baselines`

- `spawn_only_setup_world_and_buffer`: median `21.458 us/op`
- `insert_only_setup_world_buffer_and_entities`: median `79.865 us/op`
- `mixed_setup_world_buffer_and_entities`: median `299.313 us/op`
- `spawn_only_stage_and_clear`: median `1.409 us/op`
- `insert_only_stage_and_clear`: median `1.698 us/op`
- `mixed_stage_and_clear`: median `1.157 us/op`

### `structural_churn_baselines`

- `spawn_then_scalar_insert`: median `3.041 ms/op`
- `spawn_bundle_fused`: median `740.909 us/op`
- `live_entities_scalar_transition`: median `2.258 ms/op`
- `live_entities_bundle_transition`: median `1.436 ms/op`

### `frame_pass_baselines`

- `1_pass_4k_entities_1_archetype`: median `389.291 us/op`
- `4_passes_4k_entities_1_archetype`: median `754.499 us/op`
- `4_passes_16k_entities_8_archetypes`: median `3.467 ms/op`
- `8_passes_16k_entities_16_archetypes`: median `7.109 ms/op`

### `frame_workload_baselines`

- `branch_heavy_4_systems_8k_entities_8_archetypes`: median `14.779 us/op`
- `branch_heavy_8_systems_16k_entities_16_archetypes`: median `50.138 us/op`
- `write_heavy_4_systems_4k_entities_1_archetype`: median `20.592 us/op`
- `write_heavy_8_systems_16k_entities_8_archetypes`: median `119.740 us/op`

## Experiment protocol

1. Start every experiment from `75cee81`.
   Do not branch from a dirty main workspace state.
2. Create an isolated worktree:
   - `git worktree add .tmp/ecs-perf-exp-<id> 75cee81`
3. Inside that worktree, create a throwaway branch:
   - `git switch -c perf/ecs-exp-<id>`
4. Record the worktree path and branch name in the experiment log before
   editing anything.
   Keep one worktree and one branch per experiment only.
5. Make one coherent experiment only.
   Keep the write scope narrow enough that the result can be interpreted.
6. Run the minimum correctness surface first:
   - `zig build check`
7. Run the benchmark subset that matches the hypothesis.
   Default full bundle:
   - `zig build micro_hotpaths_baselines`
   - `zig build query_iteration_baselines`
   - `zig build query_scale_baselines`
   - `zig build command_buffer_staged_apply_baselines`
   - `zig build structural_churn_baselines`
   - `zig build frame_pass_baselines`
8. Record results in the experiment log section below.
9. Decide one of:
   - `discard`
   - `revisit`
   - `promote`
10. If the result is `promote`, reapply or carry the exact winning change onto
    the main workspace, validate it there, commit it, and then update this
    plan so future experiments branch from the new stable commit.
11. Before cleanup, verify the throwaway worktree is clean:
    - `git status --short`
12. Remove the throwaway worktree and branch after logging:
   - `git worktree remove .tmp/ecs-perf-exp-<id>`
   - `git branch -D perf/ecs-exp-<id>`
13. Return to the stable main workspace at `75cee81`.
14. Confirm the main workspace is still on the intended stable commit before
    starting the next experiment.

## Logging template

Copy this block for every experiment.

```text
Experiment: EXP-###
Class: minor | radical | cross-package | config | benchmark-only
Status: planned | running | completed | discarded | promoted | revisit
Stable base: 75cee81
Branch: perf/ecs-exp-###
Worktree: .tmp/ecs-perf-exp-###
Hypothesis:
Reasoning:
Touched packages/files:
Benchmark subset:
Correctness checks:
Result summary:
  - benchmark -> old median -> new median -> delta
Regressions:
Interpretation:
Next action:
Cleanup status:
```

## Planned experiments

### Priority 1: hot-path and query leverage

- `EXP-001` minor
  Hypothesis: `hasComponent()` and `componentPtrConst()` spend too much time
  rediscovering entity location and archetype key.
  Reasoning: current paths call through entity-location lookup and then key
  membership checks. A tighter direct presence fast-path may help the
  microbenchmarks and command-heavy paths.
- `EXP-002` minor
  Hypothesis: `View.Iterator.next()` loses time rescanning archetypes on every
  iterator construction.
  Reasoning: a cached matching-archetype list or prefiltered iterator state may
  improve `query_iteration`, `query_scale`, and frame passes.
- `EXP-003` minor
  Hypothesis: archetype and chunk iteration costs are sensitive to
  `chunk_rows_max`.
  Reasoning: a sweep over `32`, `64`, and `128` rows may shift dense versus
  fragmented tradeoffs in a measurable way.

### Priority 2: structural churn and command-buffer leverage

- `EXP-004` minor
  Hypothesis: command-buffer apply cost is dominated by per-command dispatch
  and repeated decode work.
  Reasoning: predecoded typed command payloads or a tighter command tag layout
  may improve `command_buffer_staged_apply`.
- `EXP-005` minor
  Hypothesis: live-entity scalar churn loses time on repeated source to
  destination archetype derivation.
  Reasoning: caching transition outcomes by `(source archetype, component set
  delta)` may improve scalar insert/remove and maybe bundle paths too.
- `EXP-006` config
  Hypothesis: `empty_chunk_retained_max` materially affects churn and staged
  apply workloads.
  Reasoning: compare `0`, `1`, `2`, and `4` retained empty chunks for
  structural cases.

### Priority 3: radical ECS-local design probes

- `EXP-007` radical
  Hypothesis: query plans should be first-class cached objects instead of
  reconstructing shape matching on every `view(...)`.
  Reasoning: if plan caching changes `query_scale` and `frame_pass` materially,
  it may justify a more durable API design later.
- `EXP-008` radical
  Hypothesis: archetype transitions need an explicit graph rather than on-demand
  destination derivation.
  Reasoning: prelinked transitions could shift both bundle and scalar mutation
  costs if structural churn is a real workload.
- `EXP-009` radical
  Hypothesis: `hasComponent()` wants a per-entity component mask or compact
  presence word alongside location metadata.
  Reasoning: this could collapse lookup overhead at the cost of update
  complexity and memory pressure.
- `EXP-010` radical
  Hypothesis: hot and cold component columns should not always share the same
  chunk residency policy.
  Reasoning: split or optional cold-column storage may improve frame passes for
  large fragmented worlds, even if it harms simpler cases.

### Priority 4: cross-package leverage

- `EXP-011` cross-package `static_collections`
  Hypothesis: archetype and chunk indexes may benefit from different map or
  dense-storage helpers than the current choices.
  Reasoning: probe `DenseArray`-style relocation metadata or alternative map
  layouts if ECS-local indexing dominates hot paths.
- `EXP-012` cross-package `static_memory`
  Hypothesis: world, chunk, and command-buffer allocations may improve with a
  more specialized pool/slab policy.
  Reasoning: benchmark allocator pressure separately from ECS logic where
  setup-heavy cases still dominate.
- `EXP-013` cross-package `static_hash`
  Hypothesis: archetype fingerprint or repeated key combination work could
  improve with batch-oriented hash helpers.
  Reasoning: if archetype lookup still shows up after query caching probes,
  this is the next lower-layer lever to test.

### Priority 5: benchmark-shape probes

- `EXP-014` benchmark-only
  Hypothesis: some current owners still hide distinct costs behind one case.
  Reasoning: split stage-only, apply-only, and setup-only command-buffer cases
  if ECS implementation changes make attribution blurry again.
- `EXP-015` benchmark-only
  Hypothesis: frame-pass workloads need one branch-heavy and one write-heavy
  alternative to avoid tuning only for the current synthetic mix.
  Reasoning: broaden observability without changing ECS code first.

### Priority 6: Zig, dependency, and codegen leverage

- `EXP-017` cross-package `static_collections`
  Hypothesis: `Vec` needs an explicit bounded length-bump or reserve-write
  helper so ECS and other packages can avoid per-element append overhead
  without reaching into internals that the compiler may not optimize well.
  Reasoning: the promoted `EXP-016` win came from bypassing append loops in one
  ECS-local hot path. A package-owned helper may preserve the win while making
  the pattern reusable and clearer to the optimizer.
- `EXP-018` Zig/codegen
  Hypothesis: some ECS hot paths are sensitive to inlining and generic shape,
  especially tiny wrappers like `hasComponent`, component lookup, and
  command-buffer bundle staging.
  Reasoning: compare small source rewrites that encourage simpler SSA shapes,
  tighter `comptime` constants, or fewer helper boundaries without changing
  semantics. Treat this as a codegen-shape probe rather than an algorithm
  change.
- `EXP-019` cross-package `static_memory`
  Hypothesis: allocator and growth behavior are still contributing measurable
  setup cost in ECS-heavy benchmarks, especially the setup-heavy command-buffer
  and structural owners.
  Reasoning: try pool/slab-backed chunk or command-buffer storage policies, or
  package-local benchmark owners that isolate allocator churn before changing
  ECS behavior.
- `EXP-020` Zig/codegen and benchmark-only
  Hypothesis: compile-time and runtime outcomes shift across `Debug`,
  `ReleaseSafe`, and `ReleaseFast` in a way that could expose assertion-heavy
  or optimizer-sensitive ECS paths.
  Reasoning: add a local-only comparison protocol around the current benchmark
  owners and compile surface to detect places where Zig optimization choices
  dominate the result more than the ECS design itself.
- `EXP-021` ECS-local
  Hypothesis: direct-encoded bundle apply and scalar remove paths may still pay
  avoidable decode and per-type dispatch overhead after the command-buffer
  staging win.
  Reasoning: revisit apply-side work now that stage-only cost is observable and
  partially improved, but keep the probe narrow enough to attribute.
- `EXP-022` Zig/codegen and benchmark-only
  Hypothesis: the large `ReleaseSafe` gap is driven more by runtime-safety
  invariants and generic query/view validation than by the core column-walk
  work itself.
  Reasoning: after `EXP-020`, the next optimizer-sensitivity probe should
  isolate which runtime-safety checks dominate the gap before changing ECS data
  structures to chase a problem that may mostly be mode-specific.

### Priority 7: observability and API-split follow-ups

- `EXP-023` benchmark-only
  Hypothesis: the current command-buffer attribution surface still leaves true
  apply throughput partially hidden because staged-apply cases include staging
  work and phase cases stop before apply.
  Reasoning: add apply-only command-buffer benchmarks over pre-staged payloads
  so later apply-side tuning can be measured without setup or staging noise.
- `EXP-024` benchmark-only
  Hypothesis: query startup costs are still under-attributed because the
  current query owners do not isolate zero-match and sparse-match startup.
  Reasoning: add zero-match and sparse-match typed query startup cases so
  future query tuning can distinguish matching cost from column-walk cost.
- `EXP-025` benchmark-only
  Hypothesis: structural churn cost is strongly width-sensitive, and the
  current scalar-versus-bundle cases do not expose where the crossover points
  are.
  Reasoning: add scalar width sweeps for `insert`, `remove`, `insertBundle`,
  and `removeBundle` so later mutation-surface decisions are benchmark-backed.
- `EXP-026` benchmark-only
  Hypothesis: the current frame and command-buffer owners still under-measure
  persistent reuse patterns compared with real long-lived simulation worlds.
  Reasoning: add persistent frame cadence benchmarks that reuse one world and
  one command buffer across many iterations instead of rebuilding setup every
  sample.
- `EXP-027` benchmark-only
  Hypothesis: allocator-backed ECS costs are still being averaged together even
  though setup, steady-state, and teardown likely respond to different
  allocator policies.
  Reasoning: separate allocator-backed world setup, steady-state work, and
  teardown into distinct benchmark cases before making allocator-shape changes.
- `EXP-028` API-split research
  Hypothesis: repeated scalar structural mutation may need an explicit batch or
  transaction surface rather than further tuning the immediate scalar API
  alone.
  Reasoning: explore a transaction-style structural batch surface that can
  preserve immediate-looking caller code while giving ECS one fused mutation
  boundary.
- `EXP-029` API-split research
  Hypothesis: dynamic tooling and runtime-composed query use cases want a
  separate erased query-plan surface, and trying to push that into the typed
  hot path will continue to regress the main iterator path.
  Reasoning: explore an erased query-plan surface for tools, editors, and
  runtime composition without burdening the typed hot-loop API.
- `EXP-030` API-split research
  Hypothesis: short-lived setup-heavy worlds, import flows, and test fixtures
  want a different calling structure from long-lived simulation worlds.
  Reasoning: explore a setup or builder-oriented surface for imports,
  fixtures, and short-lived worlds so steady-state world APIs stay tuned for
  reuse.

## Completed experiments

### `EXP-000`

- Class: benchmark truthfulness
- Status: completed
- Stable base: pre-`867c910`, adopted into `867c910`
- Hypothesis: the benchmark graph was not actually measuring release-style ECS
  code, the command-buffer owner name was misleading, and structural churn
  reruns were unnecessarily long.
- Reasoning: benchmark numbers are not actionable if optimize mode is wrong or
  the owner name hides timed setup cost.
- Touched files:
  - `build.zig`
  - `packages/static_ecs/benchmarks/command_buffer_apply_baselines.zig`
  - `packages/static_ecs/benchmarks/structural_churn_baselines.zig`
  - package and repo docs
- Result summary:
  - benchmark history now records `build_mode=release_fast`
  - command-buffer owner renamed to `command_buffer_staged_apply_baselines`
  - `structural_churn_baselines` now finishes under a practical rerun budget
- Outcome: promoted and committed in `867c910`

### `EXP-001`

- Class: minor
- Status: discarded
- Stable base: `867c910`
- Hypothesis: `hasComponent()` and `componentPtrConst()` spend too much time
  rediscovering entity location and archetype key.
- Reasoning: current lookup paths bounce through entity-location validation and
  key membership checks, so a tighter shared validated-location helper looked
  like a cheap way to reduce duplicate work.
- Touched files in throwaway worktree:
  - `packages/static_ecs/src/ecs/archetype_store.zig`
- Benchmark subset:
  - `zig build micro_hotpaths_baselines`
  - `zig build query_iteration_baselines`
- Correctness checks:
  - benchmark preflight only
- Result summary:
  - `component_ptr_const_hit`: `16.629 us/op` -> `17.177 us/op` -> slower
  - `has_component_hit`: `44.060 us/op` -> `44.348 us/op` -> slower
  - `iterator_startup_first_batch_dense`: `11.043 us/op` -> `10.990 us/op` -> flat
  - `dense_required_reads_single_archetype`: `19.985 us/op` -> `20.474 us/op` -> slower
  - `mixed_optional_health_exclude_tag`: `32.104 us/op` -> `31.919 us/op` -> slightly better
  - `fragmented_optional_exclude_scan`: `135.851 us/op` -> `138.132 us/op` -> slower
- Regressions:
  - direct entity lookup hot paths regressed instead of improving
- Interpretation:
  - the helper refactor improved code organization but did not create a real
    hot-path win. The extra abstraction likely did not reduce enough work after
    optimization and may have hindered the best inlining shape.
- Environment note:
  - isolated worktrees do not inherit the main workspace's ignored local
    support files, so the experiment worktree needed copies of the current
    ignored temporal-support files before benchmarks would build. Future
    worktrees should either copy those files up front or restrict validation to
    slices that do not depend on them.
- Next action:
  - remove the throwaway worktree and move to `EXP-002` around iterator and
    archetype-match scan cost.

### `EXP-002`

- Class: minor
- Status: revisit
- Stable base: `867c910`
- Hypothesis: archetype scan cost in `View.Iterator.next()` is still paying too
  much per query match, so replacing per-access membership checks with
  precomputed required and excluded masks may improve iterator-heavy workloads.
- Reasoning: the current `Query.matches()` path walks each access descriptor and
  calls per-component membership checks for every archetype scan. A
  precomputed-mask path should reduce that to word-wise `containsAll` and
  `intersects` checks without changing the public API or adding allocations.
- Touched files in throwaway worktree:
  - `packages/static_ecs/src/ecs/archetype_key.zig`
  - `packages/static_ecs/src/ecs/query.zig`
- Benchmark subset:
  - `zig build micro_hotpaths_baselines`
  - `zig build query_iteration_baselines`
  - `zig build query_scale_baselines`
  - `zig build frame_pass_baselines`
- Correctness checks:
  - `zig build check`
- Result summary:
  - `component_ptr_const_hit`: `16.629 us/op` -> `16.888 us/op` -> slower
  - `has_component_hit`: `44.060 us/op` -> `44.317 us/op` -> slower
  - `iterator_startup_first_batch_dense`: `11.043 us/op` -> `10.944 us/op` -> slightly better
  - `dense_required_reads_single_archetype`: `19.985 us/op` -> `20.474 us/op` -> slower
  - `mixed_optional_health_exclude_tag`: `32.104 us/op` -> `33.938 us/op` -> slower
  - `fragmented_optional_exclude_scan`: `135.851 us/op` -> `140.351 us/op` -> slower
  - `dense_1k_entities_1_archetype`: `43.380 us/op` -> `42.358 us/op` -> better
  - `dense_16k_entities_1_archetype`: `704.449 us/op` -> `687.530 us/op` -> better
  - `fragmented_16k_entities_8_archetypes`: `1.136 ms/op` -> `1.118 ms/op` -> better
  - `fragmented_16k_entities_16_archetypes`: `1.347 ms/op` -> `1.337 ms/op` -> better
- Regressions:
  - the shorter iterator-centric cases regressed, which means the cheaper
    matching path did not produce an across-the-board win.
  - `frame_pass_baselines` failed to compile in the experiment because the
    extra comptime work pushed the component/query instantiations past the
    current branch-quota limit.
- Interpretation:
  - the mask-based query matcher appears to help longer full-scan throughput,
    but not enough to offset startup/regression risk in its current form.
    Compile-time cost also got worse in a real benchmark owner, which makes the
    experiment unsuitable as-is for promotion.
- Environment note:
  - the experiment worktree again needed copies of the current ignored temporal
    support files from the main workspace before the full local validation
    surface matched baseline expectations.
- Next action:
  - remove the throwaway worktree and either retry this idea with lower
    comptime pressure or move to a different lever such as chunk-row sweeps or
    structural transition caching.

### `EXP-003`

- Class: config
- Status: revisit
- Stable base: `867c910`
- Hypothesis: archetype and chunk iteration costs are sensitive to
  `chunk_rows_max`, and comparing `32`, `64`, and `128` rows may reveal a more
  favorable geometry for the current benchmark mix.
- Reasoning: chunk geometry changes cache locality, batch sizes, and iterator
  overhead without touching ECS semantics. This is a clean lever for seeing
  whether the current `64`-row benchmark posture is leaving performance on the
  table.
- Touched files in throwaway worktree:
  - `packages/static_ecs/benchmarks/micro_hotpaths_baselines.zig`
  - `packages/static_ecs/benchmarks/query_iteration_baselines.zig`
  - `packages/static_ecs/benchmarks/query_scale_baselines.zig`
  - `packages/static_ecs/benchmarks/frame_pass_baselines.zig`
- Benchmark subset:
  - `zig build micro_hotpaths_baselines`
  - `zig build query_iteration_baselines`
  - `zig build query_scale_baselines`
  - `zig build frame_pass_baselines`
- Correctness checks:
  - `zig build check`
- Result summary against the stable `64`-row baseline:
  - `32` rows:
    - `component_ptr_const_hit`: `16.629 us/op` -> `16.459 us/op` -> slightly better
    - `has_component_hit`: `44.060 us/op` -> `43.809 us/op` -> slightly better
    - `iterator_startup_first_batch_dense`: `11.043 us/op` -> `11.016 us/op` -> flat
    - `dense_required_reads_single_archetype`: `19.985 us/op` -> `21.118 us/op` -> slower
    - `mixed_optional_health_exclude_tag`: `32.104 us/op` -> `32.233 us/op` -> flat
    - `fragmented_optional_exclude_scan`: `135.851 us/op` -> `138.059 us/op` -> slower
    - `dense_1k_entities_1_archetype`: `43.380 us/op` -> `43.699 us/op` -> slightly slower
    - `dense_16k_entities_1_archetype`: `704.449 us/op` -> `701.870 us/op` -> slightly better
    - `fragmented_16k_entities_8_archetypes`: `1.136 ms/op` -> `1.123 ms/op` -> slightly better
    - `fragmented_16k_entities_16_archetypes`: `1.347 ms/op` -> `1.319 ms/op` -> better
    - `1_pass_4k_entities_1_archetype`: `389.291 us/op` -> `348.876 us/op` -> better
    - `4_passes_4k_entities_1_archetype`: `754.499 us/op` -> `707.064 us/op` -> better
    - `4_passes_16k_entities_8_archetypes`: `3.467 ms/op` -> `3.399 ms/op` -> better
    - `8_passes_16k_entities_16_archetypes`: `7.109 ms/op` -> `6.975 ms/op` -> better
  - `128` rows:
    - `component_ptr_const_hit`: `16.629 us/op` -> `16.886 us/op` -> slightly slower
    - `has_component_hit`: `44.060 us/op` -> `43.218 us/op` -> slightly better
    - `iterator_startup_first_batch_dense`: `11.043 us/op` -> `10.963 us/op` -> slightly better
    - `dense_required_reads_single_archetype`: `19.985 us/op` -> `20.880 us/op` -> slower
    - `mixed_optional_health_exclude_tag`: `32.104 us/op` -> `35.085 us/op` -> slower
    - `fragmented_optional_exclude_scan`: `135.851 us/op` -> `145.879 us/op` -> slower
    - `dense_1k_entities_1_archetype`: `43.380 us/op` -> `42.494 us/op` -> better
    - `dense_16k_entities_1_archetype`: `704.449 us/op` -> `696.943 us/op` -> slightly better
    - `fragmented_16k_entities_8_archetypes`: `1.136 ms/op` -> `1.111 ms/op` -> better
    - `fragmented_16k_entities_16_archetypes`: `1.347 ms/op` -> `1.324 ms/op` -> better
    - `1_pass_4k_entities_1_archetype`: `389.291 us/op` -> `595.265 us/op` -> much slower
    - `4_passes_4k_entities_1_archetype`: `754.499 us/op` -> `1.205 ms/op` -> much slower
    - `4_passes_16k_entities_8_archetypes`: `3.467 ms/op` -> `5.442 ms/op` -> much slower
    - `8_passes_16k_entities_16_archetypes`: `7.109 ms/op` -> `11.885 ms/op` -> much slower
- Regressions:
  - the benchmark owners were not sweep-ready at first: lowering
    `chunk_rows_max` exposed that some owners had hard-coded `chunks_max`
    values sized only for `64`-row chunks. The experiment had to derive
    `chunks_max` from `entities_max` and `archetypes_max` before the sweep was
    meaningful.
  - `128` rows is clearly a bad fit for the current frame/system workloads on
    this machine.
- Interpretation:
  - `64` rows remains the best balanced default among the tested values.
    `32` rows is promising for write-heavy frame/system workloads and slightly
    better for some query-scale cases, but it also regresses the shorter
    iterator/query-iteration slice enough that it should not replace the
    current default without stronger workload targeting.
  - `128` rows concentrates work into larger batches that help some long
    scale-style scans a little, but the worse locality and larger write working
    sets appear to punish the current frame/system passes heavily.
- Measurement note:
  - the later `baseline_compare` output inside the throwaway worktree compared
    the `128` runs against the locally recorded `32`-row baselines, not the
    stable `64`-row baseline. The comparisons listed above are the manually
    normalized `32` and `128` medians against the stable `64` snapshot at the
    top of this plan.
- Next action:
  - keep the main tree on the current `64`-row benchmark posture and revisit
    chunk geometry only if a future experiment targets a specific workload
    class, such as frame-heavy worlds or fragmented long-scan analytics.

### `EXP-004`

- Class: minor
- Status: revisit
- Stable base: `867c910`
- Hypothesis: the command-buffer staged-apply workloads are still paying too
  much local overhead in bundle staging, especially inside
  `appendEncodedBundle()` where payload storage is grown one zero byte at a
  time before encoding.
- Reasoning: the staged-apply benchmark owner measures command-buffer staging
  as well as apply, and the current payload-growth loop is obvious per-command
  work entirely inside `static_ecs`.
- Touched files in throwaway worktree:
  - `packages/static_ecs/src/ecs/command_buffer.zig`
- Benchmark subset:
  - `zig build micro_hotpaths_baselines`
  - `zig build command_buffer_staged_apply_baselines`
- Correctness checks:
  - `zig build check`
- Result summary against the stable `867c910` baseline:
  - `command_buffer_stage_spawn_bundle_single`: `66.040 ns/op` -> `7.922 ns/op` -> much better
  - staged-apply run 1:
    - `spawn_bundle_stage_and_apply`: `2.048 ms/op` -> `1.982 ms/op` -> slightly better
    - `insert_bundle_stage_and_apply`: `2.315 ms/op` -> `3.559 ms/op` -> worse
    - `mixed_spawn_insert_remove_stage_and_apply`: `3.409 ms/op` -> `6.409 ms/op` -> worse
  - staged-apply rerun:
    - `spawn_bundle_stage_and_apply`: `2.048 ms/op` -> `2.344 ms/op` -> worse
    - `insert_bundle_stage_and_apply`: `2.315 ms/op` -> `4.683 ms/op` -> worse
    - `mixed_spawn_insert_remove_stage_and_apply`: `3.409 ms/op` -> `6.393 ms/op` -> worse
- Regressions:
  - the target staged-apply owner did not produce a stable win. The longer
    cases were materially worse on rerun even though the micro staging case
    improved dramatically.
- Interpretation:
  - the per-byte payload-growth loop is a real micro-level cost in command
    staging, but the current staged-apply owner is dominated enough by world
    setup, world mutation, and general system variance that this narrow change
    did not yield a trustworthy end-to-end improvement.
  - This experiment is worth revisiting only after the benchmark surface
    separates stage-only from apply-only costs more explicitly.
- Measurement note:
  - the staged-apply owner showed strong run-to-run instability here, including
    bimodal and drifting samples, which reinforces that it is not a clean
    attribution surface for a narrow local staging optimization.
- Next action:
  - discard this code change for now, keep the insight, and come back to it
    only alongside a benchmark-surface split such as the planned
    `EXP-014` stage-only/apply-only work.

### `EXP-005`

- Class: minor
- Status: promoted
- Stable base: `867c910`
- Hypothesis: live scalar churn and spawn-then-scalar insertion are repeatedly
  deriving the same single-component archetype transitions and redoing the same
  target-archetype lookup work for every entity.
- Reasoning: the structural churn owner repeatedly performs the same
  `(source archetype, add/remove one component)` transitions. A tiny validated
  transition cache plus a known-target move helper should let scalar
  insert/remove paths reuse target archetype discovery without changing
  semantics.
- Touched files in throwaway worktree:
  - `packages/static_ecs/src/ecs/archetype_store.zig`
- Benchmark subset:
  - `zig build structural_churn_baselines`
  - `zig build micro_hotpaths_baselines`
- Correctness checks:
  - `zig build check`
- Result summary against the stable `867c910` baseline:
  - structural churn run 1:
    - `spawn_then_scalar_insert`: `15.544 ms/op` -> `12.040 ms/op` -> better
    - `spawn_bundle_fused`: `2.939 ms/op` -> `2.939 ms/op` -> flat
    - `live_entities_scalar_transition`: `14.180 ms/op` -> `10.653 ms/op` -> better
    - `live_entities_bundle_transition`: `6.267 ms/op` -> `6.274 ms/op` -> flat
  - structural churn rerun:
    - `spawn_then_scalar_insert`: `15.544 ms/op` -> `11.726 ms/op` -> better
    - `spawn_bundle_fused`: `2.939 ms/op` -> `2.911 ms/op` -> flat
    - `live_entities_scalar_transition`: `14.180 ms/op` -> `10.522 ms/op` -> better
    - `live_entities_bundle_transition`: `6.267 ms/op` -> `6.335 ms/op` -> flat
  - micro sanity:
    - `component_ptr_const_hit`: `16.629 us/op` -> `16.504 us/op` -> flat
    - `has_component_hit`: `44.060 us/op` -> `44.574 us/op` -> flat/slightly worse
    - `iterator_startup_first_batch_dense`: `11.043 us/op` -> `11.014 us/op` -> flat
- Correctness note:
  - the experiment added an explicit stale-cache test to prove cached target
    archetype indexes are validated against current target keys before reuse,
    so archetype removal and index swaps do not create misrouting bugs.
- Interpretation:
  - this is the first experiment in the loop with a clear and repeatable
    end-to-end win on its target workload without a meaningful regression
    elsewhere. The gain is exactly where expected: scalar structural churn,
    while bundle-oriented paths remain essentially unchanged.
- Next action:
  - promote this change into the main workspace and use the new result as the
    stable baseline for later structural experiments.

### `EXP-006`

- Class: config
- Status: revisit
- Stable base: `db55c19`
- Hypothesis: `empty_chunk_retained_max` materially affects churn-heavy and
  staged-apply workloads because it controls whether recently emptied chunks
  are reused or destroyed between repeated archetype transitions.
- Reasoning: the current stable value is `2`, but the real leverage might
  saturate at `1` or vanish entirely if empty-chunk reuse is not actually
  helping on this machine. The useful comparison set is `0`, `1`, stable `2`,
  and `4`.
- Touched files in throwaway worktree:
  - `packages/static_ecs/benchmarks/structural_churn_baselines.zig`
  - `packages/static_ecs/benchmarks/command_buffer_apply_baselines.zig`
- Benchmark subset:
  - `zig build structural_churn_baselines`
  - `zig build command_buffer_staged_apply_baselines`
- Correctness checks:
  - `zig build check`
- Result summary against the stable `db55c19` baseline
  (`empty_chunk_retained_max = 2`):
  - `0` retained empty chunks:
    - `spawn_then_scalar_insert`: `12.052 ms/op` -> `12.586 ms/op` -> worse
    - `spawn_bundle_fused`: `2.901 ms/op` -> `2.931 ms/op` -> slightly worse
    - `live_entities_scalar_transition`: `10.643 ms/op` -> `18.932 ms/op` -> much worse
    - `live_entities_bundle_transition`: `6.409 ms/op` -> `11.187 ms/op` -> much worse
    - `spawn_bundle_stage_and_apply`: `2.048 ms/op` -> `2.044 ms/op` -> flat
    - `insert_bundle_stage_and_apply`: `2.315 ms/op` -> `2.527 ms/op` -> worse
    - `mixed_spawn_insert_remove_stage_and_apply`: `3.409 ms/op` -> `3.210 ms/op` -> slightly better
  - `1` retained empty chunk:
    - `spawn_then_scalar_insert`: `12.052 ms/op` -> `11.697 ms/op` -> better
    - `spawn_bundle_fused`: `2.901 ms/op` -> `2.921 ms/op` -> flat
    - `live_entities_scalar_transition`: `10.643 ms/op` -> `10.524 ms/op` -> slightly better
    - `live_entities_bundle_transition`: `6.409 ms/op` -> `6.291 ms/op` -> slightly better
    - `spawn_bundle_stage_and_apply`: `2.048 ms/op` -> `2.021 ms/op` -> slightly better
    - `insert_bundle_stage_and_apply`: `2.315 ms/op` -> `2.513 ms/op` -> worse
    - `mixed_spawn_insert_remove_stage_and_apply`: `3.409 ms/op` -> `3.224 ms/op` -> slightly better
  - `4` retained empty chunks:
    - `spawn_then_scalar_insert`: `12.052 ms/op` -> `11.834 ms/op` -> slightly better
    - `spawn_bundle_fused`: `2.901 ms/op` -> `2.919 ms/op` -> flat
    - `live_entities_scalar_transition`: `10.643 ms/op` -> `10.530 ms/op` -> slightly better
    - `live_entities_bundle_transition`: `6.409 ms/op` -> `6.275 ms/op` -> slightly better
    - `spawn_bundle_stage_and_apply`: `2.048 ms/op` -> `2.077 ms/op` -> flat/slightly worse
    - `insert_bundle_stage_and_apply`: `2.315 ms/op` -> `4.565 ms/op` -> much worse and noisy
    - `mixed_spawn_insert_remove_stage_and_apply`: `3.409 ms/op` -> `3.214 ms/op` -> slightly better
- Interpretation:
  - empty-chunk reuse is clearly valuable on this machine; dropping retention to
    `0` is a bad fit for both structural churn and bundle transitions.
  - `1` retained empty chunk is competitive and slightly better for the churn
    owner, but it does not cleanly beat the stable `2` setting across both
    owners because the staged-apply insert case gets worse.
  - `4` retained empty chunks does not show a credible general win and can
    become actively noisy or worse in staged apply.
- Next action:
  - keep the stable config at `2` for now. Revisit this lever only if a future
    benchmark split isolates setup/apply costs more cleanly or if a workload
    specifically prioritizes structural churn over staged command ingestion.

### `EXP-007`

- Class: radical
- Status: discarded
- Stable base: `585a3f5`
- Hypothesis: repeated `world.view(...).iterator()` construction is paying too
  much archetype matching work, so a store-local cached query plan keyed by
  query shape and structural epoch might improve iterator-heavy workloads.
- Reasoning: the current iterator walks archetypes directly from the store for
  every new view. If the matched archetype list is stable between structural
  mutations, reusing it should help `query_scale`, `query_iteration`, and
  `frame_pass`.
- Touched files in throwaway worktree:
  - `packages/static_ecs/src/ecs/archetype_store.zig`
  - `packages/static_ecs/src/ecs/view.zig`
- Benchmark subset:
  - `zig build micro_hotpaths_baselines`
  - `zig build query_iteration_baselines`
  - `zig build query_scale_baselines`
  - `zig build frame_pass_baselines`
- Correctness checks:
  - `zig build check`
- Result summary against the direct stable `585a3f5` reruns from the same
  session, after trimming the first version's accidental full-store invariant
  scan off the hot path:
  - `iterator_startup_first_batch_dense`: `10.977 us/op` -> `16.608 us/op` -> worse
  - `dense_required_reads_single_archetype`: `20.562 us/op` -> `29.786 us/op` -> worse
  - `mixed_optional_health_exclude_tag`: `32.460 us/op` -> `48.393 us/op` -> worse
  - `fragmented_optional_exclude_scan`: `143.239 us/op` -> `205.240 us/op` -> worse
  - `dense_1k_entities_1_archetype`: `42.489 us/op` -> `53.859 us/op` -> worse
  - `dense_16k_entities_1_archetype`: `691.319 us/op` -> `873.650 us/op` -> worse
  - `fragmented_16k_entities_8_archetypes`: `1.105 ms/op` -> `1.390 ms/op` -> worse
  - `fragmented_16k_entities_16_archetypes`: `1.314 ms/op` -> `1.657 ms/op` -> worse
  - `1_pass_4k_entities_1_archetype`: `373.868 us/op` -> `445.379 us/op` -> worse
  - `4_passes_4k_entities_1_archetype`: `747.379 us/op` -> `1.025 ms/op` -> worse
  - `4_passes_16k_entities_8_archetypes`: `3.396 ms/op` -> `4.527 ms/op` -> worse
  - `8_passes_16k_entities_16_archetypes`: `6.888 ms/op` -> `9.798 ms/op` -> worse
- Correctness note:
  - the experiment added a regression test proving that a reused `View`
    refreshes matched archetypes after structural mutation before yielding a
    new iterator, so the discard is performance-only rather than a correctness
    rejection.
- Interpretation:
  - the plan-cache idea in this form is a bad fit. Even with cheap local
    assertions, building and consulting the cached match list is slower than
    letting the current iterator walk archetypes directly.
  - the cache only helps if the reuse cost is lower than the existing scan,
    and that is not true here for the current archetype counts and query
    shapes.
- Measurement note:
  - the first implementation version was much worse because it accidentally
    called the store's full `assertInvariants()` scan on a hot query path.
    That was fixed and rerun before discarding the experiment, but the leaner
    version still regressed every target owner.
- Next action:
  - discard the code change, remove the throwaway worktree, and shift the next
    probe toward either command-buffer attribution-driven tuning or broader
    benchmark coverage instead of a first-class query-plan cache.

### `EXP-014`

- Class: benchmark-only
- Status: promoted
- Stable base: `db55c19`
- Hypothesis: the current `command_buffer_staged_apply_baselines` owner still
  hides materially different costs behind one staged-apply number, especially
  world setup and entity preparation in the insert and mixed cases.
- Reasoning: narrow command-buffer experiments are hard to interpret if the
  benchmark owner includes setup, stage, and apply in one timed region and the
  harness cannot expose manual sub-phase timing boundaries.
- Touched files in throwaway worktree:
  - `build.zig`
  - `packages/static_ecs/benchmarks/command_buffer_phase_baselines.zig`
- Benchmark subset:
  - `zig build check`
  - `zig build command_buffer_phase_baselines`
  - `zig build command_buffer_staged_apply_baselines`
- Correctness checks:
  - `zig build check`
- Result summary:
  - new `command_buffer_phase_baselines` medians:
    - `spawn_only_setup_world_and_buffer`: `24.048 us/op`
    - `insert_only_setup_world_buffer_and_entities`: `635.512 us/op`
    - `mixed_setup_world_buffer_and_entities`: `893.379 us/op`
    - `spawn_only_stage_and_clear`: `39.992 us/op`
    - `insert_only_stage_and_clear`: `37.484 us/op`
    - `mixed_stage_and_clear`: `32.908 us/op`
  - current staged-apply medians in the same worktree:
    - `spawn_bundle_stage_and_apply`: `2.082 ms/op`
    - `insert_bundle_stage_and_apply`: `2.545 ms/op`
    - `mixed_spawn_insert_remove_stage_and_apply`: `3.251 ms/op`
  - derived attribution from the new owner:
    - spawn setup plus stage is about `64 us/op`, so the existing spawn
      staged-apply case is still overwhelmingly apply and world mutation.
    - insert setup plus stage is about `673 us/op`, so setup accounts for a
      large share of the old insert staged-apply number.
    - mixed setup plus stage is about `926 us/op`, so setup also materially
      influences the mixed staged-apply case.
- Environment note:
  - `zig build command_buffer_phase_baselines` hit a sandbox-related Windows
    `Access is denied` process-spawn failure until rerun with elevation, while
    the same code succeeded immediately afterward. The benchmark result is
    valid, but future local worktree runs may need the same elevated retry for
    newly added benchmark steps.
- Interpretation:
  - this benchmark-only experiment improves observability enough to promote.
    It does not solve true apply-only timing, but it closes the practical gap:
    future command-buffer experiments can now separate setup-heavy regressions
    from real stage/apply regressions without changing the harness first.
- Next action:
  - complete the tracked promotion, then continue from the new observability
  surface with either `EXP-007` query-plan caching or `EXP-015`
  frame-pass-benchmark broadening.

### `EXP-015`

- Class: benchmark-only
- Status: promoted
- Stable base: `cbe02d6`
- Hypothesis: the current frame-pass owner still over-averages the workload
  shape. A branch-heavy frame mix and a write-heavy frame mix should be
  measured separately so later ECS tuning can distinguish query/filter
  pressure from column-write pressure.
- Reasoning: `frame_pass_baselines` is useful, but it is still one synthetic
  multi-pass family. Benchmark sets that isolate branch-heavy and write-heavy
  system mixes make future results more interpretable without changing ECS
  behavior.
- Touched files in throwaway worktree:
  - `build.zig`
  - `packages/static_ecs/benchmarks/frame_workload_baselines.zig`
- Benchmark subset:
  - `zig build check`
  - `zig build frame_workload_baselines`
  - `zig build frame_pass_baselines`
- Correctness checks:
  - `zig build check`
- Result summary:
  - new `frame_workload_baselines` medians:
    - `branch_heavy_4_systems_8k_entities_8_archetypes`: `1.690 ms/op`
    - `branch_heavy_8_systems_16k_entities_16_archetypes`: `7.075 ms/op`
    - `write_heavy_4_systems_4k_entities_1_archetype`: `757.557 us/op`
    - `write_heavy_8_systems_16k_entities_8_archetypes`: `5.789 ms/op`
  - existing `frame_pass_baselines` medians in the same worktree for context:
    - `1_pass_4k_entities_1_archetype`: `363.002 us/op`
    - `4_passes_4k_entities_1_archetype`: `734.050 us/op`
    - `4_passes_16k_entities_8_archetypes`: `3.414 ms/op`
    - `8_passes_16k_entities_16_archetypes`: `6.909 ms/op`
- Interpretation:
  - the new owner exposes a real shape distinction. The branch-heavy 16k/16
    case is materially more expensive than the write-heavy 16k/8 case, while
    the write-heavy dense 4k case stays close to the old dense multi-pass
    baseline. That is exactly the added observability this experiment was
    meant to create.
- Measurement note:
  - the first compile surfaced two owner-construction bugs during the
    experiment: inline temporary contexts were too const for the benchmark
    case API, and the group needed explicit `addCase(...)` calls. Both were
    fixed before accepting the owner.
- Environment note:
  - the new benchmark step hit the same Windows throwaway-worktree process
    spawn restriction as other new owners and needed one elevated rerun.
- Next action:
  - promote the owner into the main workspace, update benchmark docs, and keep
    using it alongside `frame_pass_baselines` for future ECS tuning.

### `EXP-016`

- Class: minor
- Status: promoted
- Stable base: `585a3f5`
- Hypothesis: command-buffer bundle staging still wastes time growing the
  payload byte vector one zero byte at a time even after reserving full
  capacity, so replacing that loop with one direct length bump plus bulk
  initialization should materially reduce stage-only cost.
- Reasoning: `command_buffer_phase_baselines` now isolates setup from staging,
  so this narrow change can be judged on the stage slice directly instead of
  relying on noisy staged-apply totals.
- Touched files in throwaway worktree:
  - `packages/static_ecs/src/ecs/command_buffer.zig`
- Benchmark subset:
  - `zig build micro_hotpaths_baselines`
  - `zig build command_buffer_phase_baselines`
  - `zig build command_buffer_staged_apply_baselines`
- Correctness checks:
  - `zig build check`
- Result summary against same-session stable `585a3f5` reruns:
  - micro:
    - `command_buffer_stage_spawn_bundle_single`: `68.323 ns/op` -> `10.339 ns/op` -> much better
  - phase owner run 1:
    - `spawn_only_setup_world_and_buffer`: `22.267 us/op` -> `22.103 us/op` -> flat
    - `insert_only_setup_world_buffer_and_entities`: `620.150 us/op` -> `617.556 us/op` -> flat
    - `mixed_setup_world_buffer_and_entities`: `865.966 us/op` -> `843.659 us/op` -> slightly better
    - `spawn_only_stage_and_clear`: `38.618 us/op` -> `19.862 us/op` -> much better
    - `insert_only_stage_and_clear`: `36.865 us/op` -> `22.253 us/op` -> much better
    - `mixed_stage_and_clear`: `31.773 us/op` -> `23.695 us/op` -> better
  - phase owner rerun:
    - `spawn_only_stage_and_clear`: `38.618 us/op` -> `19.737 us/op` -> much better
    - `insert_only_stage_and_clear`: `36.865 us/op` -> `21.819 us/op` -> much better
    - `mixed_stage_and_clear`: `31.773 us/op` -> `23.885 us/op` -> better
  - staged-apply run 1:
    - `spawn_bundle_stage_and_apply`: `1.998 ms/op` -> `1.987 ms/op` -> flat/slightly better
    - `insert_bundle_stage_and_apply`: `2.469 ms/op` -> `2.445 ms/op` -> flat/slightly better
    - `mixed_spawn_insert_remove_stage_and_apply`: `3.111 ms/op` -> `3.139 ms/op` -> flat/slightly worse
  - staged-apply rerun:
    - `spawn_bundle_stage_and_apply`: `1.998 ms/op` -> `1.986 ms/op` -> flat/slightly better
    - `insert_bundle_stage_and_apply`: `2.469 ms/op` -> `2.447 ms/op` -> flat/slightly better
    - `mixed_spawn_insert_remove_stage_and_apply`: `3.111 ms/op` -> `3.144 ms/op` -> flat/slightly worse
- Interpretation:
  - the one-byte append loop was real staging overhead. Replacing it with one
    direct length bump plus bulk zeroing cuts stage cost sharply and leaves the
    larger staged-apply owner effectively unchanged.
  - this is worth promoting because it is a simple localized improvement with
    a repeatable phase win and no credible end-to-end regression signal.
- Next action:
  - promote the change into the main workspace, validate the same benchmark
    slice there, and use the result as the next stable command-buffer baseline
    if more loop work continues.

### `EXP-020`

- Class: Zig/codegen and benchmark-only
- Status: revisit
- Stable base: `4a5a34b`
- Hypothesis: compile-time and runtime outcomes shift across `ReleaseFast` and
  `ReleaseSafe` enough to expose assertion-heavy or optimizer-sensitive ECS
  paths.
- Reasoning: if the hot ECS slice remains close between the two modes, the next
  levers should stay algorithmic. If the gap is large, some benchmark and
  optimization work needs to treat Zig mode sensitivity as a first-class factor.
- Touched files in throwaway worktree:
  - `build.zig`
  - `packages/static_ecs/benchmarks/query_scale_baselines.zig`
  - `packages/static_ecs/benchmarks/frame_workload_baselines.zig`
- Benchmark subset:
  - `zig build micro_hotpaths_baselines`
  - `zig build query_scale_baselines`
  - `zig build frame_workload_baselines`
- Correctness checks:
  - `zig build check` failed in the throwaway worktree because ignored local
    temporal-support integration files were absent there, so this experiment is
    benchmark-only.
- Result summary:
  - same-session full-budget `ReleaseFast` -> `ReleaseSafe` micro medians:
    - `component_ptr_const_hit`: `17.081 us/op` -> `37.927 us/op` -> `2.22x` slower
    - `has_component_hit`: `45.099 us/op` -> `100.319 us/op` -> `2.22x` slower
    - `iterator_startup_first_batch_dense`: `11.323 us/op` -> `74.652 us/op` -> `6.59x` slower
    - `command_buffer_stage_spawn_bundle_single`: `10.217 ns/op` -> `34.045 ns/op` -> `3.33x` slower
  - reduced-budget `ReleaseFast` context medians for the longer owners:
    - `dense_16k_entities_1_archetype`: `1.292 ms/op`
    - `fragmented_16k_entities_16_archetypes`: `2.819 ms/op`
    - `branch_heavy_8_systems_16k_entities_16_archetypes`: `18.807 ms/op`
    - `write_heavy_8_systems_16k_entities_8_archetypes`: `15.066 ms/op`
- Regressions:
  - even after reducing the local query-scale and frame-workload benchmark
    budgets by `8x` to `16x`, the `ReleaseSafe` versions still failed to finish
    within `244s`, and a rerun of `query_scale_baselines` still failed to
    finish within `604s`.
- Interpretation:
  - Zig optimize mode is a real performance lever for this ECS. The gap is not
    subtle: lookup and command-buffer micro paths roughly double or triple in
    `ReleaseSafe`, and iterator startup becomes multiple times slower.
  - The longer query and system owners are impractical under `ReleaseSafe`
    without a much smaller local budget, which means future performance work
    should avoid over-reading `ReleaseSafe` numbers as if they were production
    behavior.
  - This is not a promotable code change, but it is useful enough to keep as a
    logged result and a prompt for a narrower follow-up on which runtime-safety
    checks dominate the gap.
- Environment note:
  - throwaway worktrees still miss some ignored local temporal-support files,
    so broad correctness validation in these local experiments remains
    incomplete unless those files are copied in first.
- Next action:
  - keep the main tree at `4a5a34b`, discard the temporary build-budget edits,
    and follow up with `EXP-022` to isolate whether iterator invalidation
    guards, invariant scans, or generic query validation account for most of
    the `ReleaseSafe` penalty.

### `EXP-022`

- Class: Zig/codegen and benchmark-only
- Status: promoted
- Stable base: `4a5a34b`
- Hypothesis: the large `ReleaseSafe` gap and part of the `ReleaseFast`
  overhead are driven by invariant walkers that still execute full scans even
  after their internal `assert(...)` checks are stripped.
- Reasoning: many ECS hot paths call `assertInvariants()`, and some of those
  helpers walk entity-location arrays, chunk metadata, or command-buffer
  command lists. If those helpers do real traversal work in `ReleaseFast`, the
  library is paying debug-style scan costs even in production mode.
- Touched files in throwaway worktree:
  - `packages/static_ecs/src/ecs/archetype_key.zig`
  - `packages/static_ecs/src/ecs/archetype_store.zig`
  - `packages/static_ecs/src/ecs/chunk.zig`
  - `packages/static_ecs/src/ecs/command_buffer.zig`
  - `packages/static_ecs/src/ecs/entity_pool.zig`
  - `packages/static_ecs/src/ecs/world.zig`
- Benchmark subset:
  - `zig build micro_hotpaths_baselines`
  - `zig build query_iteration_baselines`
  - `zig build query_scale_baselines`
  - `zig build frame_workload_baselines`
  - promoted-tree follow-up:
    - `zig build command_buffer_phase_baselines`
    - `zig build structural_churn_baselines`
- Correctness checks:
  - promoted tree: `zig build check`
  - promoted tree: `zig build test --summary all`
- Result summary from same-session stable `4a5a34b` runs to the promoted-tree
  `74f66a0` runs:
  - micro:
    - `component_ptr_const_hit`: `16.875 us/op` -> `1.416 ns/op`
    - `has_component_hit`: `44.157 us/op` -> `3.076 ns/op`
    - `iterator_startup_first_batch_dense`: `11.302 us/op` -> `2.869 ns/op`
    - `command_buffer_stage_spawn_bundle_single`: `9.399 ns/op` -> `7.874 ns/op`
  - query iteration:
    - `dense_required_reads_single_archetype`: `20.356 us/op` -> `1.839 us/op`
    - `mixed_optional_health_exclude_tag`: `32.091 us/op` -> `652.441 ns/op`
    - `fragmented_optional_exclude_scan`: `141.175 us/op` -> `2.450 us/op`
  - query scale:
    - `dense_1k_entities_1_archetype`: `42.305 us/op` -> `594.531 ns/op`
    - `dense_16k_entities_1_archetype`: `685.952 us/op` -> `9.521 us/op`
    - `fragmented_16k_entities_8_archetypes`: `1.097 ms/op` -> `15.057 us/op`
    - `fragmented_16k_entities_16_archetypes`: `1.298 ms/op` -> `7.331 us/op`
  - frame workloads:
    - `branch_heavy_4_systems_8k_entities_8_archetypes`: `1.739 ms/op` -> `14.779 us/op`
    - `branch_heavy_8_systems_16k_entities_16_archetypes`: `7.041 ms/op` -> `50.138 us/op`
    - `write_heavy_4_systems_4k_entities_1_archetype`: `751.696 us/op` -> `20.592 us/op`
    - `write_heavy_8_systems_16k_entities_8_archetypes`: `5.685 ms/op` -> `119.740 us/op`
  - promoted-tree follow-up:
    - `command_buffer_phase_baselines.insert_only_setup_world_buffer_and_entities`: `635.018 us/op` -> `79.865 us/op`
    - `command_buffer_phase_baselines.mixed_setup_world_buffer_and_entities`: `856.735 us/op` -> `299.313 us/op`
    - `command_buffer_phase_baselines.spawn_only_stage_and_clear`: `20.064 us/op` -> `1.409 us/op`
    - `structural_churn_baselines.spawn_then_scalar_insert`: `12.052 ms/op` -> `3.041 ms/op`
    - `structural_churn_baselines.live_entities_scalar_transition`: `10.643 ms/op` -> `2.258 ms/op`
- Evidence from code:
  - `packages/static_ecs/src/ecs/archetype_store.zig` `assertInvariants()`
    walked every occupied entity location even in `ReleaseFast`; only the
    nested `assert(...)` checks disappeared.
  - `packages/static_ecs/src/ecs/chunk.zig` and
    `packages/static_ecs/src/ecs/command_buffer.zig` similarly iterated chunk
    metadata and command payload bounds even when runtime safety was off.
  - Hot read/query paths were repeatedly calling those helpers before the real
    work, so production-mode traversal overhead accumulated on every lookup,
    iterator startup, and many world/control-plane operations.
- Interpretation:
  - the assertion-density hypothesis was correct, but the key issue was not
    just the number of `assert(...)` calls. It was the fact that helper
    functions wrapped large validation scans around those asserts, and those
    scans remained live in `ReleaseFast`.
  - Gating the invariant walkers on `std.debug.runtime_safety` preserves the
    debug and `ReleaseSafe` checks while removing the production tax. This is
    a real promoted improvement, not just a benchmark artifact.
  - Some micro cases are now so small that constant-folding and hoisting may
    exaggerate the exact ratio, but the larger query, frame, command-buffer,
    and structural-churn owners confirm that the win is real end to end.
- Next action:
  - keep `74f66a0` as the new stable baseline and continue from there with a
    narrower post-invariant experiment such as `EXP-017` or `EXP-021`.

### `EXP-023`

- Class: benchmark-only plus shared harness
- Status: promoted
- Stable base: `63c733c`
- Branch: `perf/ecs-exp-023`
- Worktree: `.tmp/ecs-perf-exp-023`
- Hypothesis: the current command-buffer attribution surface still leaves true
  apply throughput partially hidden because staged-apply cases include staging
  work and phase cases stop before apply.
- Reasoning: add apply-only command-buffer benchmarks over pre-staged payloads
  so later apply-side tuning can be measured without setup or staging noise.
- Touched packages/files:
  - `packages/static_testing/src/bench/case.zig`
  - `packages/static_testing/src/bench/runner.zig`
  - `packages/static_ecs/benchmarks/command_buffer_apply_only_baselines.zig`
  - `build.zig`
  - package and repo docs
- Benchmark subset:
  - `zig build command_buffer_apply_only_baselines`
  - `zig build command_buffer_phase_baselines`
  - `zig build command_buffer_staged_apply_baselines`
- Correctness checks:
  - `zig build check`
  - `zig build test --summary all`
  - `zig build docs-lint`
- Result summary:
  - `spawn_bundle_apply_only`: new median `23.400 us/op`
  - `insert_bundle_apply_only`: new median `27.300 us/op`
  - `mixed_spawn_insert_remove_apply_only`: new median `32.400 us/op`
  - `spawn_bundle_stage_and_apply`: context median `65.436 us/op`
  - `insert_bundle_stage_and_apply`: context median `95.578 us/op`
  - `mixed_spawn_insert_remove_stage_and_apply`: context median `321.800 us/op`
  - `spawn_only_stage_and_clear`: context median `1.321 us/op`
  - `insert_only_stage_and_clear`: context median `1.853 us/op`
  - `mixed_stage_and_clear`: context median `1.275 us/op`
- Regressions:
  - none in the validated main-tree surface.
- Interpretation:
  - the new owner closes a real attribution gap. Apply-only costs are now
    visible and materially lower than the old staged-apply totals, which means
    later command-buffer tuning can separate world setup, staging, and apply
    work instead of inferring them indirectly.
  - the shared benchmark-case prepare hook is a good lower-package promotion
    because it generalizes beyond ECS and keeps setup outside the timer without
    changing the measured callback contract.
- Next action:
  - keep `75cee81` as the new stable baseline and continue with `EXP-024`
    query-startup attribution or `EXP-021` apply-side dispatch work.
- Cleanup status:
  - throwaway worktree removed after promotion; main workspace committed as
    `75cee81`.

### `EXP-024`: query-startup attribution owner

- Category: benchmark-only
- Status: promoted
- Branch: `perf/ecs-exp-024`
- Worktree: `.tmp/ecs-perf-exp-024`
- Stable base: `75cee81`
- Hypothesis:
  - query startup costs were still under-attributed because the existing query
    owners did not isolate dense first-match, sparse late-match, and zero-match
    iterator startup shapes.
- Change summary:
  - added `query_startup_baselines` as a new ECS benchmark owner and wired it
    through the root benchmark surface.
  - used narrower per-case component universes and an explicit sparse late-match
    world layout so the owner stays below Zig comptime branch limits while
    still exercising distinct startup shapes.
  - raised the owner-local iteration budget above the default ECS benchmark
    config because the startup cases land in the low-nanosecond range.
- Validation commands:
  - `zig build check`
  - `zig build query_startup_baselines`
  - `zig build query_iteration_baselines`
  - `zig build micro_hotpaths_baselines`
  - `zig build docs-lint`
- Result summary:
  - `dense_first_match_startup`: median `2.734 ns/op`
  - `sparse_late_match_startup`: median `2.515 ns/op`
  - `zero_match_startup`: median `3.027 ns/op`
  - `iterator_startup_first_batch_dense`: context median `2.722 ns/op`
- Regressions:
  - none in the validated main-tree surface.
- Interpretation:
  - the owner closes a real observability gap around iterator startup without
    disturbing the existing throughput-focused query owners.
  - zero-match startup is measurably distinct from first-match startup on this
    machine, while sparse late-match remains close enough to the dense startup
    path that future query work can now prove whether a change helps startup,
    scan throughput, or both.
- Next action:
  - keep `845a920` as the new stable baseline and continue with `EXP-025`,
    `EXP-026`, or `EXP-021`.
- Cleanup status:
  - throwaway worktree and branch pending removal after log update.

## Decision rules

- Promote only if the change improves a meaningful slice without unacceptable
  regressions elsewhere.
- Prefer changes that help more than one owner unless the single-owner gain is
  large enough to justify specialization.
- Keep radical experiments isolated; do not mix them with cross-package cleanup
  or benchmark-shape changes in one trial.
- If an experiment needs a new API or calling structure to win, log that
  outcome explicitly and close the throwaway branch instead of letting the API
  exploration drift into an implementation experiment.
- Every retained result must say whether the next action is:
  `promote to main`, `spin out into a new active plan`, or `leave as logged
  research only`.
- If a cross-package change helps ECS but harms the owning package’s generic
  contract, discard it unless the lower package independently wants the same
  capability.
