//! Topological sort — deterministic Kahn's algorithm over a generic edge list.
//!
//! Key types: `Edge`, `TopoError`.
//! Usage pattern: build an `[]Edge` slice, call `sortDeterministic(allocator, node_count, edges)`
//! to obtain a `[]usize` topological order. The algorithm uses a min-heap to break ties by
//! lowest node index, producing a stable, reproducible output for any fixed input.
//! Returns `CycleDetected` if the graph contains a cycle, `InvalidConfig` if `node_count == 0`.
//! Thread safety: not thread-safe — the allocator and output slice are caller-managed.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

pub const Edge = struct {
    from: usize,
    to: usize,
};

pub const TopoError = error{
    OutOfMemory,
    // Returned when the graph configuration is invalid at the call site
    // (e.g. node_count == 0 when a non-empty plan is required).
    // Distinct from InvalidInput, which covers out-of-range edge endpoints.
    InvalidConfig,
    InvalidInput,
    CycleDetected,
};

const MinHeap = struct {
    items: []usize,
    len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) TopoError!MinHeap {
        return .{ .items = try allocator.alloc(usize, capacity) };
    }

    pub fn deinit(self: *MinHeap, allocator: std.mem.Allocator) void {
        allocator.free(self.items);
    }

    pub fn push(self: *MinHeap, value: usize) void {
        assert(self.len < self.items.len);
        var i: usize = self.len;
        self.len += 1;
        self.items[i] = value;
        // Sift-up bound: depth of a binary heap is floor(log2(len)), which
        // is strictly less than len for any valid heap (len >= 1 after insert).
        const max_sift_steps: usize = self.len;
        assert(max_sift_steps > 0);
        var sift_steps: usize = 0;
        while (i > 0 and sift_steps < max_sift_steps) : (sift_steps += 1) {
            const parent = (i - 1) / 2;
            if (self.items[parent] <= self.items[i]) break;
            std.mem.swap(usize, &self.items[parent], &self.items[i]);
            i = parent;
        }
        assert(i == 0 or self.items[(i - 1) / 2] <= self.items[i]);
        // Postcondition: the heap must not exceed its backing buffer after insertion.
        assert(self.len <= self.items.len);
    }

    pub fn popMin(self: *MinHeap) ?usize {
        if (self.len == 0) return null;
        const old_len = self.len;
        const out = self.items[0];
        self.len -= 1;
        if (self.len == 0) {
            // Postcondition: popping the last element decrements len to 0.
            assert(self.len < old_len);
            return out;
        }
        self.items[0] = self.items[self.len];
        var i: usize = 0;
        // Sift-down bound: depth of a binary heap is floor(log2(len)), which
        // is strictly less than len for any valid heap (len >= 1 here).
        const max_sift_steps: usize = self.len;
        assert(max_sift_steps > 0);
        var sift_steps: usize = 0;
        while (sift_steps < max_sift_steps) : (sift_steps += 1) {
            const left = i * 2 + 1;
            const right = left + 1;
            if (left >= self.len) break;
            var smallest = left;
            if (right < self.len and self.items[right] < self.items[left]) smallest = right;
            if (self.items[i] <= self.items[smallest]) break;
            std.mem.swap(usize, &self.items[i], &self.items[smallest]);
            i = smallest;
        }
        // Postcondition: a successful pop always decrements len.
        assert(self.len < old_len);
        return out;
    }
};

/// Compressed Sparse Row representation of the out-neighbor graph.
/// All three slices are allocated together and must be freed via deinit.
const Csr = struct {
    offsets: []usize,
    out_neighbors: []usize,
    indegree: []u32,

    fn deinit(self: *Csr, allocator: std.mem.Allocator) void {
        allocator.free(self.offsets);
        allocator.free(self.out_neighbors);
        allocator.free(self.indegree);
    }
};

