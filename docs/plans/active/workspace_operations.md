# Workspace Operations Plan

This file tracks only active cross-package work. Completed package reviews,
finished feature plans, and trigger-only follow-up belong in
`docs/plans/completed/`.

## Operating rules

- Record new cross-package work here and in the matching package or feature
  plan.
- Keep `docs/plans/active/` limited to plans with concrete unfinished work.
- Archive plans as soon as they only describe historical status or reopen
  conditions.
- Define the validation command before implementation starts.
- Prefer package-local fixes first; escalate to cross-package work only when a
  shared boundary is the real issue.

## Priority order

1. Keep `static_testing` usable and stable. Record newly discovered harness
   improvements in plan docs, but do not broaden the shared testing surface in
   the middle of unrelated package slices unless the package is blocked.
2. Keep package architecture extendable before growing features. Boundary,
   naming, and root-surface cleanup outrank additive convenience exports while
   API stability is still flexible.
3. Keep package usage self-explanatory. When names or layout are not enough,
   tighten package docs and Zig doc comments in the same slice.
4. Keep data-oriented design, bounded behavior, explicit control flow, and
   cross-OS / cross-CPU awareness visible in planning and review decisions.
5. Keep active work aligned with `docs/reference/zig_coding_rules.md`. When a
   slice changes assertions, comments, QA surface, refactor debt, or workflow,
   record the matching cleanup explicitly in the plan instead of leaving it as
   implied review work.

## Ordered SMART workspace tasks

1. `Plan hygiene`
   Keep `docs/plans/active/` limited to plans with concrete unfinished work.
   Done when monitor-only or trigger-only package notes are archived into
   `docs/plans/completed/` and `docs/plans/active/packages/` contains only
   current implementation queues.
2. `SMART task structure`
   Keep every active plan expressed as ordered SMART steps instead of generic
   backlog bullets. Done when each active plan names the exact surface being
   changed, the completion signal, and the validation command for the next
   unfinished slice.
3. `Shared testing first`
   Use downstream package work to validate and harden shared `static_testing`
   boundaries before adding new package-local harness infrastructure. Done when
   each new package slice either points at an existing shared testing surface
   or records why direct tests are the better fit.
4. `Review baseline discipline`
   Use the relevant package review and follow-up closure record under
   `docs/plans/completed/` as the reopen baseline. Done when package follow-up
   only reopens after a concrete boundary change, bug class, or benchmark
   signal is named in the plan.
5. `Benchmark admission discipline`
   Promote only stable, bounded benchmark cases into workspace-level commands.
   Done when each promoted benchmark has a named owner, workload definition,
   and shared `bench.workflow` validation path recorded in the relevant plan.
6. `Boundary escalation discipline`
   Revisit cross-package boundaries only when an active package plan names a
   concrete ownership mismatch around memory, queues, scheduling, I/O,
   serialization, or testing. Done when cross-package work starts from an
   explicit mismatch statement rather than a vague cleanup goal.

## Implementation order

Validation command for plan updates and sequencing changes:

- `zig build docs-lint`

Scope note:

- Use the relevant package review and follow-up closure record under
  `docs/plans/completed/` as the active reopen baseline for this queue.

### Active cross-package toolchain work

No active cross-package toolchain migrations are open. Reopen this section only
when a concrete repo-wide toolchain change has unfinished work.

### Active cross-package documentation work

1. `package_docs_alignment`
   The repo is standardizing package-local `README.md` and `AGENTS.md`
   coverage across every `packages/static_*` directory.
   Active plan:
   - `docs/plans/active/package_docs_alignment.md`
   Current implementation scope:
   - add the missing package doc pairs;
   - align existing package doc pairs to one shared structure;
   - codify the package-doc contract in repo rules;
   - extend docs lint so the package-root entry-point docs stay enforced.
