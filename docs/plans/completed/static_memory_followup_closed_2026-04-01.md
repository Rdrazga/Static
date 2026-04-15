# `static_memory` follow-up plan

Scope: budgets, arenas, pools, slabs, and bounded allocation patterns.

Status: follow-up closed on 2026-04-01. The exported-surface proof map is
complete, the misuse-path queue is closed unless a new representable misuse
contract is found, the duplication review is recorded, the canonical benchmark
admission set is narrowed to the one shipped owner, and no shared-harness
extraction candidate is strong enough to justify moving package-local memory
invariants into `static_testing` today.

## Current posture

- `static_memory` now has named proof ownership across the exported root
  surface, including package-owned `testing.model` coverage for `Pool`,
  `Arena`, `Slab`, and `BudgetedAllocator`, direct allocator regressions for
  accounting and misuse boundaries, and explicit over-release failure coverage
  for `Budget.release()`.
- The canonical admitted benchmark set is the shipped
  `pool_alloc_free.alloc_free_cycle` workload in
  `packages/static_memory/benchmarks/pool_alloc_free.zig`, validated through
  `zig build bench` on the shared `baseline.zon` plus `history.binlog` path.
- `slab_reuse_cycle`, `arena_reset_cycle`, and
  `budgeted_allocator_growth_budget_boundary` remain deferred benchmark
  candidates rather than admitted canonical workloads until a concrete review
  signal justifies adding a dedicated executable owner.
- The package-owned model harnesses stay local. Their action tables, state
  contexts, and invariants are allocator-family-specific, while the shared
  runner mechanics already live in `static_testing.testing.model`.

## Open follow-up triggers

- Reopen benchmark admission only if a concrete performance-review need appears
  for slab reuse, arena reset churn, or budget-sensitive allocator growth.
- Reopen shared-harness extraction only if a future memory primitive duplicates
  enough action-table or transition framing that a package-local helper would
  stop being allocator-specific.
- Reopen misuse-path work only if a concrete new representable ownership or
  stale-state boundary is identified.
