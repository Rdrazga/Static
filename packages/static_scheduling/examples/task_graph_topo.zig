const std = @import("std");
const scheduling = @import("static_scheduling");

pub fn main() !void {
    var g = scheduling.task_graph.TaskGraph.init(std.heap.page_allocator, 4);
    defer g.deinit();

    try g.addDependency(0, 2);
    try g.addDependency(1, 2);
    try g.addDependency(2, 3);

    var plan = try g.planDeterministic(std.heap.page_allocator);
    defer plan.deinit();

    // Keep the example observable without committing to an output format.
    std.debug.print("order_len={d}\n", .{plan.order.len});
}