2. `repo_doc_audit_and_alignment`
   The repo is reviewing the markdown and `AGENTS.md` surface after the
   package-doc rollout so structure, references, and command semantics stay
   truthful.
   Active plan:
   - `docs/plans/active/repo_doc_audit_and_alignment.md`
   Current implementation scope:
   - audit root docs, package doc pairs, plan/index docs, and sketch docs;
   - validate findings against the actual tree before editing;
   - apply bounded factual fixes rather than style churn;
   - close with `zig build docs-lint`.

### Active cross-package design review work

1. `zig_0_16_0_design_alignment_review`
   The repo is reviewing every `static_*` package against the Zig `0.16.0`
   design takeaways that best match this workspace's own ideology: explicit
   ambient-state injection, caller-owned allocation policy, explicit binary
   layout, pointer-free packed metadata, explicit comptime boundaries,
   timeout-bounded host tests, and clearer resource naming.
   Active plan:
   - `docs/plans/active/zig_0_16_0_design_alignment_review.md`
   Supporting sketch:
   - `docs/sketches/zig_0_16_0_design_ideology_adoption_map_2026-04-14.md`
   Current implementation scope:
   - review every package against one shared rubric;
   - record no-change, doc-only, or implementation outcomes per package;
   - open bounded package or feature plans only for real deltas;
   - close with a completed review record and an updated active queue.

### Recently completed queue items

Latest closure:

- `zig_0_16_0_stable_migration`
  The Zig stable migration is now closed: the workspace baseline is on tagged
  Zig `0.16.0`, the supported root validation surface passes on stable
  (`docs-lint`, `check`, and `ci`), ECS and Windows stable-surface fallout are
  resolved, and the retained adoption notes are captured in
  `docs/plans/completed/zig_0_16_0_stable_migration_closed_2026-04-14.md`.
- `static_sync`
  The focused runtime and benchmark follow-up is now closed: the `condvar`
  benchmark source bug is fixed, `cancel` registration-path churn is reduced
  without changing the package's slot-order model, polling-fallback and
  watchdog loops now use phased backoff rather than pure aggressive spin,
  single-permit semaphore wakeups no longer broadcast, and the package
  validation plus benchmark surfaces are rechecked under the same closure:
  `docs/plans/completed/static_sync_runtime_and_benchmark_followup_closed_2026-04-11.md`.

1. `static_memory`
   The validated slab `ReleaseFast` follow-up is now closed: `Slab` no longer
   runs the full invariant walk outside runtime-safety builds, `free()` now
   routes through an address-ordered class index instead of a linear class
   scan, and the canonical memory benchmark owner now covers slab class and
   fallback alloc/free review beside the pool case:
   `docs/plans/completed/static_memory_releasefast_slab_followup_closed_2026-04-06.md`.
2. `static_collections`
   The validated `ReleaseFast` invariant follow-up is now closed:
   `IndexPool`, `MinHeap`, `SlotMap`, `SparseSet`, and `SortedVecMap` now
   short-circuit their full invariant walks outside runtime-safety builds, and
   the package now owns the admitted `collections_hotpaths` mutation benchmark
   owner:
   `docs/plans/completed/static_collections_releasefast_invariant_followup_closed_2026-04-06.md`.
3. `static_hash`
   The benchmark observability follow-up is now closed: the canonical
   benchmark semantic preflights are now safety-mode-only, and
   `quality_samples` now records shared `baseline.zon` plus `history.binlog`
   artifacts:
   `docs/plans/completed/static_hash_benchmark_observability_followup_closed_2026-04-06.md`.
4. `static_ecs`
   The allocator-strategy review is now closed: ECS keeps the caller-supplied
   allocator boundary, the package now owns an admitted
   `allocator_strategy_baselines` owner, and the benchmark surface directly
   compares typed bundle admission against the direct encoded route under
   different caller allocators:
   `docs/plans/completed/static_ecs_allocator_strategy_review_closed_2026-04-06.md`.
5. `static_ecs`
   The benchmark truthfulness follow-up is now closed: root bench wiring now
   compiles the imported ECS and `static_testing` modules under the same
   `ReleaseFast` mode benchmark history records, the command-buffer owner is
   explicitly staged-apply throughput instead of apply-only, and
   `structural_churn_baselines` now uses a reduced rerun budget while keeping
   the scalar-versus-bundle signal:
   `docs/plans/completed/static_ecs_benchmark_truthfulness_followup_closed_2026-04-05.md`.
