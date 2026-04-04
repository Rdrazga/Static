test {
    _ = @import("bvh_boundary_touching_queries.zig");
    _ = @import("bvh_query_aabb_truncation.zig");
    _ = @import("bvh_query_ray_sorted_truncation.zig");
    _ = @import("bvh_query_frustum_truncation.zig");
    _ = @import("bvh_query_ray_truncation.zig");
    _ = @import("incremental_bvh_lifecycle.zig");
    _ = @import("incremental_bvh_model_sequences.zig");
    _ = @import("replay_incremental_bvh_boundary_failures.zig");
}
