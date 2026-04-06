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
### Recently completed queue items

1. `static_ecs`
   The direct-surface hardening reopen is now closed: malformed encoded bundles
   fail through stable operating errors, `World.spawnBundleEncoded()` now
   rejects non-owned entities without desynchronizing `EntityPool` from
   `ArchetypeStore`, and empty-chunk retention accounting now survives
   retained-chunk reuse:
   `docs/plans/completed/static_ecs_direct_surface_hardening_closed_2026-04-05.md`.
2. `static_ecs`
   The performance and memory reopen is now closed:
   bundle-oriented mutation is fused around final-archetype admission,
   `CommandBuffer` now separates metadata from bounded payload bytes, chunk
   storage uses one backing allocation plus bounded empty-chunk retention,
   archetype and append-path chunk lookup now use package-owned fast paths,
   sparse-archetype metadata is compacted, and package-owned ECS benchmark
   review workloads now run under `zig build bench`:
   `docs/plans/completed/static_ecs_performance_and_memory_followup_closed_2026-04-05.md`.
3. `static_ecs`
   The borrowed-view contract and compile-proof follow-up is now closed:
   `View` and `ChunkBatch` are explicit borrowed surfaces with fail-fast
   invalidation under structural mutation in runtime-safety builds, and the
   package now owns representative compile-contract fixtures for its main public
   `@compileError` boundaries:
   `docs/plans/completed/static_ecs_view_contract_and_compile_proof_closed_2026-04-05.md`.
4. `static_ecs`
   The constructor-cleanup follow-up is now closed:
   `ChunkRecord` append-failure rollback is explicit, `World.init()` now
   releases `EntityPool` on partial-init failure, and direct deterministic
   budget-pressure proof now covers both cleanup paths:
   `docs/plans/completed/static_ecs_cleanup_followup_closed_2026-04-05.md`.
5. `static_ecs`
   The direct `ArchetypeStore` hardening reopen is now closed:
   `components_per_archetype_max` validation matches `World`, same-index direct
   spawn aliasing is rejected before mutation, and direct deterministic proof
   now covers empty-chunk and empty-archetype swap reindexing.
6. `workspace_validation_followup`
   Root command semantics are now explicit, the `static_queues` lock-free
   stress proof now matches the queue's non-blocking contention contract, the
   `static_sync` cancel-test cleanup no longer leaves live threads behind on
   failure paths, `zig build harness` now stays success-only, and `zig build
   bench` remains explicitly review-only by default.
7. `static_memory`
   `Budget.release()` now fails fast on over-release in all builds, with direct
   negative coverage proving the panic path.
8. `static_rng`
   `uintBelow()` now keeps an explicit bounded hard-stop contract, backed by a
   pathological-engine proof.
9. `static_spatial`
   `IncrementalBVH` query reporting now matches `BVH` total-hit semantics, with
   truncation behavior locked down in direct coverage.
10. `static_scheduling`
   The stale `static_queues` dependency/import wiring has been removed from the
   package and root build graphs.
11. `static_profile`
   The public `static_core` alias has been removed, the package boundary stays
   narrow, and the package follow-up now lives under `docs/plans/completed/`.
12. `static_collections`
   The `IndexPool` / `SlotMap` free-structure invariant-hardening slice is
   complete, including fail-fast post-mutation checks and multi-node stale
   handle rejection after reuse.
13. `static_hash`
   The streaming `testing.model` slice now covers early finalize plus
   finish-time fallback finalization without inventing unsupported misuse
   semantics.
14. `static_sync`
   The exported-surface proof map is complete and the primitive-specific gap
   queue is now closed, so the package follow-up lives under
   `docs/plans/completed/`.
15. `static_queues`
   The exported-family proof map, root review, helper audit, and package-owned
   deterministic `SpscChannel` coordination queue are complete, so the package
   follow-up now lives under `docs/plans/completed/`.
16. `static_memory`
   The exported-surface proof map, duplication review, benchmark-admission
   decision, and shared-harness extraction review are complete, so the package
   follow-up now lives under `docs/plans/completed/`.
17. `static_scheduling`
   The exported-surface proof map, deterministic gap queue, canonical
   benchmarks, boundary/root review, and shared-harness extraction review are
   complete, so the package follow-up now lives under `docs/plans/completed/`.
18. `static_rng`
    The root export review, cross-architecture portability notes, and
    generator-versus-sampling boundary review are complete, so the package
    follow-up now lives under `docs/plans/completed/`.
19. `static_hash`
    The sequence-harness extraction decision, root-surface contract review, and
    quality-sample telemetry decision are complete, so the package follow-up now
    lives under `docs/plans/completed/` while algorithm-portfolio research stays
    separate.
20. `static_collections`
   The root-surface review is now implemented, the `SmallVec` spill and
   `FlatHashMap.clone` regressions are fixed, the `SlotMap` iterator contract
   is explicit and directly proved, and the first shared benchmark owner
   (`flat_hash_map_lookup_insert_baselines`) is admitted, so the package
   follow-up now lives under `docs/plans/completed/`.
21. `static_collections`
   The reopened validation queue is now closed: `FlatHashMap` overwrite and
   duplicate-reject paths no longer allocate before proving insertion,
   `IndexPool` full invariants again prove free-stack uniqueness, and the
   `MinHeap` / `PriorityQueue` clear plus clone contracts are now explicit and
   directly proved.
22. `static_collections`
    The validated review-fix slice is now closed: `MinHeap` invalidates removed
    tracked indices on `popMin` / `removeAt`, `Vec` split mutable versus const
    item access, `FlatHashMap` now rejects padded default-hash key types unless
    callers provide a custom hash, and `SmallVec.ensureCapacity` reports
    oversized requests as `error.Overflow`.
