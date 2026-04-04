//! Demonstrates a bounded wait-queue handoff for a single aligned value.
const std = @import("std");
const sync = @import("static_sync");

pub fn main() !void {
    var state: u32 = 0;
    var waiter_started = std.atomic.Value(bool).init(false);
    var waiter_finished = std.atomic.Value(bool).init(false);
    var start_timer = try std.time.Timer.start();
    const waiter_start_timeout_ns = 1 * std.time.ns_per_s;

    if (!sync.wait_queue.supports_wait_queue) {
        try std.testing.expectError(
            error.Unsupported,
            sync.wait_queue.waitValue(u32, &state, 0, .{}),
        );
        return;
    }

    const Context = struct {
        state: *u32,
        waiter_started: *std.atomic.Value(bool),
        waiter_finished: *std.atomic.Value(bool),

        fn run(self: *@This()) void {
            std.debug.assert(@atomicLoad(u32, self.state, .acquire) == 0);
            self.waiter_started.store(true, .release);
            sync.wait_queue.waitValue(u32, self.state, 0, .{}) catch unreachable;
            std.debug.assert(@atomicLoad(u32, self.state, .acquire) == 1);
            self.waiter_finished.store(true, .release);
        }
    };

    var ctx = Context{
        .state = &state,
        .waiter_started = &waiter_started,
        .waiter_finished = &waiter_finished,
    };
    var thread = try std.Thread.spawn(.{}, Context.run, .{&ctx});

    while (!waiter_started.load(.acquire)) {
        if (start_timer.read() > waiter_start_timeout_ns) return error.WaiterStartTimeout;
        std.Thread.yield() catch unreachable;
    }

    @atomicStore(u32, &state, 1, .release);
    sync.wait_queue.wakeValue(u32, &state, 1);
    thread.join();

    std.debug.assert(waiter_finished.load(.acquire));
    std.debug.assert(@atomicLoad(u32, &state, .acquire) == 1);
}
