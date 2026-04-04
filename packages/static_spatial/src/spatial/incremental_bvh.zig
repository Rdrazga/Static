//! Incremental Bounding Volume Hierarchy (IBVH) for 3D dynamic scenes.
//!
//! This is the dynamic BVH family in `static_spatial`.
//!
//! Key type: `IncrementalBVH(T)`. Supports `insert`, `remove`, and `refit` without
//! full rebuild. It is backed by growable node and free-list arrays, so mutation
//! operations may allocate.
//!
//! Sibling selection uses a greedy surface-area-heuristic (SAH) cost function —
//! new leaves are inserted next to the existing node whose combined AABB produces the
//! smallest surface area increase.
//!
//! Query contract: `queryRay` and `queryAABB` write up to `out.len` results and return
//! the total hit count. If the count exceeds `out.len`, the caller can detect truncation
//! by comparing the return value against the output buffer length, just like `BVH`.
//!
//! Use `BVH` when the scene can be built once and queried repeatedly with no
//! further allocation. Use `IncrementalBVH` when dynamic updates matter more than
//! steady-state boundedness.
//!
//! Thread safety: `insert`/`remove`/`refit` mutate; queries are read-only. External
//! synchronization required.
const std = @import("std");
const primitives = @import("primitives.zig");
const AABB3 = primitives.AABB3;
const Ray3 = primitives.Ray3;