6. `static_ecs`
   The admitted ECS benchmark matrix expansion is now closed: the package now
   owns microbenchmarks for primitive hot paths, query-scale workloads across
   entity and archetype counts, frame-like sequential ECS pass runs, a
   long-form production benchmark backlog sketch, and direct named benchmark
   build steps for the admitted ECS owners:
   `docs/plans/completed/static_ecs_benchmark_matrix_expansion_closed_2026-04-05.md`.
7. `static_ecs`
   The encoded-bundle portability and command-buffer staging reopen is now
   closed: direct encoded-bundle validation now tolerates misaligned caller
   slices, the public route now documents payload bytes as same-process
   bit-valid staging input, failed bundle staging rolls payload usage back, and
   the typed bundle helpers plus command-buffer staging no longer materialize
   stack scratch sized by encoded bundle bytes:
   `docs/plans/completed/static_ecs_bundle_portability_and_command_buffer_followup_closed_2026-04-05.md`.
8. `static_ecs`
   The direct-surface hardening reopen is now closed: malformed encoded bundles
   fail through stable operating errors, `World.spawnBundleEncoded()` now
   rejects non-owned entities without desynchronizing `EntityPool` from
   `ArchetypeStore`, and empty-chunk retention accounting now survives
   retained-chunk reuse:
   `docs/plans/completed/static_ecs_direct_surface_hardening_closed_2026-04-05.md`.
9. `static_ecs`
   The performance and memory reopen is now closed:
   bundle-oriented mutation is fused around final-archetype admission,
   `CommandBuffer` now separates metadata from bounded payload bytes, chunk
   storage uses one backing allocation plus bounded empty-chunk retention,
   archetype and append-path chunk lookup now use package-owned fast paths,
   sparse-archetype metadata is compacted, and package-owned ECS benchmark
   review workloads now run under `zig build bench`:
   `docs/plans/completed/static_ecs_performance_and_memory_followup_closed_2026-04-05.md`.
10. `static_ecs`
   The borrowed-view contract and compile-proof follow-up is now closed:
   `View` and `ChunkBatch` are explicit borrowed surfaces with fail-fast
   invalidation under structural mutation in runtime-safety builds, and the
   package now owns representative compile-contract fixtures for its main public
   `@compileError` boundaries:
   `docs/plans/completed/static_ecs_view_contract_and_compile_proof_closed_2026-04-05.md`.
11. `static_ecs`
   The constructor-cleanup follow-up is now closed:
   `ChunkRecord` append-failure rollback is explicit, `World.init()` now
   releases `EntityPool` on partial-init failure, and direct deterministic
   budget-pressure proof now covers both cleanup paths:
   `docs/plans/completed/static_ecs_cleanup_followup_closed_2026-04-05.md`.
12. `static_ecs`
   The direct `ArchetypeStore` hardening reopen is now closed:
   `components_per_archetype_max` validation matches `World`, same-index direct
   spawn aliasing is rejected before mutation, and direct deterministic proof
   now covers empty-chunk and empty-archetype swap reindexing.
13. `workspace_validation_followup`
   Root command semantics are now explicit, the `static_queues` lock-free
   stress proof now matches the queue's non-blocking contention contract, the
   `static_sync` cancel-test cleanup no longer leaves live threads behind on
   failure paths, `zig build harness` now stays success-only, and `zig build
   bench` remains explicitly review-only by default.
14. `static_memory`
   `Budget.release()` now fails fast on over-release in all builds, with direct
   negative coverage proving the panic path.
15. `static_rng`
   `uintBelow()` now keeps an explicit bounded hard-stop contract, backed by a
   pathological-engine proof.
16. `static_spatial`
   `IncrementalBVH` query reporting now matches `BVH` total-hit semantics, with
   truncation behavior locked down in direct coverage.
17. `static_scheduling`
   The stale `static_queues` dependency/import wiring has been removed from the
   package and root build graphs.
