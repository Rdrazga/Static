//! Fixed-capacity collection types and handle-based containers for bounded data management.

pub const core = @import("static_core");
pub const memory = @import("static_memory");
pub const hash = @import("static_hash");

pub const vec = @import("collections/vec.zig");
pub const fixed_vec = @import("collections/fixed_vec.zig");
pub const small_vec = @import("collections/small_vec.zig");
pub const bit_set = @import("collections/bit_set.zig");
pub const dense_array = @import("collections/dense_array.zig");
pub const handle = @import("collections/handle.zig");
pub const index_pool = @import("collections/index_pool.zig");
pub const slot_map = @import("collections/slot_map.zig");
pub const flat_hash_map = @import("collections/flat_hash_map.zig");
pub const sorted_vec_map = @import("collections/sorted_vec_map.zig");
pub const sparse_set = @import("collections/sparse_set.zig");
pub const min_heap = @import("collections/min_heap.zig");

test {
    // Goal: compile-import every public module so each file's inline tests run.
    // Method: reference each re-exported module to force build-time resolution.
    _ = core;
    _ = memory;
    _ = hash;
    _ = vec;
    _ = fixed_vec;
    _ = small_vec;
    _ = bit_set;
    _ = dense_array;
    _ = handle;
    _ = index_pool;
    _ = slot_map;
    _ = flat_hash_map;
    _ = sorted_vec_map;
    _ = sparse_set;
    _ = min_heap;
}
