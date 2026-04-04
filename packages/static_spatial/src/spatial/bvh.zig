//! Static Bounding Volume Hierarchy (BVH) for 3D broad-phase queries.
//!
//! Key type: `BVH(T)`. Build once from a fixed item set; supports ray, AABB, and frustum queries.
//!
//! Splitting strategies: `.middle` (fast build, lower query quality) and `.sah` (slower build,
//! surface-area-heuristic optimal splits). SAH uses up to 32 bins per axis.
//!
//! The tree is built iteratively (no recursion). Leaf item counts are bounded by
//! `BVHConfig.max_leaf_items`. Worst-case node count is `2 * n - 1` for `n` items.
//!
//! Query contract: result counts may exceed `out.len`; callers detect truncation by
//! comparing the return value against `out.len`.
//!
//! Thread safety: `build` allocates; all query methods are read-only and safe for
//! concurrent reads if no mutation is occurring.
const std = @import("std");
const primitives = @import("primitives.zig");
const AABB3 = primitives.AABB3;
const Ray3 = primitives.Ray3;
const Ray3Precomputed = primitives.Ray3Precomputed;
const Sphere = primitives.Sphere;
const Frustum = primitives.Frustum;

pub const BVHError = error{
    OutOfMemory,
    Empty,
    InvalidConfig,
};

pub const BVHConfig = struct {
    strategy: enum { middle, sah } = .middle,
    max_leaf_items: u32 = 4,
    sah_bins: u32 = 12,
};

