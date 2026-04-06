# `static_memory`

Bounded allocators, ownership helpers, and memory-management building blocks for the `static` workspace.

## Current status

- The root workspace build is the supported entry point; package-local `zig build` is not supported.
- `static_memory` covers budgets, arenas, pools, slabs, stacks, scratch scopes, frame guards, growth helpers, and allocator wrappers.
- Package-level model coverage is already in place for pool allocation and reuse, arena reset sequences, slab class reuse, exhaustion, and route validation, and budgeted-allocator runtime sequences.
- The canonical admitted benchmark is `pool_alloc_free`, now covering pool alloc/free plus slab class-routing and fallback alloc/free cases, with review artifacts stored under the shared baseline/history path.

## Main surfaces

- `src/root.zig` exports the package surface and re-exports the allocator and helper modules.
- `src/memory/budget.zig` owns byte accounting, lock-in behavior, and the budgeted allocator wrapper.
- `src/memory/arena.zig` owns the bump arena and reset/reuse contract.
- `src/memory/pool.zig` owns fixed-size block pools and typed pool helpers.
- `src/memory/slab.zig` owns size-class slab allocation, address-ordered free routing, and fallback behavior.
- `src/memory/scratch.zig` and `src/memory/frame_scope.zig` own scoped scratch and stack rollback helpers.
- `src/memory/stack.zig`, `src/memory/growth.zig`, `src/memory/capacity_report.zig`, `src/memory/soft_limit_allocator.zig`, `src/memory/debug_allocator.zig`, `src/memory/profile_hooks.zig`, `src/memory/epoch.zig`, and `src/memory/tls_pool.zig` cover the remaining allocator-policy and support surfaces.

## Validation

- `zig build check`
- `zig build test`
- `zig build bench`
- `zig build examples`
- `zig build docs-lint`

## Key paths

- `tests/integration/root.zig` wires the package-level deterministic regression entry points.
- `tests/integration/pool_model_adoption.zig`
- `tests/integration/arena_model_reset_sequences.zig`
- `tests/integration/slab_model_class_reuse_exhaustion.zig`
- `tests/integration/budgeted_allocator_runtime_sequences.zig`
- `benchmarks/pool_alloc_free.zig` is the canonical benchmark owner and now spans pool and slab alloc/free review cases.
- `benchmarks/support.zig` holds the shared benchmark reporting helpers.
- `examples/typed_pool_basic.zig`
- `examples/scratch_mark_rollback.zig`
- `examples/frame_arena_reset.zig`
- `examples/budget_lock_in.zig`
- `examples/budget_lock_in_embedded.zig`

## Benchmark artifacts

- Benchmark outputs live under `.zig-cache/static_memory/benchmarks/<name>/`.
- Canonical review artifacts use the shared `baseline.zon` plus `history.binlog` pair.
- Re-record the baseline when the workload or measured contract changes materially.