18. `static_profile`
   The public `static_core` alias has been removed, the package boundary stays
   narrow, and the package follow-up now lives under `docs/plans/completed/`.
19. `static_collections`
   The `IndexPool` / `SlotMap` free-structure invariant-hardening slice is
   complete, including fail-fast post-mutation checks and multi-node stale
   handle rejection after reuse.
20. `static_hash`
   The streaming `testing.model` slice now covers early finalize plus
   finish-time fallback finalization without inventing unsupported misuse
   semantics.
21. `static_sync`
   The exported-surface proof map is complete and the primitive-specific gap
   queue is now closed, so the package follow-up lives under
   `docs/plans/completed/`.
22. `static_queues`
   The exported-family proof map, root review, helper audit, and package-owned
   deterministic `SpscChannel` coordination queue are complete, so the package
   follow-up now lives under `docs/plans/completed/`.
23. `static_memory`
   The exported-surface proof map, duplication review, benchmark-admission
   decision, and shared-harness extraction review are complete, so the package
   follow-up now lives under `docs/plans/completed/`.
24. `static_scheduling`
   The exported-surface proof map, deterministic gap queue, canonical
   benchmarks, boundary/root review, and shared-harness extraction review are
   complete, so the package follow-up now lives under `docs/plans/completed/`.
25. `static_rng`
    The root export review, cross-architecture portability notes, and
    generator-versus-sampling boundary review are complete, so the package
    follow-up now lives under `docs/plans/completed/`.
26. `static_hash`
    The sequence-harness extraction decision, root-surface contract review, and
    quality-sample telemetry decision are complete, so the package follow-up now
    lives under `docs/plans/completed/` while algorithm-portfolio research stays
    separate.
27. `static_collections`
   The root-surface review is now implemented, the `SmallVec` spill and
   `FlatHashMap.clone` regressions are fixed, the `SlotMap` iterator contract
   is explicit and directly proved, and the first shared benchmark owner
   (`flat_hash_map_lookup_insert_baselines`) is admitted, so the package
   follow-up now lives under `docs/plans/completed/`.
28. `static_collections`
   The reopened validation queue is now closed: `FlatHashMap` overwrite and
   duplicate-reject paths no longer allocate before proving insertion,
   `IndexPool` full invariants again prove free-stack uniqueness, and the
   `MinHeap` / `PriorityQueue` clear plus clone contracts are now explicit and
   directly proved.
29. `static_collections`
    The validated review-fix slice is now closed: `MinHeap` invalidates removed
    tracked indices on `popMin` / `removeAt`, `Vec` split mutable versus const
    item access, `FlatHashMap` now rejects padded default-hash key types unless
    callers provide a custom hash, and `SmallVec.ensureCapacity` reports
    oversized requests as `error.Overflow`.
30. `static_collections`
    The reopened alias/clone/invariant slice is now closed:
    `Vec.appendSliceAssumeCapacity` documents and supports self-alias overlap,
    `FlatHashMap.clone` no longer reads empty-entry storage, and
    `IndexPool.assertFullInvariants` again proves duplicate-free free-stack
    state through a read-only duplicate scan.
31. `static_collections`
    The reopened API-contract and ergonomics follow-up is now closed:
    `Vec` oversized-capacity requests fail as stable `Overflow` operating
    errors before allocator or budget side effects, constructor/runtime error
    naming is normalized across the touched collection families, `SmallVec`,
    `SlotMap`, `SortedVecMap`, and `FlatHashMap` now expose the intended
    public read/reset/iteration parity, and the map plus heap families now
    support additive borrowed lookup helpers with dual by-value or `*const`
    callback signatures where planned.
32. `static_collections`
    The bounded map helper follow-up is now closed: `SortedVecMap` and
    `FlatHashMap` both expose aligned `getOrPut` plus `removeOrNull` helper
    surfaces, `FlatHashMap` keeps the existing-key `getOrPut` path free of
    premature growth work, and the package intentionally stops short of a full
    occupied/vacant entry API.
