const std = @import("std");
const testing = std.testing;
const sync = @import("static_sync");

test "host-thread smoke validates event wait/set handoff" {
    if (!sync.event.supports_blocking_wait) return error.SkipZigTest;

    const Context = struct {
        event: *sync.event.Event,
        waiter_started: *std.atomic.Value(bool),
        waiter_finished: *std.atomic.Value(bool),

        fn run(self: *@This()) void {
            self.waiter_started.store(true, .release);
            self.event.wait();
            self.waiter_finished.store(true, .release);
        }
    };

    var event = sync.event.Event{};
    var waiter_started = std.atomic.Value(bool).init(false);
    var waiter_finished = std.atomic.Value(bool).init(false);
    var context = Context{
        .event = &event,
        .waiter_started = &waiter_started,
        .waiter_finished = &waiter_finished,
    };

    var thread = try std.Thread.spawn(.{}, Context.run, .{&context});

    try waitForFlag(&waiter_started, 100 * std.time.ns_per_ms);
    event.set();
    thread.join();

    try testing.expect(waiter_finished.load(.acquire));
    try event.tryWait();
}

test "host-thread smoke validates semaphore wait/post handoff" {
    if (!sync.semaphore.supports_blocking_wait) return error.SkipZigTest;

    const Context = struct {
        semaphore: *sync.semaphore.Semaphore,
        waiter_started: *std.atomic.Value(bool),
        acquired_count: *std.atomic.Value(u32),

        fn run(self: *@This()) void {
            self.waiter_started.store(true, .release);
            self.semaphore.wait();
            _ = self.acquired_count.fetchAdd(1, .acq_rel);
        }
    };

    var semaphore = sync.semaphore.Semaphore{};
    var waiter_started = std.atomic.Value(bool).init(false);
    var acquired_count = std.atomic.Value(u32).init(0);
    var context = Context{
        .semaphore = &semaphore,
        .waiter_started = &waiter_started,
        .acquired_count = &acquired_count,
    };

    var thread = try std.Thread.spawn(.{}, Context.run, .{&context});

    try waitForFlag(&waiter_started, 100 * std.time.ns_per_ms);
    semaphore.post(1);
    thread.join();

    try testing.expectEqual(@as(u32, 1), acquired_count.load(.acquire));
    try testing.expectError(error.WouldBlock, semaphore.tryWait());
}

test "host-thread smoke validates wait_queue wait/wake handoff" {
    if (!sync.wait_queue.supports_wait_queue) return error.SkipZigTest;

    const Context = struct {
        state: *u32,
        waiter_started: *std.atomic.Value(bool),
        waiter_finished: *std.atomic.Value(bool),

        fn run(self: *@This()) void {
            self.waiter_started.store(true, .release);
            while (@atomicLoad(u32, self.state, .acquire) == 0) {
                sync.wait_queue.waitValue(u32, self.state, 0, .{}) catch unreachable;
            }
            self.waiter_finished.store(true, .release);
        }
    };

    var state: u32 = 0;
    var waiter_started = std.atomic.Value(bool).init(false);
    var waiter_finished = std.atomic.Value(bool).init(false);
    var context = Context{
        .state = &state,
        .waiter_started = &waiter_started,
        .waiter_finished = &waiter_finished,
    };

    var thread = try std.Thread.spawn(.{}, Context.run, .{&context});

    try waitForFlag(&waiter_started, 100 * std.time.ns_per_ms);
    @atomicStore(u32, &state, 1, .release);
    sync.wait_queue.wakeValue(u32, &state, 1);
    thread.join();

    try testing.expect(waiter_finished.load(.acquire));
}

test "host-thread smoke validates condvar signal handoff" {
    if (!sync.condvar.supports_blocking_wait) return error.SkipZigTest;

    const Context = struct {
        mutex: *std.Thread.Mutex,
        condvar: *sync.condvar.Condvar,
        ready: *bool,
        waiter_started: *std.atomic.Value(bool),
        waiter_finished: *std.atomic.Value(bool),

        fn run(self: *@This()) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.waiter_started.store(true, .release);
            while (!self.ready.*) {
                self.condvar.wait(self.mutex);
            }
            self.waiter_finished.store(true, .release);
        }
    };

    var mutex: std.Thread.Mutex = .{};
    var condvar = sync.condvar.Condvar{};
    var ready = false;
    var waiter_started = std.atomic.Value(bool).init(false);
    var waiter_finished = std.atomic.Value(bool).init(false);
    var context = Context{
        .mutex = &mutex,
        .condvar = &condvar,
        .ready = &ready,
        .waiter_started = &waiter_started,
        .waiter_finished = &waiter_finished,
    };

    var thread = try std.Thread.spawn(.{}, Context.run, .{&context});

    try waitForFlag(&waiter_started, 100 * std.time.ns_per_ms);

    mutex.lock();
    ready = true;
    mutex.unlock();
    condvar.signal();
    thread.join();

    try testing.expect(waiter_finished.load(.acquire));
}

fn waitForFlag(flag: *std.atomic.Value(bool), timeout_ns: u64) !void {
    const start = std.time.Instant.now() catch return error.SkipZigTest;
    while (!flag.load(.acquire)) {
        const elapsed = (std.time.Instant.now() catch return error.SkipZigTest).since(start);
        if (elapsed >= timeout_ns) return error.Timeout;
        std.Thread.yield() catch {};
    }
}
