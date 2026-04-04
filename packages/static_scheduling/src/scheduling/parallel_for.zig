//! Parallel-for dispatch over a topological plan.
//!
//! `runSequential` executes all tasks in plan order on the calling thread.
//! This keeps dispatch deterministic while the package's executor and thread-pool
//! surfaces continue to evolve under real consumer pressure.

const std = @import("std");
const task_graph = @import("task_graph.zig");

/// Execute all tasks in `plan.order` sequentially on the calling thread.
///
/// Calls `dispatch_fn(ctx, task_id)` once per entry in `plan.order`, in order.
/// The dispatch sequence exactly equals `plan.order` with no reordering.
///
/// Precondition: plan.order must be non-empty.
/// Postcondition: every task in plan.order has been dispatched exactly once.
pub fn runSequential(
    plan: *const task_graph.Plan,
    ctx: anytype,
    comptime dispatch_fn: fn (@TypeOf(ctx), usize) void,
) void {
    std.debug.assert(plan.order.len > 0);

    var index: usize = 0;
    while (index < plan.order.len) : (index += 1) {
        dispatch_fn(ctx, plan.order[index]);
    }

    std.debug.assert(index == plan.order.len);
}

test "runSequential calls dispatch_fn in plan order for a linear graph" {
    const allocator = std.testing.allocator;

    var g = task_graph.TaskGraph.init(allocator, 4);
    defer g.deinit();

    try g.addDependency(0, 1);
    try g.addDependency(1, 2);
    try g.addDependency(2, 3);

    var plan = try g.planDeterministic(allocator);
    defer plan.deinit();

    const Recorder = struct {
        buf: [4]usize = undefined,
        len: usize = 0,

        fn dispatch(self: *@This(), task_id: usize) void {
            std.debug.assert(self.len < self.buf.len);
            self.buf[self.len] = task_id;
            self.len += 1;
        }
    };

    var rec = Recorder{};
    runSequential(&plan, &rec, Recorder.dispatch);

    std.debug.assert(rec.len == 4);
    try std.testing.expectEqual(@as(usize, 4), rec.len);

    std.debug.assert(std.mem.eql(usize, rec.buf[0..rec.len], plan.order));
    try std.testing.expectEqualSlices(usize, plan.order, rec.buf[0..rec.len]);
}

test "runSequential calls dispatch_fn in plan order for a fork-join graph" {
    const allocator = std.testing.allocator;

    var g = task_graph.TaskGraph.init(allocator, 5);
    defer g.deinit();

    try g.addDependency(0, 2);
    try g.addDependency(0, 3);
    try g.addDependency(2, 1);
    try g.addDependency(3, 1);

    var plan = try g.planDeterministic(allocator);
    defer plan.deinit();

    const expected_order = [_]usize{ 0, 2, 3, 1, 4 };
    try std.testing.expectEqualSlices(usize, &expected_order, plan.order);

    const Recorder = struct {
        buf: [5]usize = undefined,
        len: usize = 0,

        fn dispatch(self: *@This(), task_id: usize) void {
            std.debug.assert(self.len < self.buf.len);
            self.buf[self.len] = task_id;
            self.len += 1;
        }
    };

    var rec = Recorder{};
    runSequential(&plan, &rec, Recorder.dispatch);

    std.debug.assert(rec.len == expected_order.len);
    try std.testing.expectEqual(@as(usize, expected_order.len), rec.len);
    std.debug.assert(std.mem.eql(usize, rec.buf[0..rec.len], plan.order));
    try std.testing.expectEqualSlices(usize, plan.order, rec.buf[0..rec.len]);
}

test "runSequential single task dispatches exactly once" {
    const allocator = std.testing.allocator;

    var g = task_graph.TaskGraph.init(allocator, 1);
    defer g.deinit();

    var plan = try g.planDeterministic(allocator);
    defer plan.deinit();

    const Counter = struct {
        count: usize = 0,

        fn dispatch(self: *@This(), _: usize) void {
            self.count += 1;
        }
    };

    var ctr = Counter{};
    runSequential(&plan, &ctr, Counter.dispatch);

    std.debug.assert(ctr.count == 1);
    try std.testing.expectEqual(@as(usize, 1), ctr.count);
}