33. `static_collections`
    The post-review fix slice is now closed: `SmallVec` accepts the valid
    empty-spilled `shrinkToFit()` state without breaking its one-way spill
    boundary, `FlatHashMap` extends the default-hash safety gate from padding
    risk to the broader raw-representation families it can detect at comptime,
    and the `Handle.invalid()` docs now match the real API.
34. `static_collections`
    The testing-surface hardening slice is now closed: the package owns a
    bounded compile-fail harness for the main generic `@compileError`
    validators, `FlatHashMap`, `SortedVecMap`, and `SparseSet` now have
    deterministic `testing.model` runtime-sequence coverage, and
    `SortedVecMap` comparator-signature validation now fires at type
    instantiation to match the new proof surface.
35. `static_ecs`
    The first world-local typed ECS implementation slice is now closed: the
    package owns explicit `WorldConfig` bounds, entity identity, typed
    component-universe admission, `ArchetypeKey`, bounded `Chunk`,
    `ArchetypeStore`, typed query/view chunk-batch iteration, a bounded
    `CommandBuffer`, typed insert/remove helpers that keep value-component
    admission initialized, and a package-owned `testing.model` sequence proof.
    Benchmark posture is recorded as deferred until one chunk-iteration or
    structural-churn workload is stable enough to admit as a canonical shared
    benchmark owner.
36. `static_ecs`
    The benchmark review and expansion reopen is now closed: the admitted ECS
    benchmark owners now distinguish dense versus fragmented query iteration,
    initial versus live-entity structural churn, and spawn-heavy versus
    insert-heavy versus mixed command-buffer apply while staying on the shared
    `static_testing.bench.workflow` path with bounded environment-tag
    metadata:
    `docs/plans/completed/static_ecs_benchmark_review_and_expansion_closed_2026-04-05.md`.

### Archived monitor-only follow-up

- `static_core`, `static_meta`, `static_math`, `static_simd`, and
  `static_profile` now live in `docs/plans/completed/` follow-up records and
  should reopen only when a concrete bug class, benchmark signal, or boundary
  mismatch appears.

### Current next queue - concrete unfinished package work

1. `static_sync`
   Reopen narrowly for the remaining performance experiments named by
   `docs/sketches/static_sync_remaining_performance_opportunities_2026-04-11.md`.
   Approved implementation scope:
   - prototype a bounded `cancel` slot-acquisition improvement that preserves
     the current lowest-slot allocation behavior;
   - prototype a `wait_queue` cancel-wake path that reduces or removes
     timeout-budget poll slicing when cancel registration succeeds;
   - add only the benchmark attribution and proof extensions needed to decide
     whether to keep or revert the experiments;
   - keep higher-level runtime policy and broader API growth out of scope.
   Active plan:
   - `docs/plans/active/packages/static_sync_remaining_perf_experiments.md`
2. `static_spatial`
   Keep the bounded-grid contract mismatch and the new benchmark/testing audit
   hardening open together. Approved implementation scope:
   - align `UniformGrid`, `UniformGrid3D`, and `LooseGrid` to the total-hit
     reporting contract already used by `BVH` and `IncrementalBVH`;
   - broaden package-owned benchmark coverage beyond the single BVH owner and
     add workload-shape observability fields;
   - add allocator-failure, malformed-geometry, retained replay, and broader
     package-level hostile-proof for the non-BVH spatial families;
   - keep downstream ECS, renderer, and scheduler ownership out of scope.
   Active plans:
   - `docs/plans/active/packages/static_spatial.md`
   - `docs/plans/active/packages/static_spatial_benchmark_and_testing_hardening.md`
3. `static_collections`
   Keep the generic packed-storage boundary decision and the new benchmark or
   testing hardening audit open together. Approved implementation scope:
   - decide whether `DenseArray` should expose additive relocation metadata for
     swap-remove or keep that policy entirely ECS-owned;
   - broaden benchmark coverage and observability across the unrepresented
     collection families;
   - add retained replay, systematic allocator-failure, and repeated-pressure
     proof where the current package still relies on direct fixtures alone;
   - keep ECS vocabulary and higher-layer relocation policy out of scope.
   Active plans:
   - `docs/plans/active/packages/static_collections.md`
   - `docs/plans/active/packages/static_collections_benchmark_and_testing_hardening.md`