pub fn BVH(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Item = struct {
            bounds: AABB3,
            value: T,
        };

        pub const RayHit = struct {
            value: T,
            t: f32,
        };

        const Node = struct {
            bounds: AABB3,
            /// For internal nodes: index of left child (right = left + 1).
            /// For leaves: index of first item in the items array.
            first: u32,
            /// 0 for internal nodes, >0 for leaves (item count).
            count: u32,
        };

        nodes: []Node,
        items: []Item,

        pub fn build(
            allocator: std.mem.Allocator,
            input: []const Item,
            config: BVHConfig,
        ) BVHError!Self {
            if (input.len == 0) return BVHError.Empty;
            if (config.max_leaf_items == 0) return BVHError.InvalidConfig;

            // Copy items so we can reorder them during build.
            const items = allocator.alloc(Item, input.len) catch
                return BVHError.OutOfMemory;
            @memcpy(items, input);

            // Worst case: 2*n - 1 nodes for n items.
            const max_nodes = input.len * 2;
            const nodes = allocator.alloc(Node, max_nodes) catch {
                allocator.free(items);
                return BVHError.OutOfMemory;
            };

            var node_count: u32 = 0;

            buildIterative(
                nodes,
                items,
                &node_count,
                0,
                @intCast(items.len),
                config,
            );

            // Shrink nodes allocation to actual size.
            const final_nodes = allocator.realloc(nodes, node_count) catch
                nodes; // If realloc fails, keep the oversized allocation.

            return .{
                .nodes = final_nodes,
                .items = items,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            // Precondition: a built BVH must have at least one node and one item.
            std.debug.assert(self.nodes.len > 0);
            std.debug.assert(self.items.len > 0);
            allocator.free(self.nodes);
            allocator.free(self.items);
            self.* = undefined;
        }

        /// Query all items whose bounds intersect `ray`.
        ///
        /// Results are written into `out`. Returns the total number of hits
        /// found — if this exceeds `out.len`, results were truncated and the
        /// caller should retry with a larger buffer. Compare the return
        /// value against `out.len` to detect truncation.
        pub fn queryRay(
            self: *const Self,
            ray: Ray3,
            out: []T,
        ) u32 {
            // Precondition: ray direction must be non-zero (unit-length is preferred;
            // Ray3.init already asserts unit length at construction sites).
            const dir_len_sq = ray.dir_x * ray.dir_x + ray.dir_y * ray.dir_y + ray.dir_z * ray.dir_z;
            std.debug.assert(dir_len_sq > 0.0);
            if (self.nodes.len == 0) return 0;
            const pre = Ray3Precomputed.fromRay(ray);

            var count: u32 = 0;
            var stack: [64]u32 = undefined;
            var sp: u32 = 0;

            stack[0] = 0;
            sp = 1;

            while (sp > 0) {
                sp -= 1;
                const node_idx = stack[sp];
                const node = self.nodes[node_idx];

                if (pre.intersectsAABB(node.bounds) == null) continue;

                if (node.count > 0) {
                    const end = node.first + node.count;
                    for (node.first..end) |i| {
                        if (pre.intersectsAABB(self.items[i].bounds) != null) {
                            if (count < out.len) {
                                out[count] = self.items[i].value;
                            }
                            count += 1;
                        }
                    }
                } else {
                    std.debug.assert(sp + 2 <= stack.len);
                    stack[sp] = node_idx + 1;
                    sp += 1;
                    stack[sp] = node.first;
                    sp += 1;
                }
            }

            // Postcondition: traversal stack must be fully consumed on exit.
            std.debug.assert(sp == 0);
            return count;
        }

        /// Query all items whose bounds intersect `aabb`.
        ///
        /// Results are written into `out`. Returns the total number of hits
        /// found — if this exceeds `out.len`, results were truncated and the
        /// caller should retry with a larger buffer. Compare the return
        /// value against `out.len` to detect truncation.
        pub fn queryAABB(
            self: *const Self,
            aabb: AABB3,
            out: []T,
        ) u32 {
            // Precondition: query AABB must not be inverted.
            std.debug.assert(aabb.min_x <= aabb.max_x);
            std.debug.assert(aabb.min_y <= aabb.max_y);
            std.debug.assert(aabb.min_z <= aabb.max_z);
            if (self.nodes.len == 0) return 0;

            var count: u32 = 0;
            var stack: [64]u32 = undefined;
            var sp: u32 = 0;

            stack[0] = 0;
            sp = 1;

            while (sp > 0) {
                sp -= 1;
                const node_idx = stack[sp];
                const node = self.nodes[node_idx];

                if (!aabb.intersects(node.bounds)) continue;

                if (node.count > 0) {
                    // Leaf node: test each item.
                    const end = node.first + node.count;
                    for (node.first..end) |i| {
                        if (aabb.intersects(self.items[i].bounds)) {
                            if (count < out.len) {
                                out[count] = self.items[i].value;
                            }
                            // Always increment: total hits may exceed out.len.
                            count += 1;
                        }
                    }
                } else {
                    // Internal node: left child is at node_idx + 1,
                    // right child index is stored in node.first.
                    std.debug.assert(sp + 2 <= stack.len);
                    stack[sp] = node_idx + 1;
                    sp += 1;
                    stack[sp] = node.first;
                    sp += 1;
                }
            }

            // Postcondition: traversal stack must be fully consumed on exit.
            std.debug.assert(sp == 0);
            return count;
        }

        /// Query items whose bounds intersect `ray`, sorted by ascending `t`.
        ///
        /// Each result includes the item value and the entry `t` parameter.
        /// Returns the total number of hits found — if this exceeds
        /// `out.len`, results were truncated.
        pub fn queryRaySorted(
            self: *const Self,
            ray: Ray3,
            out: []RayHit,
        ) u32 {
            // Precondition: ray direction must be non-zero (matches queryRay's pair assertion).
            const dir_len_sq_s = ray.dir_x * ray.dir_x + ray.dir_y * ray.dir_y + ray.dir_z * ray.dir_z;
            std.debug.assert(dir_len_sq_s > 0.0);
            if (self.nodes.len == 0) return 0;
            const pre = Ray3Precomputed.fromRay(ray);

            var count: u32 = 0;
            var stack: [64]u32 = undefined;
            var sp: u32 = 0;

            stack[0] = 0;
            sp = 1;

            while (sp > 0) {
                sp -= 1;
                const node_idx = stack[sp];
                const node = self.nodes[node_idx];

                if (pre.intersectsAABB(node.bounds) == null) continue;

                if (node.count > 0) {
                    const end = node.first + node.count;
                    for (node.first..end) |i| {
                        if (pre.intersectsAABB(self.items[i].bounds)) |h| {
                            if (count < out.len) {
                                out[count] = .{
                                    .value = self.items[i].value,
                                    .t = h.t_min,
                                };
                            }
                            count += 1;
                        }
                    }
                } else {
                    std.debug.assert(sp + 2 <= stack.len);
                    stack[sp] = node_idx + 1;
                    sp += 1;
                    stack[sp] = node.first;
                    sp += 1;
                }
            }

            // Postcondition: traversal stack must be fully consumed on exit.
            std.debug.assert(sp == 0);
            const written = @min(count, @as(u32, @intCast(out.len)));
            std.sort.pdq(RayHit, out[0..written], {}, struct {
                fn lessThan(_: void, a: RayHit, b: RayHit) bool {
                    return a.t < b.t;
                }
            }.lessThan);

            return count;
        }

        /// Query items whose bounds intersect `frustum`.
        ///
        /// Uses hierarchical culling — subtrees fully outside the frustum
        /// are skipped. Returns the total hit count (may exceed `out.len`).
        pub fn queryFrustum(
            self: *const Self,
            frustum: Frustum,
            out: []T,
        ) u32 {
            // Precondition: all frustum plane normals must be non-zero length
            // (a zero-length normal indicates an uninitialized or degenerate frustum).
            for (frustum.planes) |plane| {
                const nlen_sq = plane.normal_x * plane.normal_x +
                    plane.normal_y * plane.normal_y +
                    plane.normal_z * plane.normal_z;
                std.debug.assert(nlen_sq > 0.0);
            }
            if (self.nodes.len == 0) return 0;

            var count: u32 = 0;
            var stack: [64]u32 = undefined;
            var sp: u32 = 0;

            stack[0] = 0;
            sp = 1;

            while (sp > 0) {
                sp -= 1;
                const node_idx = stack[sp];
                const node = self.nodes[node_idx];

                // Use the 3-way classification for hierarchical culling.
                const classification = frustum.intersectsAABB(node.bounds);
                if (classification == .outside) continue;

                if (node.count > 0) {
                    // Leaf node: test each item individually.
                    const end = node.first + node.count;
                    if (classification == .inside) {
                        // Node fully inside — all items qualify.
                        for (node.first..end) |i| {
                            if (count < out.len) {
                                out[count] = self.items[i].value;
                            }
                            count += 1;
                        }
                    } else {
                        // Node intersecting — test each item individually.
                        for (node.first..end) |i| {
                            if (frustum.intersectsAABB(self.items[i].bounds) != .outside) {
                                if (count < out.len) {
                                    out[count] = self.items[i].value;
                                }
                                count += 1;
                            }
                        }
                    }
                } else {
                    std.debug.assert(sp + 2 <= stack.len);
                    stack[sp] = node_idx + 1;
                    sp += 1;
                    stack[sp] = node.first;
                    sp += 1;
                }
            }

            // Postcondition: traversal stack must be fully consumed on exit.
            std.debug.assert(sp == 0);
            return count;
        }

        // -----------------------------------------------------------------
        // Build helpers
        // -----------------------------------------------------------------

        const max_depth: u32 = 64;

        const WorkItem = struct {
            start: u32,
            end: u32,
            parent_idx: u32,
            is_right: bool,
        };

        fn makeLeaf(bounds: AABB3, start: u32, count: u32) Node {
            std.debug.assert(count > 0);
            return .{ .bounds = bounds, .first = start, .count = count };
        }

        /// Iterative BVH build using an explicit work stack.
        ///
        /// Bounded to 64 levels of depth, which supports up to 2^64 items
        /// in a balanced tree — far beyond any practical input. Degenerate
        /// inputs that would exceed this depth are forced into leaves.
        fn buildIterative(
            nodes: []Node,
            items: []Item,
            node_count: *u32,
            initial_start: u32,
            initial_end: u32,
            config: BVHConfig,
        ) void {
            std.debug.assert(initial_start < initial_end);
            // Precondition: nodes buffer must be large enough for the worst case (2n - 1).
            std.debug.assert(nodes.len >= (initial_end - initial_start) * 2);
            var stack: [max_depth]WorkItem = undefined;
            var sp: u32 = 0;
            stack[0] = .{
                .start = initial_start,
                .end = initial_end,
                .parent_idx = 0,
                .is_right = false,
            };
            sp = 1;

            var first_node = true;

            while (sp > 0) {
                sp -= 1;
                const work = stack[sp];
                const count = work.end - work.start;
                const my_idx = node_count.*;
                node_count.* += 1;

                if (!first_node and work.is_right) {
                    nodes[work.parent_idx].first = my_idx;
                }
                first_node = false;

                const bounds = computeBounds(items, work.start, work.end);

                if (count <= config.max_leaf_items or sp + 2 > max_depth) {
                    nodes[my_idx] = makeLeaf(bounds, work.start, count);
                    continue;
                }

                const mid = splitItems(items, work.start, work.end, bounds, config);
                if (mid == work.start or mid == work.end) {
                    nodes[my_idx] = makeLeaf(bounds, work.start, count);
                    continue;
                }

                nodes[my_idx] = .{ .bounds = bounds, .first = 0, .count = 0 };
                pushChildren(&stack, &sp, work.start, mid, work.end, my_idx);
            }
        }

        fn splitItems(
            items: []Item,
            start: u32,
            end: u32,
            bounds: AABB3,
            config: BVHConfig,
        ) u32 {
            return switch (config.strategy) {
                .middle => middleSplit(items, start, end, bounds),
                .sah => sahSplit(items, start, end, bounds, config.sah_bins),
            };
        }

        fn pushChildren(
            stack: *[max_depth]WorkItem,
            sp: *u32,
            start: u32,
            mid: u32,
            end: u32,
            parent_idx: u32,
        ) void {
            std.debug.assert(sp.* + 2 <= max_depth);
            // Right first (processed second = depth-first left-first).
            stack[sp.*] = .{
                .start = mid,
                .end = end,
                .parent_idx = parent_idx,
                .is_right = true,
            };
            sp.* += 1;
            stack[sp.*] = .{
                .start = start,
                .end = mid,
                .parent_idx = parent_idx,
                .is_right = false,
            };
            sp.* += 1;
        }

        fn computeBounds(items: []const Item, start: u32, end: u32) AABB3 {
            std.debug.assert(start < end);
            var bounds = items[start].bounds;
            for ((start + 1)..end) |i| {
                bounds = AABB3.merge(bounds, items[i].bounds);
            }
            return bounds;
        }

        fn centroid(aabb: AABB3, axis: u2) f32 {
            return switch (axis) {
                0 => (aabb.min_x + aabb.max_x) * 0.5,
                1 => (aabb.min_y + aabb.max_y) * 0.5,
                2 => (aabb.min_z + aabb.max_z) * 0.5,
                else => unreachable,
            };
        }

        fn longestAxis(bounds: AABB3) u2 {
            const w = bounds.max_x - bounds.min_x;
            const h = bounds.max_y - bounds.min_y;
            const d = bounds.max_z - bounds.min_z;
            if (w >= h and w >= d) return 0;
            if (h >= d) return 1;
            return 2;
        }

        fn middleSplit(
            items: []Item,
            start: u32,
            end: u32,
            bounds: AABB3,
        ) u32 {
            const axis = longestAxis(bounds);
            const mid_val = centroid(bounds, axis);

            // Partition items around the midpoint.
            var lo = start;
            var hi = end;
            while (lo < hi) {
                if (centroid(items[lo].bounds, axis) < mid_val) {
                    lo += 1;
                } else {
                    hi -= 1;
                    std.mem.swap(Item, &items[lo], &items[hi]);
                }
            }

            return lo;
        }

        const max_bins = 32;

        /// Identity element for merge-grow patterns. Delegates to the canonical
        /// AABB3.empty constant so all spatial types share a single definition.
        const empty_aabb = AABB3.empty;

        fn axisExtent(bounds: AABB3, axis: u2) struct { min: f32, max: f32 } {
            return switch (axis) {
                0 => .{ .min = bounds.min_x, .max = bounds.max_x },
                1 => .{ .min = bounds.min_y, .max = bounds.max_y },
                2 => .{ .min = bounds.min_z, .max = bounds.max_z },
                else => unreachable,
            };
        }

        fn accumulateBins(
            items: []const Item,
            start: u32,
            end: u32,
            axis: u2,
            axis_min: f32,
            inv_extent: f32,
            bins: u32,
            bin_counts: *[max_bins]u32,
            bin_bounds: *[max_bins]AABB3,
        ) void {
            for (0..bins) |bi| {
                bin_bounds[bi] = empty_aabb;
            }
            for (start..end) |i| {
                const c = centroid(items[i].bounds, axis);
                var bi: u32 = @intFromFloat(@min(
                    @as(f32, @floatFromInt(bins - 1)),
                    @floor((c - axis_min) * inv_extent * @as(f32, @floatFromInt(bins))),
                ));
                if (bi >= bins) bi = bins - 1;
                bin_counts[bi] += 1;
                bin_bounds[bi] = AABB3.merge(bin_bounds[bi], items[i].bounds);
            }
        }

        fn evaluateSAH(
            bin_counts: *const [max_bins]u32,
            bin_bounds: *const [max_bins]AABB3,
            bins: u32,
        ) struct { cost: f32, split: u32 } {
            var best_cost: f32 = std.math.floatMax(f32);
            var best_split: u32 = 0;

            for (1..bins) |split| {
                var lc: u32 = 0;
                var rc: u32 = 0;
                var lb: AABB3 = empty_aabb;
                var rb: AABB3 = empty_aabb;

                for (0..split) |b| {
                    if (bin_counts[b] > 0) {
                        lc += bin_counts[b];
                        lb = AABB3.merge(lb, bin_bounds[b]);
                    }
                }
                for (split..bins) |b| {
                    if (bin_counts[b] > 0) {
                        rc += bin_counts[b];
                        rb = AABB3.merge(rb, bin_bounds[b]);
                    }
                }
                if (lc == 0 or rc == 0) continue;

                const cost = @as(f32, @floatFromInt(lc)) * lb.surfaceArea() +
                    @as(f32, @floatFromInt(rc)) * rb.surfaceArea();
                if (cost < best_cost) {
                    best_cost = cost;
                    best_split = @intCast(split);
                }
            }
            return .{ .cost = best_cost, .split = best_split };
        }

        fn sahSplit(
            items: []Item,
            start: u32,
            end: u32,
            bounds: AABB3,
            bin_count: u32,
        ) u32 {
            std.debug.assert(start < end);
            const axis = longestAxis(bounds);
            const ae = axisExtent(bounds, axis);
            const extent = ae.max - ae.min;
            if (extent < 1.0e-6) return start;

            const inv_extent = 1.0 / extent;
            const count = end - start;
            const bins = @min(bin_count, max_bins);

            var bin_counts: [max_bins]u32 = [_]u32{0} ** max_bins;
            var bin_bounds: [max_bins]AABB3 = undefined;
            accumulateBins(items, start, end, axis, ae.min, inv_extent, bins, &bin_counts, &bin_bounds);

            const result = evaluateSAH(&bin_counts, &bin_bounds, bins);
            const leaf_cost = @as(f32, @floatFromInt(count)) * bounds.surfaceArea();
            if (result.cost >= leaf_cost) return start;

            const split_pos = ae.min + @as(f32, @floatFromInt(result.split)) /
                @as(f32, @floatFromInt(bins)) * extent;

            return partitionByAxis(items, start, end, axis, split_pos);
        }

        fn partitionByAxis(items: []Item, start: u32, end: u32, axis: u2, split_pos: f32) u32 {
            var lo = start;
            var hi = end;
            while (lo < hi) {
                if (centroid(items[lo].bounds, axis) < split_pos) {
                    lo += 1;
                } else {
                    hi -= 1;
                    std.mem.swap(Item, &items[lo], &items[hi]);
                }
            }
            return lo;
        }
    };
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

fn makeAABB(x: f32, y: f32, z: f32, s: f32) AABB3 {
    return AABB3.init(x, y, z, x + s, y + s, z + s);
}

test "BVH build empty returns error" {
    const IntBVH = BVH(u32);
    const items = [_]IntBVH.Item{};
    const result = IntBVH.build(testing.allocator, &items, .{});
    try testing.expectError(BVHError.Empty, result);
}

test "BVH build single item" {
    const IntBVH = BVH(u32);
    const items = [_]IntBVH.Item{
        .{ .bounds = makeAABB(0, 0, 0, 1), .value = 42 },
    };
    var bvh = try IntBVH.build(testing.allocator, &items, .{});
    defer bvh.deinit(testing.allocator);

    try testing.expect(bvh.nodes.len >= 1);
    try testing.expectEqual(@as(u32, 1), bvh.nodes[0].count);
}

test "BVH build and ray query" {
    const IntBVH = BVH(u32);
    const items = [_]IntBVH.Item{
        .{ .bounds = makeAABB(0, 0, 0, 1), .value = 0 },
        .{ .bounds = makeAABB(2, 0, 0, 1), .value = 1 },
        .{ .bounds = makeAABB(4, 0, 0, 1), .value = 2 },
        .{ .bounds = makeAABB(0, 5, 0, 1), .value = 3 },
        .{ .bounds = makeAABB(0, 0, 5, 1), .value = 4 },
        .{ .bounds = makeAABB(10, 10, 10, 1), .value = 5 },
    };
    var bvh = try IntBVH.build(testing.allocator, &items, .{ .max_leaf_items = 2 });
    defer bvh.deinit(testing.allocator);

    // Ray along +X axis at y=0.5, z=0.5 should hit items at x=0..1 and x=2..3 and x=4..5.
    const ray = Ray3.init(-1.0, 0.5, 0.5, 1.0, 0.0, 0.0);
    var results: [16]u32 = undefined;
    const hit_count = bvh.queryRay(ray, &results);
    try testing.expectEqual(@as(u32, 3), hit_count);

    // Verify that the hit values are 0, 1, 2 (in any order).
    var found = [_]bool{false} ** 3;
    for (0..hit_count) |i| {
        if (results[i] < 3) found[results[i]] = true;
    }
    try testing.expect(found[0] and found[1] and found[2]);
}

test "BVH build and AABB query" {
    const IntBVH = BVH(u32);
    const items = [_]IntBVH.Item{
        .{ .bounds = makeAABB(0, 0, 0, 1), .value = 10 },
        .{ .bounds = makeAABB(2, 0, 0, 1), .value = 20 },
        .{ .bounds = makeAABB(5, 5, 5, 1), .value = 30 },
        .{ .bounds = makeAABB(10, 10, 10, 1), .value = 40 },
    };
    var bvh = try IntBVH.build(testing.allocator, &items, .{ .max_leaf_items = 2 });
    defer bvh.deinit(testing.allocator);

    // Query region that overlaps items 0 and 1.
    const query = AABB3.init(-0.5, -0.5, -0.5, 3.5, 1.5, 1.5);
    var results: [16]u32 = undefined;
    const count = bvh.queryAABB(query, &results);
    try testing.expectEqual(@as(u32, 2), count);

    var found_10 = false;
    var found_20 = false;
    for (0..count) |i| {
        if (results[i] == 10) found_10 = true;
        if (results[i] == 20) found_20 = true;
    }
    try testing.expect(found_10 and found_20);
}

test "BVH middle strategy" {
    const IntBVH = BVH(u32);
    var input: [8]IntBVH.Item = undefined;
    for (0..8) |i| {
        const fi: f32 = @floatFromInt(i);
        input[i] = .{
            .bounds = makeAABB(fi * 3.0, 0, 0, 1),
            .value = @intCast(i),
        };
    }

    var bvh = try IntBVH.build(
        testing.allocator,
        &input,
        .{ .strategy = .middle, .max_leaf_items = 2 },
    );
    defer bvh.deinit(testing.allocator);

    // Query a region covering items 0..2 (x in [0, 7]).
    const query = AABB3.init(-0.5, -0.5, -0.5, 7.5, 1.5, 1.5);
    var results: [16]u32 = undefined;
    const count = bvh.queryAABB(query, &results);
    try testing.expectEqual(@as(u32, 3), count);
}

test "BVH ray miss" {
    const IntBVH = BVH(u32);
    const items = [_]IntBVH.Item{
        .{ .bounds = makeAABB(0, 0, 0, 1), .value = 1 },
        .{ .bounds = makeAABB(2, 0, 0, 1), .value = 2 },
        .{ .bounds = makeAABB(4, 0, 0, 1), .value = 3 },
    };
    var bvh_tree = try IntBVH.build(testing.allocator, &items, .{});
    defer bvh_tree.deinit(testing.allocator);

    // Ray far above all items, pointing in +X.
    const ray = Ray3.init(-10.0, 100.0, 100.0, 1.0, 0.0, 0.0);
    var results: [16]u32 = undefined;
    const count = bvh_tree.queryRay(ray, &results);
    try testing.expectEqual(@as(u32, 0), count);
}

test "BVH queryRaySorted returns hits in ascending t" {
    const IntBVH = BVH(u32);
    // Three boxes along the +X axis, spaced apart.
    const items = [_]IntBVH.Item{
        .{ .bounds = makeAABB(4, 0, 0, 1), .value = 2 },
        .{ .bounds = makeAABB(0, 0, 0, 1), .value = 0 },
        .{ .bounds = makeAABB(2, 0, 0, 1), .value = 1 },
    };
    var bvh_tree = try IntBVH.build(testing.allocator, &items, .{ .max_leaf_items = 1 });
    defer bvh_tree.deinit(testing.allocator);

    // Ray along +X at y=0.5, z=0.5.
    const ray = Ray3.init(-1.0, 0.5, 0.5, 1.0, 0.0, 0.0);
    var results: [16]IntBVH.RayHit = undefined;
    const count = bvh_tree.queryRaySorted(ray, &results);
    try testing.expectEqual(@as(u32, 3), count);

    // Verify ascending t order.
    try testing.expect(results[0].t <= results[1].t);
    try testing.expect(results[1].t <= results[2].t);
}

test "BVH queryFrustum finds items inside frustum" {
    const IntBVH = BVH(u32);
    // Place items along the X axis, all near y=0.5, z=0.5.
    const items = [_]IntBVH.Item{
        .{ .bounds = makeAABB(0, 0, 0, 1), .value = 10 },
        .{ .bounds = makeAABB(2, 0, 0, 1), .value = 20 },
        .{ .bounds = makeAABB(100, 100, 100, 1), .value = 30 }, // far away
    };
    var bvh_tree = try IntBVH.build(testing.allocator, &items, .{});
    defer bvh_tree.deinit(testing.allocator);

    // Construct a box frustum directly from 6 inward-facing planes
    // enclosing the region [-1, 10] x [-1, 10] x [-1, 10].
    const frustum = Frustum{
        .planes = .{
            // left: normal +X, d = 1 (x >= -1)
            .{ .normal_x = 1, .normal_y = 0, .normal_z = 0, .d = 1 },
            // right: normal -X, d = -10 (x <= 10)
            .{ .normal_x = -1, .normal_y = 0, .normal_z = 0, .d = 10 },
            // bottom: normal +Y, d = 1 (y >= -1)
            .{ .normal_x = 0, .normal_y = 1, .normal_z = 0, .d = 1 },
            // top: normal -Y, d = -10 (y <= 10)
            .{ .normal_x = 0, .normal_y = -1, .normal_z = 0, .d = 10 },
            // near: normal +Z, d = 1 (z >= -1)
            .{ .normal_x = 0, .normal_y = 0, .normal_z = 1, .d = 1 },
            // far: normal -Z, d = -10 (z <= 10)
            .{ .normal_x = 0, .normal_y = 0, .normal_z = -1, .d = 10 },
        },
    };

    var results: [16]u32 = undefined;
    const count = bvh_tree.queryFrustum(frustum, &results);
    // Items 10 and 20 should be inside the box; 30 is far away.
    try testing.expect(count >= 2);
    var found_10 = false;
    var found_20 = false;
    for (0..@min(count, 16)) |i| {
        if (results[i] == 10) found_10 = true;
        if (results[i] == 20) found_20 = true;
    }
    try testing.expect(found_10 and found_20);
}
