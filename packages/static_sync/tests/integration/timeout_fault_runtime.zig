const std = @import("std");
const testing = std.testing;
const sync = @import("static_sync");

const handshake_timeout_ns: u64 = std.time.ns_per_s;

test "timeout fault runtime keeps event retries explicit under delayed wake" {
    if (!@hasDecl(sync.event.Event, "timedWait")) return error.SkipZigTest;

    const Context = struct {
        event: *sync.event.Event,
        worker_ready: *std.atomic.Value(bool),
        allow_set: *std.atomic.Value(bool),
        set_count: *std.atomic.Value(u32),

        fn run(self: *@This()) void {
            self.worker_ready.store(true, .release);
            while (!self.allow_set.load(.acquire)) {
                std.Thread.yield() catch {};
            }
            self.event.set();
            _ = self.set_count.fetchAdd(1, .acq_rel);
        }
    };

    var event = sync.event.Event{};
    var worker_ready = std.atomic.Value(bool).init(false);
    var allow_set = std.atomic.Value(bool).init(false);
    var set_count = std.atomic.Value(u32).init(0);
    var context = Context{
        .event = &event,
        .worker_ready = &worker_ready,
        .allow_set = &allow_set,
        .set_count = &set_count,
    };

    var thread = try std.Thread.spawn(.{}, Context.run, .{&context});
    var joined = false;
    defer if (!joined) {
        allow_set.store(true, .release);
        thread.join();
    };

    try waitForFlag(&worker_ready, handshake_timeout_ns, "event delayed-set worker ready");
    try testing.expectError(error.Timeout, event.timedWait(0));
    try testing.expectError(error.Timeout, event.timedWait(0));

    allow_set.store(true, .release);
    try event.timedWait(100 * std.time.ns_per_ms);

    thread.join();
    joined = true;
    try testing.expectEqual(@as(u32, 1), set_count.load(.acquire));
    try event.timedWait(0);
    event.reset();
    try testing.expectError(error.Timeout, event.timedWait(0));
}

test "timeout fault runtime keeps semaphore retries explicit under delayed post" {
    if (!@hasDecl(sync.semaphore.Semaphore, "timedWait")) return error.SkipZigTest;

    const Context = struct {
        semaphore: *sync.semaphore.Semaphore,
        worker_ready: *std.atomic.Value(bool),
        allow_post: *std.atomic.Value(bool),
        post_count: *std.atomic.Value(u32),

        fn run(self: *@This()) void {
            self.worker_ready.store(true, .release);
            while (!self.allow_post.load(.acquire)) {
                std.Thread.yield() catch {};
            }
            self.semaphore.post(1);
            _ = self.post_count.fetchAdd(1, .acq_rel);
        }
    };

    var semaphore = sync.semaphore.Semaphore{};
    var worker_ready = std.atomic.Value(bool).init(false);
    var allow_post = std.atomic.Value(bool).init(false);
    var post_count = std.atomic.Value(u32).init(0);
    var context = Context{
        .semaphore = &semaphore,
        .worker_ready = &worker_ready,
        .allow_post = &allow_post,
        .post_count = &post_count,
    };

    var thread = try std.Thread.spawn(.{}, Context.run, .{&context});
    var joined = false;
    defer if (!joined) {
        allow_post.store(true, .release);
        thread.join();
    };

    try waitForFlag(&worker_ready, handshake_timeout_ns, "semaphore delayed-post worker ready");
    try testing.expectError(error.Timeout, semaphore.timedWait(0));
    try testing.expectError(error.Timeout, semaphore.timedWait(0));

    allow_post.store(true, .release);
    try semaphore.timedWait(100 * std.time.ns_per_ms);

    thread.join();
    joined = true;
    try testing.expectEqual(@as(u32, 1), post_count.load(.acquire));
    try testing.expectError(error.WouldBlock, semaphore.tryWait());

    semaphore.post(1);
    try semaphore.timedWait(0);
    try testing.expectError(error.WouldBlock, semaphore.tryWait());
}

test "timeout fault runtime keeps wait_queue retries explicit under delayed wake" {
    if (!sync.wait_queue.supports_wait_queue) return error.SkipZigTest;

    const Context = struct {
        state: *u32,
        worker_ready: *std.atomic.Value(bool),
        allow_wake: *std.atomic.Value(bool),
        wake_count: *std.atomic.Value(u32),

        fn run(self: *@This()) void {
            self.worker_ready.store(true, .release);
            while (!self.allow_wake.load(.acquire)) {
                std.Thread.yield() catch {};
            }
            @atomicStore(u32, self.state, 1, .release);
            sync.wait_queue.wakeValue(u32, self.state, 1);
            _ = self.wake_count.fetchAdd(1, .acq_rel);
        }
    };

    var state: u32 = 0;
    var worker_ready = std.atomic.Value(bool).init(false);
    var allow_wake = std.atomic.Value(bool).init(false);
    var wake_count = std.atomic.Value(u32).init(0);
    var context = Context{
        .state = &state,
        .worker_ready = &worker_ready,
        .allow_wake = &allow_wake,
        .wake_count = &wake_count,
    };

    var thread = try std.Thread.spawn(.{}, Context.run, .{&context});
    var joined = false;
    defer if (!joined) {
        allow_wake.store(true, .release);
        thread.join();
    };

    try waitForFlag(&worker_ready, handshake_timeout_ns, "wait_queue delayed-wake worker ready");
    try testing.expectError(error.Timeout, sync.wait_queue.waitValue(u32, &state, 0, .{ .timeout_ns = 0 }));
    try testing.expectError(error.Timeout, sync.wait_queue.waitValue(u32, &state, 0, .{ .timeout_ns = 0 }));

    allow_wake.store(true, .release);
    try sync.wait_queue.waitValue(u32, &state, 0, .{ .timeout_ns = 100 * std.time.ns_per_ms });

    thread.join();
    joined = true;
    try testing.expectEqual(@as(u32, 1), wake_count.load(.acquire));

    @atomicStore(u32, &state, 0, .release);
    try testing.expectError(error.Timeout, sync.wait_queue.waitValue(u32, &state, 0, .{ .timeout_ns = 0 }));
}

fn waitForFlag(
    flag: *std.atomic.Value(bool),
    timeout_ns: u64,
    stage_name: []const u8,
) !void {
    std.debug.assert(timeout_ns > 0);
    std.debug.assert(stage_name.len > 0);

    const start = sync.time_compat.Instant.now() catch return error.SkipZigTest;
    while (!flag.load(.acquire)) {
        const elapsed = (sync.time_compat.Instant.now() catch return error.SkipZigTest).since(start);
        if (elapsed >= timeout_ns) {
            std.debug.print(
                "static_sync timeout_fault_runtime timeout waiting for {s}\n",
                .{stage_name},
            );
            return error.Timeout;
        }
        std.Thread.yield() catch {};
    }
}