4. `static_ecs`
   Reopen for benchmark and testing hardening named by
   `docs/sketches/static_ecs_benchmark_and_testing_review_2026-04-11.md`.
   Approved implementation scope:
   - expand ECS benchmark observability beyond elapsed-time-only reporting;
   - add the missing removal-heavy, relocation-heavy, capacity-edge, and
     allocator/control-plane benchmark owners under the shared bench workflow;
   - adopt retained replay, generated malformed-input coverage,
     `testing.model`, and retained failure bundles where they fit the current
     ECS input and mutation boundaries;
   - add systematic allocator-failure, budget-pressure, and hard-bound
     saturation proof;
   - keep runtime-erased query, import/export, scheduler ownership, and
     spatial-adapter work out of scope.
   Active plan:
   - `docs/plans/active/packages/static_ecs_benchmark_and_testing_hardening.md`
5. `static_hash_batch_shapes`
   Reopen only for generic batch-shaped helpers that clearly improve
   `static_hash` on its own terms without importing ECS vocabulary or depending
   on raw-record layout accidents. Prioritize fold-many `combine` helpers
   first. Approved implementation scope: land the fold-many `combine` helpers
   if the gate still accepts them. Treat any fixed-width canonical-byte record
   primitive as decision-only until the package plan names a non-ECS caller
   story and a representation-safe input contract.
6. `static_hash_algorithm_portfolio_research`
   Keep the algorithm-portfolio work isolated as a lower-priority research
   sidecar while the implementation queue above closes package-local proof,
   contract, and benchmark-definition work. Extend the scenario matrix and
   package-boundary notes with the ECS-signature, short-key, and fixed-schema
   repeated-record workloads found in the DoD audit.

### Parallelism guidance

- `static_sync` is reopened narrowly for the remaining performance
  experiments. Keep the scope limited to the `cancel` slot-acquisition path,
  the `wait_queue` cancel-wake path, and the minimum benchmark or proof work
  needed to keep or revert those experiments. If the prototype weakens the
  current hostile-runtime proof posture or regresses the named benchmark
  owners, prefer reverting rather than broadening the reopen.
- `static_spatial` is next after the narrow `static_sync` experiment reopen.
  Within the
  package, land the bounded-grid contract fix before broadening the benchmark
  matrix unless a concrete spatial regression signal forces the order to flip.
- `static_collections` remains immediately after `static_spatial`. Within the
  package, close the `DenseArray` relocation boundary decision before
  broadening the wider benchmark or retained-failure matrix unless a concrete
  collection regression or bug class preempts it.
- `static_hash_batch_shapes` remains below that active queue and should
  only advance when its generic-helper gate accepts an exact helper shape.
- `static_hash_algorithm_portfolio_research` stays below the implementation
  queue as a research sidecar and should not preempt the concrete helper work
  above.
- `static_ecs` is now explicitly reopened for benchmark and testing hardening
  through `docs/plans/active/packages/static_ecs_benchmark_and_testing_hardening.md`,
  but it sits below `static_spatial` and `static_collections` because the
  current ECS reopen is broad hardening work rather than a known root-surface
  crash or contract mismatch.
- `static_ecs` performance, memory-shape, config-truthfulness, borrowed-view,
  benchmark-admission, and direct-surface hardening work remains closed under
  the 2026-04-05 follow-up records as the reopen baseline. Keep
  runtime-erased query, import/export, scheduler ownership, and spatial-adapter
  work closed unless a separate concrete trigger appears.
- Lower-package outcomes still matter for follow-on ECS work, but they no
  longer block opening the package plan. `static_ecs` v1 should not depend on a
  `DenseArray` relocation helper, a fixed-width repeated-record hash helper, or
  first-slice spatial adapters.
- Do not reopen the archived monitor-only package plans without a concrete
  trigger.