/// Builds a CSR adjacency structure and per-node indegree array from a flat edge list.
/// Validates that all edge endpoints lie within [0, node_count). Returns InvalidInput
/// for out-of-range endpoints. The caller owns all allocated slices via Csr.deinit.
fn buildCsr(
    allocator: std.mem.Allocator,
    node_count: usize,
    edges: []const Edge,
) TopoError!Csr {
    assert(node_count > 0);

    var indegree = try allocator.alloc(u32, node_count);
    errdefer allocator.free(indegree);
    @memset(indegree, 0);

    var out_counts = try allocator.alloc(u32, node_count);
    defer allocator.free(out_counts);
    @memset(out_counts, 0);

    for (edges) |e| {
        if (e.from >= node_count or e.to >= node_count) return TopoError.InvalidInput;
        out_counts[e.from] += 1;
        indegree[e.to] += 1;
    }

    var offsets = try allocator.alloc(usize, node_count + 1);
    errdefer allocator.free(offsets);
    offsets[0] = 0;
    for (out_counts, 0..) |cnt, i| {
        offsets[i + 1] = offsets[i] + @as(usize, cnt);
    }

    // Invariant: the total number of out-neighbor slots equals the edge count,
    // because each edge contributes exactly one out-neighbor entry.
    const total_out = offsets[node_count];
    assert(total_out == edges.len);

    var out_neighbors = try allocator.alloc(usize, total_out);
    errdefer allocator.free(out_neighbors);

    var cursor = try allocator.alloc(usize, node_count);
    defer allocator.free(cursor);
    for (cursor, 0..) |*c, i| c.* = offsets[i];

    for (edges) |e| {
        const idx = cursor[e.from];
        out_neighbors[idx] = e.to;
        cursor[e.from] = idx + 1;
    }

    return Csr{
        .offsets = offsets,
        .out_neighbors = out_neighbors,
        .indegree = indegree,
    };
}

pub fn sortDeterministic(
    allocator: std.mem.Allocator,
    node_count: usize,
    edges: []const Edge,
) TopoError![]usize {
    // node_count == 0 is a configuration error: the caller controls this at
    // construction time, not from external data. Use InvalidConfig because the
    // failure is a stable caller-supplied configuration mistake.
    if (node_count == 0) return TopoError.InvalidConfig;

    var csr = try buildCsr(allocator, node_count, edges);
    defer csr.deinit(allocator);

    var heap = try MinHeap.init(allocator, node_count);
    defer heap.deinit(allocator);

    for (csr.indegree, 0..) |deg, i| {
        if (deg == 0) heap.push(i);
    }

    var order = try allocator.alloc(usize, node_count);
    var produced: usize = 0;

    while (heap.popMin()) |n| {
        order[produced] = n;
        produced += 1;

        const start = csr.offsets[n];
        const end = csr.offsets[n + 1];
        var j: usize = start;
        while (j < end) : (j += 1) {
            const m = csr.out_neighbors[j];
            const deg = csr.indegree[m] - 1;
            csr.indegree[m] = deg;
            if (deg == 0) heap.push(m);
        }
    }

    if (produced != node_count) {
        allocator.free(order);
        return TopoError.CycleDetected;
    }

    return order;
}

test "sortDeterministic is stable and detects cycles" {
    const a = testing.allocator;

    // 0 -> 2, 1 -> 2, 2 -> 3 should produce 0,1,2,3.
    const edges = [_]Edge{
        .{ .from = 1, .to = 2 },
        .{ .from = 0, .to = 2 },
        .{ .from = 2, .to = 3 },
    };
    const order = try sortDeterministic(a, 4, &edges);
    defer a.free(order);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3 }, order);

    const cycle_edges = [_]Edge{
        .{ .from = 0, .to = 1 },
        .{ .from = 1, .to = 0 },
    };
    try testing.expectError(TopoError.CycleDetected, sortDeterministic(a, 2, &cycle_edges));
}

