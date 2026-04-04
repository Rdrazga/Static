const std = @import("std");
const q = @import("static_queues");

const Job = struct {
    id: u8,
    node: q.intrusive.Node = .{},
};

pub fn main() !void {
    var list = q.intrusive.IntrusiveList(Job, "node").init();

    var first = Job{ .id = 1 };
    var second = Job{ .id = 2 };
    list.pushBack(&first);
    list.pushBack(&second);

    _ = list.popFront().?;
}
