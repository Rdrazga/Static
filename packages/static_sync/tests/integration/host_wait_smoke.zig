const std = @import("std");
const testing = std.testing;
const sync = @import("static_sync");

const handshake_timeout_ns: u64 = std.time.ns_per_s;

test "host-thread smoke validates event wait/set handoff" {
    if (!sync.event.supports_blocking_wait) return error.SkipZigTest;

    const Context = struct {
        event: *sync.event.Event,
        waiter_ready: *std.atomic.Value(bool),
        waiter_finished: *std.atomic.Value(bool),

        fn run(self: *@This()) void {
            self.waiter_ready.store(true, .release);
            self.event.wait();
            self.waiter_finished.store(true, .release);
        }
    };

    var event = sync.event.Event{};
    var waiter_ready = std.atomic.Value(bool).init(false);
    var waiter_finished = std.atomic.Value(bool).init(false);
    var context = Context{
        .event = &event,
        .waiter_ready = &waiter_ready,
        .waiter_finished = &waiter_finished,
    };

    var thread = try std.Thread.spawn(.{}, Context.run, .{&context});
    var joined = false;
    defer if (!joined) {
        event.set();
        thread.join();
    };

    try waitForFlag(&waiter_ready, handshake_timeout_ns, "event waiter ready");
    event.set();
    thread.join();
    joined = true;

    try testing.expect(waiter_finished.load(.acquire));
    try event.tryWait();
}

test "host-thread smoke validates semaphore wait/post handoff" {
    if (!sync.semaphore.supports_blocking_wait) return error.SkipZigTest;

    const Context = struct {
        semaphore: *sync.semaphore.Semaphore,
        waiter_ready: *std.atomic.Value(bool),
        acquired_count: *std.atomic.Value(u32),

        fn run(self: *@This()) void {
            self.waiter_ready.store(true, .release);
            self.semaphore.wait();
            _ = self.acquired_count.fetchAdd(1, .acq_rel);
        }
    };

    var semaphore = sync.semaphore.Semaphore{};
    var waiter_ready = std.atomic.Value(bool).init(false);
    var acquired_count = std.atomic.Value(u32).init(0);
    var context = Context{
        .semaphore = &semaphore,
        .waiter_ready = &waiter_ready,
        .acquired_count = &acquired_count,
    };

    var thread = try std.Thread.spawn(.{}, Context.run, .{&context});
    var joined = false;
    defer if (!joined) {
        semaphore.post(1);
        thread.join();
    };

    try waitForFlag(&waiter_ready, handshake_timeout_ns, "semaphore waiter ready");
    semaphore.post(1);
    thread.join();
    joined = true;

    try testing.expectEqual(@as(u32, 1), acquired_count.load(.acquire));
    try testing.expectError(error.WouldBlock, semaphore.tryWait());
}

test "host-thread smoke validates wait_queue wait/wake handoff" {
    if (!sync.wait_queue.supports_wait_queue) return error.SkipZigTest;

    const Context = struct {
        state: *u32,
        waiter_ready: *std.atomic.Value(bool),
        waiter_finished: *std.atomic.Value(bool),

        fn run(self: *@This()) void {
            while (@atomicLoad(u32, self.state, .acquire) == 0) {
                self.waiter_ready.store(true, .release);
                sync.wait_queue.waitValue(u32, self.state, 0, .{}) catch unreachable;
            }
            self.waiter_finished.store(true, .release);
        }
    };

    var state: u32 = 0;
    var waiter_ready = std.atomic.Value(bool).init(false);
    var waiter_finished = std.atomic.Value(bool).init(false);
    var context = Context{
        .state = &state,
        .waiter_ready = &waiter_ready,
        .waiter_finished = &waiter_finished,
    };

    var thread = try std.Thread.spawn(.{}, Context.run, .{&context});
    var joined = false;
    defer if (!joined) {
        @atomicStore(u32, &state, 1, .release);
        sync.wait_queue.wakeValue(u32, &state, 1);
        thread.join();
    };

    try waitForFlag(&waiter_ready, handshake_timeout_ns, "wait_queue waiter ready");
    @atomicStore(u32, &state, 1, .release);
    sync.wait_queue.wakeValue(u32, &state, 1);
    thread.join();
    joined = true;

    try testing.expect(waiter_finished.load(.acquire));
}

test "host-thread smoke validates condvar signal handoff" {
    if (!sync.condvar.supports_blocking_wait) return error.SkipZigTest;

    const Context = struct {
        mutex: *sync.threading.Mutex,
        condvar: *sync.condvar.Condvar,
        ready: *bool,
        waiter_ready: *std.atomic.Value(bool),
        waiter_finished: *std.atomic.Value(bool),

        fn run(self: *@This()) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.waiter_ready.store(true, .release);
            while (!self.ready.*) {
                self.condvar.wait(self.mutex);
            }
            self.waiter_finished.store(true, .release);
        }
    };

    var mutex: sync.threading.Mutex = .{};
    var condvar = sync.condvar.Condvar{};
    var ready = false;
    var waiter_ready = std.atomic.Value(bool).init(false);
    var waiter_finished = std.atomic.Value(bool).init(false);
    var context = Context{
        .mutex = &mutex,
        .condvar = &condvar,
        .ready = &ready,
        .waiter_ready = &waiter_ready,
        .waiter_finished = &waiter_finished,
    };

    var thread = try std.Thread.spawn(.{}, Context.run, .{&context});
    var joined = false;
    defer if (!joined) {
        mutex.lock();
        ready = true;
        mutex.unlock();
        condvar.signal();
        thread.join();
    };

    try waitForFlag(&waiter_ready, handshake_timeout_ns, "condvar waiter ready");

    mutex.lock();
    ready = true;
    mutex.unlock();
    condvar.signal();
    thread.join();
    joined = true;

    try testing.expect(waiter_finished.load(.acquire));
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
                "static_sync host_wait_smoke timeout waiting for {s}\n",
                .{stage_name},
            );
            return error.Timeout;
        }
        std.Thread.yield() catch {};
    }
}
