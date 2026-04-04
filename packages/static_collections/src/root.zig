//! Fixed-capacity collection types and handle-based containers for bounded data management.
//!
//! Each module defines a local `Error` union tailored to its failure modes. The unions
//! overlap intentionally (e.g. `OutOfMemory`, `NoSpaceLeft`) but are not identical,
//! keeping modules independently compilable without a shared error import.

/// Shared memory-budget utilities remain re-exported because multiple
/// collection families use them as part of their public configuration surface.
pub const memory = @import("static_memory");

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
    _ = memory;
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