/// An incremental bounding volume hierarchy that supports insert, remove, and
/// refit without full rebuild. Uses a pointer-index-based tree backed by a
/// growable array with a free list for recycled nodes.
pub fn IncrementalBVH(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const NodeIndex = u32;
        pub const INVALID: NodeIndex = std.math.maxInt(NodeIndex);

        comptime {
            // NodeIndex must be able to represent INVALID without wrapping.
            std.debug.assert(@bitSizeOf(NodeIndex) == 32);
        }

        pub const Node = struct {
            bounds: AABB3,
            parent: NodeIndex,
            left: NodeIndex,
            right: NodeIndex,
            value: ?T,
            is_leaf: bool,
        };

        nodes: std.ArrayListUnmanaged(Node),
        free_list: std.ArrayListUnmanaged(NodeIndex),
        root: NodeIndex,
        leaf_count: u32,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Self {
            const self = Self{
                .nodes = .{},
                .free_list = .{},
                .root = INVALID,
                .leaf_count = 0,
                .allocator = allocator,
            };
            // Postcondition: tree starts empty with no root.
            std.debug.assert(self.root == INVALID);
            std.debug.assert(self.leaf_count == 0);
            return self;
        }

        pub fn deinit(self: *Self) void {
            // Precondition: free list cannot exceed the total node count.
            std.debug.assert(self.free_list.items.len <= self.nodes.items.len);
            // Precondition: leaf_count must be consistent (non-negative is guaranteed by u32).
            std.debug.assert(self.leaf_count <= self.nodes.items.len);
            self.free_list.deinit(self.allocator);
            self.nodes.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn count(self: *const Self) u32 {
            return self.leaf_count;
        }

        /// Insert a leaf with the given bounds and value. Returns a handle
        /// (node index) that can be used for remove and refit operations.
        pub fn insert(self: *Self, bounds: AABB3, value: T) !NodeIndex {
            // Precondition: AABB must not be inverted. AABB3.init already
            // asserts this, but we verify here as a pair assertion since
            // `bounds` may arrive via the raw struct form in internal callers.
            std.debug.assert(bounds.min_x <= bounds.max_x);
            std.debug.assert(bounds.min_y <= bounds.max_y);
            std.debug.assert(bounds.min_z <= bounds.max_z);
            const leaf_count_before = self.leaf_count;
            const leaf_idx = try self.allocNode(.{
                .bounds = bounds,
                .parent = INVALID,
                .left = INVALID,
                .right = INVALID,
                .value = value,
                .is_leaf = true,
            });

            self.leaf_count += 1;
            // Postcondition: leaf count increased by exactly one.
            std.debug.assert(self.leaf_count == leaf_count_before + 1);

            // If the tree is empty, the new leaf becomes the root.
            if (self.root == INVALID) {
                self.root = leaf_idx;
                // Postcondition: root is now valid after first insert.
                std.debug.assert(self.root != INVALID);
                return leaf_idx;
            }

            // Find the best sibling: the leaf whose merged bounds with the
            // new leaf produce the smallest surface area increase.
            const best_sibling = self.findBestSibling(bounds);

            // Create a new internal node to be the parent of the best sibling
            // and the new leaf.
            const old_parent = self.nodes.items[best_sibling].parent;
            const merged = AABB3.merge(self.nodes.items[best_sibling].bounds, bounds);

            const new_parent_idx = try self.allocNode(.{
                .bounds = merged,
                .parent = old_parent,
                .left = best_sibling,
                .right = leaf_idx,
                .value = null,
                .is_leaf = false,
            });

            self.nodes.items[best_sibling].parent = new_parent_idx;
            self.nodes.items[leaf_idx].parent = new_parent_idx;

            // Attach the new parent to the old parent.
            if (old_parent != INVALID) {
                if (self.nodes.items[old_parent].left == best_sibling) {
                    self.nodes.items[old_parent].left = new_parent_idx;
                } else {
                    std.debug.assert(self.nodes.items[old_parent].right == best_sibling);
                    self.nodes.items[old_parent].right = new_parent_idx;
                }
                self.refitAncestors(old_parent);
            } else {
                // The best sibling was the root.
                self.root = new_parent_idx;
            }

            // Postcondition: root is always valid after insert.
            std.debug.assert(self.root != INVALID);
            return leaf_idx;
        }

        /// Remove a leaf by its handle. The leaf's parent internal node is
        /// also removed and the sibling is promoted.
        pub fn remove(self: *Self, handle: NodeIndex) void {
            std.debug.assert(handle < self.nodes.items.len);
            std.debug.assert(self.nodes.items[handle].is_leaf);
            // Precondition: at least one leaf must exist to remove.
            std.debug.assert(self.leaf_count > 0);
            const leaf_count_before = self.leaf_count;

            self.leaf_count -= 1;
            // Postcondition: leaf count decreased by exactly one.
            std.debug.assert(self.leaf_count == leaf_count_before - 1);

            // If the leaf is the root, just clear the tree.
            if (handle == self.root) {
                self.freeNode(handle);
                self.root = INVALID;
                return;
            }

            const parent = self.nodes.items[handle].parent;
            std.debug.assert(parent != INVALID);

            // Determine the sibling.
            const sibling = if (self.nodes.items[parent].left == handle)
                self.nodes.items[parent].right
            else
                self.nodes.items[parent].left;

            const grandparent = self.nodes.items[parent].parent;

            // Promote the sibling to the grandparent's child.
            if (grandparent != INVALID) {
                if (self.nodes.items[grandparent].left == parent) {
                    self.nodes.items[grandparent].left = sibling;
                } else {
                    self.nodes.items[grandparent].right = sibling;
                }
                self.nodes.items[sibling].parent = grandparent;
                self.refitAncestors(grandparent);
            } else {
                // Parent was the root. Sibling becomes the new root.
                self.root = sibling;
                self.nodes.items[sibling].parent = INVALID;
            }

            self.freeNode(handle);
            self.freeNode(parent);
        }

        /// Update the bounds of a leaf and refit ancestor bounds up to the root.
        pub fn refit(self: *Self, handle: NodeIndex, new_bounds: AABB3) void {
            std.debug.assert(handle < self.nodes.items.len);
            std.debug.assert(self.nodes.items[handle].is_leaf);
            // Precondition: new bounds must be non-inverted.
            std.debug.assert(new_bounds.min_x <= new_bounds.max_x);
            std.debug.assert(new_bounds.min_y <= new_bounds.max_y);
            std.debug.assert(new_bounds.min_z <= new_bounds.max_z);

            self.nodes.items[handle].bounds = new_bounds;

            const parent = self.nodes.items[handle].parent;
            if (parent != INVALID) {
                self.refitAncestors(parent);
            }
        }

        /// Traverse the tree and collect all leaf values whose bounds are
        /// intersected by the given ray.
        ///
        /// Returns the total hit count. Results are written up to `out.len`;
        /// callers detect truncation by comparing the return value against the
        /// output buffer length.
        pub fn queryRay(self: *const Self, ray: Ray3, out: []T) u32 {
            // Precondition: ray direction must be non-zero (Ray3.init enforces unit length).
            const dir_len_sq = ray.dir_x * ray.dir_x + ray.dir_y * ray.dir_y + ray.dir_z * ray.dir_z;
            std.debug.assert(dir_len_sq > 0.0);
            if (self.root == INVALID) return 0;

            var hit_count: u32 = 0;
            var stack: [64]NodeIndex = undefined;
            var sp: u32 = 0;

            stack[sp] = self.root;
            sp += 1;

            while (sp > 0) {
                sp -= 1;
                const idx = stack[sp];
                const node = &self.nodes.items[idx];

                if (ray.intersectsAABB(node.bounds) == null) continue;

                if (node.is_leaf) {
                    if (hit_count < out.len) {
                        out[hit_count] = node.value.?;
                    }
                    hit_count += 1;
                } else {
                    if (node.left != INVALID) {
                        std.debug.assert(sp < stack.len);
                        stack[sp] = node.left;
                        sp += 1;
                    }
                    if (node.right != INVALID) {
                        std.debug.assert(sp < stack.len);
                        stack[sp] = node.right;
                        sp += 1;
                    }
                }
            }

            // Postcondition: traversal stack must be fully consumed on exit.
            std.debug.assert(sp == 0);
            return hit_count;
        }

        /// Traverse the tree and collect all leaf values whose bounds
        /// intersect the given AABB.
        ///
        /// Returns the total hit count. Results are written up to `out.len`;
        /// callers detect truncation by comparing the return value against the
        /// output buffer length.
        pub fn queryAABB(self: *const Self, aabb: AABB3, out: []T) u32 {
            // Precondition: query AABB must not be inverted.
            std.debug.assert(aabb.min_x <= aabb.max_x);
            std.debug.assert(aabb.min_y <= aabb.max_y);
            std.debug.assert(aabb.min_z <= aabb.max_z);
            if (self.root == INVALID) return 0;

            var hit_count: u32 = 0;
            var stack: [64]NodeIndex = undefined;
            var sp: u32 = 0;

            stack[sp] = self.root;
            sp += 1;

            while (sp > 0) {
                sp -= 1;
                const idx = stack[sp];
                const node = &self.nodes.items[idx];

                if (!aabb.intersects(node.bounds)) continue;

                if (node.is_leaf) {
                    if (hit_count < out.len) {
                        out[hit_count] = node.value.?;
                    }
                    hit_count += 1;
                } else {
                    if (node.left != INVALID) {
                        std.debug.assert(sp < stack.len);
                        stack[sp] = node.left;
                        sp += 1;
                    }
                    if (node.right != INVALID) {
                        std.debug.assert(sp < stack.len);
                        stack[sp] = node.right;
                        sp += 1;
                    }
                }
            }

            // Postcondition: traversal stack must be fully consumed on exit.
            std.debug.assert(sp == 0);
            return hit_count;
        }

        // -----------------------------------------------------------------
        // Internal helpers
        // -----------------------------------------------------------------

        /// Find the existing leaf whose expansion would increase total surface
        /// area the least when merged with the given bounds.
        fn findBestSibling(self: *const Self, bounds: AABB3) NodeIndex {
            var best: NodeIndex = self.root;
            var best_cost: f32 = std.math.inf(f32);

            var stack: [64]NodeIndex = undefined;
            var sp: u32 = 0;

            stack[sp] = self.root;
            sp += 1;

            while (sp > 0) {
                sp -= 1;
                const idx = stack[sp];
                const node = &self.nodes.items[idx];

                const merged = AABB3.merge(node.bounds, bounds);
                const cost = merged.surfaceArea();

                if (cost < best_cost) {
                    best_cost = cost;
                    best = idx;
                }

                // Only descend into children if the lower bound (inherited
                // cost) could beat the current best.
                if (!node.is_leaf) {
                    const inherited_cost = cost - node.bounds.surfaceArea();
                    if (inherited_cost < best_cost) {
                        if (node.left != INVALID) {
                            std.debug.assert(sp < stack.len);
                            stack[sp] = node.left;
                            sp += 1;
                        }
                        if (node.right != INVALID) {
                            std.debug.assert(sp < stack.len);
                            stack[sp] = node.right;
                            sp += 1;
                        }
                    }
                }
            }

            return best;
        }

        /// Refit the bounds of the given node and all its ancestors.
        fn refitAncestors(self: *Self, start: NodeIndex) void {
            // Depth is bounded by node count: in a valid acyclic tree the
            // parent chain from any node to the root visits at most
            // nodes.items.len ancestors before reaching INVALID.
            const max_depth: u32 = @intCast(self.nodes.items.len);
            std.debug.assert(max_depth > 0);
            var idx = start;
            var depth: u32 = 0;
            while (idx != INVALID and depth < max_depth) : (depth += 1) {
                const node = &self.nodes.items[idx];
                if (!node.is_leaf) {
                    const left_bounds = self.nodes.items[node.left].bounds;
                    const right_bounds = self.nodes.items[node.right].bounds;
                    node.bounds = AABB3.merge(left_bounds, right_bounds);
                }
                idx = node.parent;
            }
            // If idx != INVALID here, the loop exhausted max_depth, indicating
            // a cycle or corrupted parent chain.
            std.debug.assert(idx == INVALID);
        }

        /// Allocate a node, reusing one from the free list if available.
        fn allocNode(self: *Self, node: Node) !NodeIndex {
            if (self.free_list.items.len > 0) {
                const recycled = self.free_list.pop().?;
                self.nodes.items[recycled] = node;
                return recycled;
            }
            const idx: NodeIndex = @intCast(self.nodes.items.len);
            try self.nodes.append(self.allocator, node);
            return idx;
        }

        /// Return a node to the free list for later reuse.
        fn freeNode(self: *Self, idx: NodeIndex) void {
            self.nodes.items[idx] = .{
                .bounds = AABB3.init(0, 0, 0, 0, 0, 0),
                .parent = INVALID,
                .left = INVALID,
                .right = INVALID,
                .value = null,
                .is_leaf = false,
            };
            // free_list grows at the same rate as nodes and is backed by the
            // same allocator; the free list can hold at most nodes.items.len
            // entries — within the same allocation budget already proven viable.
            self.free_list.append(self.allocator, idx) catch unreachable;
        }
    };
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

fn approxEq(a: f32, b: f32) bool {
    return std.math.approxEqAbs(f32, a, b, 1.0e-5);
}

test "IncrementalBVH insert and query" {
    const BVH = IncrementalBVH(u32);
    var bvh = BVH.init(testing.allocator);
    defer bvh.deinit();

    // Insert three items at different positions.
    const h1 = try bvh.insert(AABB3.init(0, 0, 0, 1, 1, 1), 10);
    const h2 = try bvh.insert(AABB3.init(5, 5, 5, 6, 6, 6), 20);
    const h3 = try bvh.insert(AABB3.init(10, 10, 10, 11, 11, 11), 30);

    try testing.expectEqual(@as(u32, 3), bvh.count());

    // Verify handles are valid.
    try testing.expect(h1 != BVH.INVALID);
    try testing.expect(h2 != BVH.INVALID);
    try testing.expect(h3 != BVH.INVALID);

    // AABB query that overlaps the first two items.
    var buf: [8]u32 = undefined;
    const n = bvh.queryAABB(AABB3.init(-1, -1, -1, 7, 7, 7), &buf);
    try testing.expectEqual(@as(u32, 2), n);

    // Ray query along +X axis at y=0.5, z=0.5 should hit the first item.
    var ray_buf: [8]u32 = undefined;
    const ray = Ray3.init(-5.0, 0.5, 0.5, 1.0, 0.0, 0.0);
    const rn = bvh.queryRay(ray, &ray_buf);
    try testing.expect(rn >= 1);
    // The first hit should be item 10.
    var found_10 = false;
    for (ray_buf[0..rn]) |v| {
        if (v == 10) found_10 = true;
    }
    try testing.expect(found_10);
}

test "IncrementalBVH remove" {
    const BVH = IncrementalBVH(u32);
    var bvh = BVH.init(testing.allocator);
    defer bvh.deinit();

    const h1 = try bvh.insert(AABB3.init(0, 0, 0, 1, 1, 1), 10);
    _ = try bvh.insert(AABB3.init(5, 5, 5, 6, 6, 6), 20);
    _ = try bvh.insert(AABB3.init(10, 10, 10, 11, 11, 11), 30);

    try testing.expectEqual(@as(u32, 3), bvh.count());

    // Remove the first item.
    bvh.remove(h1);
    try testing.expectEqual(@as(u32, 2), bvh.count());

    // Query the region where item 10 was; it should no longer appear.
    var buf: [8]u32 = undefined;
    const n = bvh.queryAABB(AABB3.init(-1, -1, -1, 2, 2, 2), &buf);
    for (buf[0..n]) |v| {
        try testing.expect(v != 10);
    }

    // The remaining items should still be queryable.
    const n2 = bvh.queryAABB(AABB3.init(-1, -1, -1, 12, 12, 12), &buf);
    try testing.expectEqual(@as(u32, 2), n2);
}

test "IncrementalBVH refit" {
    const BVH = IncrementalBVH(u32);
    var bvh = BVH.init(testing.allocator);
    defer bvh.deinit();

    const h1 = try bvh.insert(AABB3.init(0, 0, 0, 1, 1, 1), 10);
    _ = try bvh.insert(AABB3.init(5, 5, 5, 6, 6, 6), 20);

    // Move item 10 to a new location.
    bvh.refit(h1, AABB3.init(50, 50, 50, 51, 51, 51));

    // The old location should no longer yield item 10.
    var buf: [8]u32 = undefined;
    const n_old = bvh.queryAABB(AABB3.init(-1, -1, -1, 2, 2, 2), &buf);
    for (buf[0..n_old]) |v| {
        try testing.expect(v != 10);
    }

    // The new location should yield item 10.
    const n_new = bvh.queryAABB(AABB3.init(49, 49, 49, 52, 52, 52), &buf);
    try testing.expectEqual(@as(u32, 1), n_new);
    try testing.expectEqual(@as(u32, 10), buf[0]);

    // Root bounds should contain both items after refit.
    const root_bounds = bvh.nodes.items[bvh.root].bounds;
    try testing.expect(root_bounds.containsAABB(AABB3.init(5, 5, 5, 6, 6, 6)));
    try testing.expect(root_bounds.containsAABB(AABB3.init(50, 50, 50, 51, 51, 51)));
}

test "IncrementalBVH empty query" {
    const BVH = IncrementalBVH(u32);
    var bvh = BVH.init(testing.allocator);
    defer bvh.deinit();

    // Queries on an empty tree should return zero results.
    var buf: [8]u32 = undefined;
    const n_aabb = bvh.queryAABB(AABB3.init(0, 0, 0, 10, 10, 10), &buf);
    try testing.expectEqual(@as(u32, 0), n_aabb);

    const ray = Ray3.init(0, 0, -10, 0, 0, 1);
    const n_ray = bvh.queryRay(ray, &buf);
    try testing.expectEqual(@as(u32, 0), n_ray);

    // Also verify count is zero.
    try testing.expectEqual(@as(u32, 0), bvh.count());
}
