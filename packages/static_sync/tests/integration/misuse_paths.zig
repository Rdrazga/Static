const std = @import("std");
const sync = @import("static_sync");

test "misuse-paths keep cancel unregister-after-fire and reset-after-cancel safe" {
    var source = sync.cancel.CancelSource{};
    const token = source.token();

    var callback_count = std.atomic.Value(u32).init(0);
    var registration = sync.cancel.CancelRegistration.init(wakeCounter, &callback_count);

    try registration.register(token);
    source.cancel();
    registration.unregister();

    try std.testing.expectEqual(@as(u32, 1), callback_count.load(.acquire));
    try std.testing.expect(token.isCancelled());

    source.reset();
    try std.testing.expect(!token.isCancelled());

    try registration.register(token);
    registration.unregister();
    try std.testing.expectEqual(@as(u32, 1), callback_count.load(.acquire));
}

test "misuse-paths keep zero-timeout semantics explicit across wait primitives" {
    if (@hasDecl(sync.event.Event, "timedWait")) {
        var event = sync.event.Event{};
        try std.testing.expectError(error.Timeout, event.timedWait(0));
        event.set();
        try event.timedWait(0);
    }

    if (@hasDecl(sync.semaphore.Semaphore, "timedWait")) {
        var semaphore = sync.semaphore.Semaphore{};
        try std.testing.expectError(error.Timeout, semaphore.timedWait(0));
        semaphore.post(1);
        try semaphore.timedWait(0);
        try std.testing.expectError(error.WouldBlock, semaphore.tryWait());
    }

    if (sync.wait_queue.supports_wait_queue) {
        var state: u32 = 0;
        try std.testing.expectError(error.Timeout, sync.wait_queue.waitValue(u32, &state, 0, .{
            .timeout_ns = 0,
        }));

        @atomicStore(u32, &state, 1, .release);
        try sync.wait_queue.waitValue(u32, &state, 0, .{
            .timeout_ns = 0,
        });
    }
}

test "misuse-paths keep semaphore saturating post behavior bounded" {
    var semaphore = sync.semaphore.Semaphore{};
    semaphore.post(std.math.maxInt(usize));
    semaphore.post(1);

    var consume_count: usize = 0;
    while (consume_count < 4) : (consume_count += 1) {
        try semaphore.tryWait();
    }

    semaphore.post(2);
    try semaphore.tryWait();
    try semaphore.tryWait();
}

fn wakeCounter(ctx: ?*anyopaque) void {
    const counter: *std.atomic.Value(u32) = @ptrCast(@alignCast(ctx.?));
    _ = counter.fetchAdd(1, .acq_rel);
}
