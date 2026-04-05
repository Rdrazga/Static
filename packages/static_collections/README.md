# `static_collections`

Bounded fixed-capacity and allocation-aware collection types for the `static`
workspace.

## Current status

- The root workspace build is the supported entry point; package-local
  `zig build` is not the supported validation path.
- The package owns deterministic runtime-sequence coverage for the core
  collection families, including `SlotMap`, `IndexPool`, `Vec`,
  `FlatHashMap`, `SortedVecMap`, `SparseSet`, `SmallVec`, `MinHeap`,
  `DenseArray`, `FixedVec`, and `BitSet`.
- The package also owns a negative compile-contract harness for the main
  generic rejection boundaries, including invalid comparator/hash signatures
  and the padded-key default-hash gate.
- Shared benchmark adoption is in place for `flat_hash_map` lookup-hit and
  insert/remove churn review workloads.

## Main surfaces

- `src/root.zig` exports the package API.
- `src/collections/bit_set.zig` owns bounded bit-set operations and boundary
  handling.
- `src/collections/dense_array.zig` owns dense storage and relocation
  bookkeeping.
- `src/collections/fixed_vec.zig`, `src/collections/vec.zig`, and
  `src/collections/small_vec.zig` own the bounded vector variants.
- `src/collections/flat_hash_map.zig` and
  `src/collections/sorted_vec_map.zig` own the map families and their borrowed
  lookup/removal helpers.
- `src/collections/min_heap.zig` owns heap ordering and tracked-index
  invalidation.
- `src/collections/slot_map.zig`, `src/collections/index_pool.zig`, and
  `src/collections/handle.zig` own handle-based storage and invalidation.
- `src/collections/sparse_set.zig` owns sparse/dense membership tracking.
- `tests/integration/root.zig` wires the package-level deterministic runtime
  coverage.
- `tests/compile_fail/build.zig` wires the package-owned compile-contract
  fixtures.
- `benchmarks/` holds the canonical shared-workflow benchmark entry points.
- `examples/` holds bounded usage examples; examples are not the canonical
  regression surface.

## Validation

- `zig build check`
- `zig build test`
- `zig build bench`
- `zig build examples`
- `zig build docs-lint`

## Key paths

- `tests/integration/flat_hash_map_runtime_sequences.zig` and
  `tests/integration/flat_hash_map_collision_lifecycle.zig` cover map
  mutation sequences and collision-heavy behavior.
- `tests/integration/slot_map_runtime_sequences.zig`,
  `tests/integration/index_pool_runtime_sequences.zig`, and
  `tests/integration/handle_layout_sequences.zig` cover handle-based storage
  contracts.
- `tests/integration/vec_budget_capacity_sequences.zig`,
  `tests/integration/fixed_vec_capacity_order_sequences.zig`, and
  `tests/integration/small_vec_spill_sequences.zig` cover bounded vector
  behavior.
- `tests/integration/sorted_vec_map_runtime_sequences.zig`,
  `tests/integration/sorted_vec_map_ordered_updates.zig`, and
  `tests/integration/min_heap_capacity_order_sequences.zig` cover ordering and
  comparator-sensitive behavior.
- `tests/compile_fail/fixtures/` holds the comptime rejection fixtures.
- `benchmarks/flat_hash_map_lookup_insert_baselines.zig` is the canonical
  benchmark entry point for the shared lookup/insert-remove review workflow.
- `examples/` shows minimal bounded usage of the main collection families.

## Benchmark artifacts

- Benchmark outputs live under
  `.zig-cache/static_collections/benchmarks/<name>/`.
- Canonical review artifacts stay on shared `baseline.zon` plus
  `history.binlog`.
- Re-record baselines when a workload, capacity bound, or mutation pattern
  changes materially.
