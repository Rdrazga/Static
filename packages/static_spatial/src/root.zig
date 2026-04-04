//! `static_spatial`: geometry primitives plus spatial indexing structures.
//!
//! This package is topic-oriented. It intentionally contains two runtime-policy
//! families under one spatial domain:
//!
//! - bounded or build-once structures such as `UniformGrid`, `UniformGrid3D`,
//!   `LooseGrid`, and `BVH`;
//! - dynamic structures such as `SparseGrid`, `SparseGrid3D`, and
//!   `IncrementalBVH` whose mutation paths may allocate.
//!
//! Package center:
//!
//! - `UniformGrid3D` and `BVH` are the primary broad-phase story for bounded
//!   or build-once workloads;
//! - `IncrementalBVH` remains the explicit dynamic option when mutation matters
//!   more than steady-state boundedness.
//!
//! The package root must not imply one allocation model for every structure.
//! Check each module's allocation profile before choosing it for a hot path.
//!
//! Allocation model by family:
//!
//! - primitives are pure data: no hidden state, no allocation, thread-safe by construction;
//! - bounded/build-once structures allocate during `init` or `build`, then query without further allocation;
//! - dynamic structures may allocate during inserts or other mutation operations and are intended for control-plane or sparse-world use.
//!
//! All acceleration structures are single-threaded and require external synchronization.
//!
//! Validation policy:
//!
//! - constructors (`init`, `fromCenterExtent`, and similar) enforce invariants
//!   with `std.debug.assert`; violating those preconditions is a programmer bug;
//! - `tryInit` variants return `?T` for boundary-facing construction from external data;
//! - operational methods (`insert`, `query`, `build`, `refit`) use error unions
//!   for operating errors such as allocation failure or capacity exhaustion.

pub const primitives = @import("spatial/primitives.zig");
pub const morton = @import("spatial/morton.zig");
pub const uniform_grid = @import("spatial/uniform_grid.zig");
pub const uniform_grid_3d = @import("spatial/uniform_grid_3d.zig");
pub const sparse_grid = @import("spatial/sparse_grid.zig");
pub const loose_grid = @import("spatial/loose_grid.zig");
pub const bvh = @import("spatial/bvh.zig");
pub const incremental_bvh = @import("spatial/incremental_bvh.zig");

// Re-export primary primitive types for convenience.
pub const Point2 = primitives.Point2;
pub const Point3 = primitives.Point3;
pub const AABB2 = primitives.AABB2;
pub const AABB3 = primitives.AABB3;
pub const Sphere = primitives.Sphere;
pub const Ray3 = primitives.Ray3;
pub const Ray3Precomputed = primitives.Ray3Precomputed;
pub const Plane = primitives.Plane;
pub const Frustum = primitives.Frustum;
pub const GridConfig = primitives.GridConfig;
pub const GridConfig3D = primitives.GridConfig3D;

// Bounded or build-once acceleration structures.
pub const UniformGrid = uniform_grid.UniformGrid;
pub const UniformGrid3D = uniform_grid_3d.UniformGrid3D;
pub const LooseGrid = loose_grid.LooseGrid;
pub const BVH = bvh.BVH;

// Dynamic acceleration structures whose mutation paths may allocate.
pub const SparseGrid = sparse_grid.SparseGrid;
pub const SparseGrid3D = sparse_grid.SparseGrid3D;
pub const IncrementalBVH = incremental_bvh.IncrementalBVH;

// Re-export Morton utilities.
pub const encode2d = morton.encode2d;
pub const decode2d = morton.decode2d;
pub const encode3d = morton.encode3d;
pub const decode3d = morton.decode3d;

test {
    _ = primitives;
    _ = morton;
    _ = uniform_grid;
    _ = uniform_grid_3d;
    _ = sparse_grid;
    _ = loose_grid;
    _ = bvh;
    _ = incremental_bvh;
}
