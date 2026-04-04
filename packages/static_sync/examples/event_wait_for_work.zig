const std = @import("std");
const sync = @import("static_sync");

pub fn main() !void {
    var event = sync.event.Event{};

    if (@hasDecl(sync.event.Event, "wait")) {
        const Context = struct {
            event: *sync.event.Event,

            fn run(ctx: *@This()) void {
                ctx.event.set();
            }
        };

        var ctx = Context{ .event = &event };
        var thread = try std.Thread.spawn(.{}, Context.run, .{&ctx});
        defer thread.join();
        event.wait();
        return;
    }

    event.tryWait() catch |err| switch (err) {
        error.WouldBlock => {},
    };
    event.set();
    try event.tryWait();
}
