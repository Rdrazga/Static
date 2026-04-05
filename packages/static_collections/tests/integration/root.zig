//! Integration test root: forces build-time resolution of all test modules.
//! Each import triggers comptime analysis of the corresponding test file,
//! ensuring all integration tests are included in the test binary.
comptime {
    _ = @import("fixed_vec_capacity_order_sequences.zig");
    _ = @import("small_vec_spill_sequences.zig");
    _ = @import("bit_set_boundary_sequences.zig");
    _ = @import("dense_array_runtime_sequences.zig");
    _ = @import("handle_layout_sequences.zig");
    _ = @import("sorted_vec_map_ordered_updates.zig");
    _ = @import("sparse_set_membership_sequences.zig");
    _ = @import("slot_map_runtime_sequences.zig");
    _ = @import("index_pool_runtime_sequences.zig");
    _ = @import("vec_budget_capacity_sequences.zig");
    _ = @import("flat_hash_map_collision_lifecycle.zig");
    _ = @import("min_heap_capacity_order_sequences.zig");
}