test "sortDeterministic single node with no edges returns [0]" {
    const a = testing.allocator;
    const order = try sortDeterministic(a, 1, &.{});
    defer a.free(order);
    try testing.expectEqualSlices(usize, &.{0}, order);
}

test "sortDeterministic ordering is independent of input edge order" {
    const a = testing.allocator;
    // Diamond: edges provided in reverse order vs original test.
    const edges_reversed = [_]Edge{
        .{ .from = 2, .to = 3 },
        .{ .from = 1, .to = 2 },
        .{ .from = 0, .to = 2 },
    };
    const order = try sortDeterministic(a, 4, &edges_reversed);
    defer a.free(order);
    // Lowest-id-first policy must still produce 0,1,2,3 regardless of edge input order.
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3 }, order);
}

test "sortDeterministic disconnected graph returns nodes in ascending id order" {
    const a = testing.allocator;
    // Four isolated nodes; min-heap drains 0,1,2,3.
    const order = try sortDeterministic(a, 4, &.{});
    defer a.free(order);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3 }, order);
}

test "sortDeterministic out-of-range edge returns InvalidInput" {
    const a = testing.allocator;
    const bad_edges = [_]Edge{.{ .from = 0, .to = 5 }};
    try testing.expectError(TopoError.InvalidInput, sortDeterministic(a, 4, &bad_edges));
}

test "sortDeterministic node_count 0 returns InvalidConfig" {
    const a = testing.allocator;
    try testing.expectError(TopoError.InvalidConfig, sortDeterministic(a, 0, &.{}));
}

test "sortDeterministic long serial chain returns forward order" {
    const a = testing.allocator;
    // 0->1->2->3->4
    const edges = [_]Edge{
        .{ .from = 0, .to = 1 },
        .{ .from = 1, .to = 2 },
        .{ .from = 2, .to = 3 },
        .{ .from = 3, .to = 4 },
    };
    const order = try sortDeterministic(a, 5, &edges);
    defer a.free(order);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3, 4 }, order);
}

test "sortDeterministic stress: randomized acyclic edge lists respect all edges and produce full order" {
    // Property test with a fixed seed for reproducibility.
    // Invariants under test:
    //   1. plan length equals node_count for any acyclic graph.
    //   2. every input edge (from, to) is respected: from appears before to in the output.
    // Acyclicity is guaranteed by construction: edges only go from lower to higher node index.
    const a = testing.allocator;

    var prng = std.Random.DefaultPrng.init(0xdeadbeef_cafef00d);
    const random = prng.random();

    const trial_count: usize = 64;
    var trial: usize = 0;
    while (trial < trial_count) : (trial += 1) {
        // node_count in [1..16] keeps the test fast while covering non-trivial graphs.
        const node_count: usize = 1 + random.uintLessThan(usize, 16);

        // Build a random acyclic edge list: only emit edges (i, j) where i < j.
        var edge_buf: [64]Edge = undefined;
        var edge_count: usize = 0;
        var i: usize = 0;
        while (i < node_count and edge_count < edge_buf.len) : (i += 1) {
            var j: usize = i + 1;
            while (j < node_count and edge_count < edge_buf.len) : (j += 1) {
                if (random.boolean()) {
                    edge_buf[edge_count] = .{ .from = i, .to = j };
                    edge_count += 1;
                }
            }
        }
        const edges = edge_buf[0..edge_count];

        const order = try sortDeterministic(a, node_count, edges);
        defer a.free(order);

        // Invariant 1: plan covers every node exactly once (paired assert + expectation).
        assert(order.len == node_count);
        try testing.expectEqual(node_count, order.len);

        // Invariant 2: every input edge is respected in the output order.
        // Build a position map: position[node] = index in order.
        var position: [16]usize = undefined;
        assert(node_count <= position.len);
        for (order, 0..) |node, pos| {
            position[node] = pos;
        }
        for (edges) |e| {
            assert(position[e.from] < position[e.to]);
            try testing.expect(position[e.from] < position[e.to]);
        }
    }
}
