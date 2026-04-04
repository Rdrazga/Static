const std = @import("std");
const sync = @import("static_sync");

pub fn main() !void {
    var barrier = try sync.barrier.Barrier.init(2);

    if (!@hasDecl(sync.barrier.Barrier, "arriveAndWait")) {
        _ = barrier.arrive();
        _ = barrier.arrive();
        return;
    }

    const Context = struct {
        barrier: *sync.barrier.Barrier,

        fn run(ctx: *@This()) void {
            ctx.barrier.arriveAndWait();
        }
    };

    var ctx = Context{ .barrier = &barrier };
    var thread = try std.Thread.spawn(.{}, Context.run, .{&ctx});
    defer thread.join();

    barrier.arriveAndWait();
}
