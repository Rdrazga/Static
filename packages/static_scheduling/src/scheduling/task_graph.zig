//! Task graph - allocator-backed DAG of tasks with deterministic topological planning.
//!
//! Key types: `TaskGraph`, `Plan`, `TaskId`, `Error`.
//! Usage pattern: call `TaskGraph.init(allocator, node_count)` to create a graph,
//! `addDependency(from, to)` for each ordering constraint, then
//! `planDeterministic(plan_allocator)` to produce a `Plan` holding the topological
//! order. Call `plan.deinit()` then `graph.deinit()` when done.
//! Thread safety: not thread-safe - a single instance must be owned by one thread.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const topo = @import("topo.zig");

pub const TaskId = u32;

pub const Error = topo.TopoError;

pub const Plan = struct {
    allocator: std.mem.Allocator,
    // order holds node indices from topo.sortDeterministic, which works in usize-space.
    // Each value is guaranteed to be in [0, node_count) and node_count is validated to
    // fit within TaskId (u32) at addDependency time. Callers that need TaskId values
    // may safely cast: `@as(TaskId, @intCast(plan.order[i]))`. The types are kept
    // separate here to avoid coupling the generic topo layer to the TaskId domain type.
    order: []usize,

    pub fn deinit(self: *Plan) void {
        // Pre-deinit canary: a valid plan always holds at least one node in order.
        // An empty or already-freed slice indicates a double-deinit or corrupt state.
        assert(self.order.len > 0);
        self.allocator.free(self.order);
        self.* = undefined;
    }
};

pub const TaskGraph = struct {
    allocator: std.mem.Allocator,
    node_count: usize,
    edges: std.ArrayListUnmanaged(topo.Edge) = .{},

    pub fn init(allocator: std.mem.Allocator, node_count: usize) TaskGraph {
        // Precondition: a graph with zero nodes cannot schedule any work and
        // would violate sortDeterministic's InvalidConfig guard. Reject at construction.
        assert(node_count > 0);
        // Precondition: node_count must fit within TaskId (u32) so that callers
        // casting order values to TaskId via @intCast are safe.
        assert(node_count <= std.math.maxInt(TaskId));
        return .{ .allocator = allocator, .node_count = node_count };
    }

    pub fn deinit(self: *TaskGraph) void {
        // Pre-deinit canary: node_count > 0 is established by init and never changed.
        // A zero here means this graph was never properly initialised or was already freed.
        assert(self.node_count > 0);
        self.edges.deinit(self.allocator);
        self.* = undefined;
    }

    /// Adds an edge from `from` to `to`, indicating `from` must complete before `to`.
    /// Self-edges (`from == to`) and out-of-range IDs are rejected with `InvalidInput`.
    pub fn addDependency(self: *TaskGraph, from: TaskId, to: TaskId) Error!void {
        if (@as(usize, from) >= self.node_count or @as(usize, to) >= self.node_count) {
            return Error.InvalidInput;
        }
        if (from == to) return Error.InvalidInput;
        const before_len = self.edges.items.len;
        try self.edges.append(self.allocator, .{ .from = @as(usize, from), .to = @as(usize, to) });
        assert(self.edges.items.len == before_len + 1);
    }

    pub fn planDeterministic(self: *TaskGraph, plan_allocator: std.mem.Allocator) Error!Plan {
        assert(self.node_count > 0);
        // node_count is bounded by the caller (addDependency rejects IDs >= node_count,
        // and TaskId is u32), so every index in order fits in u32. Assert this invariant
        // so that callers casting order values to TaskId via @intCast are safe.
        assert(self.node_count <= std.math.maxInt(TaskId));
        const order = try topo.sortDeterministic(plan_allocator, self.node_count, self.edges.items);
        assert(order.len == self.node_count);
        return .{ .allocator = plan_allocator, .order = order };
    }
};

test "TaskGraph addDependency rejects out-of-range task IDs" {
    var g = TaskGraph.init(testing.allocator, 3);
    defer g.deinit();
    try testing.expectError(Error.InvalidInput, g.addDependency(0, 5));
    try testing.expectError(Error.InvalidInput, g.addDependency(9, 1));
}

test "TaskGraph addDependency rejects self-edge without mutating edges" {
    var g = TaskGraph.init(testing.allocator, 3);
    defer g.deinit();
    try testing.expectError(Error.InvalidInput, g.addDependency(1, 1));
    try testing.expectEqual(@as(usize, 0), g.edges.items.len);
}

test "TaskGraph planDeterministic linear graph returns ascending order" {
    var g = TaskGraph.init(testing.allocator, 4);
    defer g.deinit();
    // 0->1->2->3
    try g.addDependency(0, 1);
    try g.addDependency(1, 2);
    try g.addDependency(2, 3);
    var plan = try g.planDeterministic(testing.allocator);
    defer plan.deinit();
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3 }, plan.order);
}

test "TaskGraph planDeterministic diamond graph returns deterministic order" {
    var g = TaskGraph.init(testing.allocator, 3);
    defer g.deinit();
    // 0->2, 1->2 (diamond with two roots, single sink).
    try g.addDependency(0, 2);
    try g.addDependency(1, 2);
    var plan = try g.planDeterministic(testing.allocator);
    defer plan.deinit();
    // Lowest-id-first: roots 0 and 1 before sink 2.
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, plan.order);
}

test "TaskGraph planDeterministic returns CycleDetected for cyclic graph" {
    var g = TaskGraph.init(testing.allocator, 2);
    defer g.deinit();
    try g.addDependency(0, 1);
    try g.addDependency(1, 0);
    try testing.expectError(Error.CycleDetected, g.planDeterministic(testing.allocator));
}

test "TaskGraph deinit after plan deinit does not crash" {
    var g = TaskGraph.init(testing.allocator, 2);
    try g.addDependency(0, 1);
    var plan = try g.planDeterministic(testing.allocator);
    // Deinit plan first, then graph - both must be safe.
    plan.deinit();
    g.deinit();
}