23. `static_collections`
    The reopened alias/clone/invariant slice is now closed:
    `Vec.appendSliceAssumeCapacity` documents and supports self-alias overlap,
    `FlatHashMap.clone` no longer reads empty-entry storage, and
    `IndexPool.assertFullInvariants` again proves duplicate-free free-stack
    state through a read-only duplicate scan.
24. `static_collections`
    The reopened API-contract and ergonomics follow-up is now closed:
    `Vec` oversized-capacity requests fail as stable `Overflow` operating
    errors before allocator or budget side effects, constructor/runtime error
    naming is normalized across the touched collection families, `SmallVec`,
    `SlotMap`, `SortedVecMap`, and `FlatHashMap` now expose the intended
    public read/reset/iteration parity, and the map plus heap families now
    support additive borrowed lookup helpers with dual by-value or `*const`
    callback signatures where planned.
25. `static_collections`
    The bounded map helper follow-up is now closed: `SortedVecMap` and
    `FlatHashMap` both expose aligned `getOrPut` plus `removeOrNull` helper
    surfaces, `FlatHashMap` keeps the existing-key `getOrPut` path free of
    premature growth work, and the package intentionally stops short of a full
    occupied/vacant entry API.
26. `static_collections`
    The post-review fix slice is now closed: `SmallVec` accepts the valid
    empty-spilled `shrinkToFit()` state without breaking its one-way spill
    boundary, `FlatHashMap` extends the default-hash safety gate from padding
    risk to the broader raw-representation families it can detect at comptime,
    and the `Handle.invalid()` docs now match the real API.
27. `static_collections`
    The testing-surface hardening slice is now closed: the package owns a
    bounded compile-fail harness for the main generic `@compileError`
    validators, `FlatHashMap`, `SortedVecMap`, and `SparseSet` now have
    deterministic `testing.model` runtime-sequence coverage, and
    `SortedVecMap` comparator-signature validation now fires at type
    instantiation to match the new proof surface.
28. `static_ecs`
    The first world-local typed ECS implementation slice is now closed: the
    package owns explicit `WorldConfig` bounds, entity identity, typed
    component-universe admission, `ArchetypeKey`, bounded `Chunk`,
    `ArchetypeStore`, typed query/view chunk-batch iteration, a bounded
    `CommandBuffer`, typed insert/remove helpers that keep value-component
    admission initialized, and a package-owned `testing.model` sequence proof.
    Benchmark posture is recorded as deferred until one chunk-iteration or
    structural-churn workload is stable enough to admit as a canonical shared
    benchmark owner.

### Archived monitor-only follow-up

- `static_core`, `static_meta`, `static_math`, `static_simd`, and
  `static_profile` now live in `docs/plans/completed/` follow-up records and
  should reopen only when a concrete bug class, benchmark signal, or boundary
  mismatch appears.

### Current next queue - concrete unfinished package work

1. `static_spatial`
   Close the bounded-grid query contract mismatch found in the ECS / DoD audit:
   `UniformGrid`, `UniformGrid3D`, and `LooseGrid` still return only the number
   written, while `BVH` and `IncrementalBVH` return total hits under
   truncation. Approved implementation scope: align the bounded grid family to
   total-hit reporting while preserving duplicate semantics, then add matching
   direct proof and docs.
2. `static_collections`
   Reopen for the generic packed-storage follow-up named by the ECS readiness
   review: decide whether `DenseArray` should expose additive relocation
   metadata for swap-remove or keep that policy entirely ECS-owned, then land
   the accepted package-local outcome with direct proof. Approved default:
   close the boundary decision explicitly even if the durable outcome is to
   keep relocation policy in `static_ecs`.
3. `static_hash_batch_shapes`
   Reopen only for generic batch-shaped helpers that clearly improve
   `static_hash` on its own terms without importing ECS vocabulary or depending
   on raw-record layout accidents. Prioritize fold-many `combine` helpers
   first. Approved implementation scope: land the fold-many `combine` helpers
   if the gate still accepts them. Treat any fixed-width canonical-byte record
   primitive as decision-only until the package plan names a non-ECS caller
   story and a representation-safe input contract.
4. `static_hash_algorithm_portfolio_research`
   Keep the algorithm-portfolio work isolated as a lower-priority research
   sidecar while the implementation queue above closes package-local proof,
   contract, and benchmark-definition work. Extend the scenario matrix and
   package-boundary notes with the ECS-signature, short-key, and fixed-schema
   repeated-record workloads found in the DoD audit.

### Parallelism guidance

- The current package-fix front is the `static_spatial` bounded-grid contract
  alignment, followed by the reopened `static_collections` packed-storage
  boundary decision. `static_hash_batch_shapes` remains below those two and
  should only advance when its generic-helper gate accepts an exact helper
  shape.
- `static_hash_algorithm_portfolio_research` stays below the implementation
  queue as a research sidecar and should not preempt the concrete helper work
  above.
- `static_ecs` performance, memory-shape, config-truthfulness, borrowed-view,
  benchmark-admission, and direct-surface hardening work is now closed under
  the 2026-04-05 follow-up records. Keep runtime-erased query, import/export,
  scheduler ownership, and spatial-adapter work closed unless a separate
  concrete trigger appears.
- Lower-package outcomes still matter for follow-on ECS work, but they no
  longer block opening the package plan. `static_ecs` v1 should not depend on a
  `DenseArray` relocation helper, a fixed-width repeated-record hash helper, or
  first-slice spatial adapters.
- Do not reopen the archived monitor-only package plans without a concrete
  trigger.
