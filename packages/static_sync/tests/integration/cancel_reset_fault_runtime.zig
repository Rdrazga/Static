const std = @import("std");
const testing = std.testing;
const sync = @import("static_sync");

const handshake_timeout_ns: u64 = std.time.ns_per_s;

const BlockingWakeState = struct {
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

test "cancel reset fault runtime keeps wait_queue retry reusable after cancellation" {
    if (!sync.wait_queue.supports_wait_queue) return error.SkipZigTest;

    const Result = struct {
        err: ?sync.wait_queue.WaitError = null,
    };

    const Waiter = struct {
        state: *u32,
        started: *std.atomic.Value(bool),
        finished: *std.atomic.Value(bool),
        result: *Result,
        token: sync.cancel.CancelToken,

        fn run(self: *@This()) void {
            self.started.store(true, .release);
            sync.wait_queue.waitValue(u32, self.state, 0, .{
                .timeout_ns = 5 * std.time.ns_per_s,
                .cancel = self.token,
            }) catch |err| {
                self.result.err = err;
                self.finished.store(true, .release);
                return;
            };
            self.result.err = null;
            self.finished.store(true, .release);
        }
    };

    var state: u32 = 0;
    var cancel_source = sync.cancel.CancelSource{};
    const token = cancel_source.token();

    var first_started = std.atomic.Value(bool).init(false);
    var first_finished = std.atomic.Value(bool).init(false);
    var first_result = Result{};
    var first_waiter = Waiter{
        .state = &state,
        .started = &first_started,
        .finished = &first_finished,
        .result = &first_result,
        .token = token,
    };

    var first_thread = try std.Thread.spawn(.{}, Waiter.run, .{&first_waiter});
    var first_joined = false;
    defer if (!first_joined) first_thread.join();

    try waitForFlag(&first_started, handshake_timeout_ns, "first wait_queue waiter started");
    cancel_source.cancel();
    try waitForFlag(&first_finished, handshake_timeout_ns, "first wait_queue waiter finished");
    first_thread.join();
    first_joined = true;

    try testing.expectEqual(@as(?sync.wait_queue.WaitError, error.Cancelled), first_result.err);
    try testing.expect(token.isCancelled());

    cancel_source.reset();
    try testing.expect(!token.isCancelled());

    var second_started = std.atomic.Value(bool).init(false);
    var second_finished = std.atomic.Value(bool).init(false);
    var second_result = Result{};
    var second_waiter = Waiter{
        .state = &state,
        .started = &second_started,
        .finished = &second_finished,
        .result = &second_result,
        .token = token,
    };

    var second_thread = try std.Thread.spawn(.{}, Waiter.run, .{&second_waiter});
    var second_joined = false;
    defer if (!second_joined) second_thread.join();

    try waitForFlag(&second_started, handshake_timeout_ns, "second wait_queue waiter started");
    @atomicStore(u32, &state, 1, .release);
    sync.wait_queue.wakeValue(u32, &state, 1);
    try waitForFlag(&second_finished, handshake_timeout_ns, "second wait_queue waiter finished");
    second_thread.join();
    second_joined = true;

    try testing.expectEqual(@as(?sync.wait_queue.WaitError, null), second_result.err);
}

test "cancel reset fault runtime keeps unregister bounded during delayed wake propagation" {
    const Canceller = struct {
        source: *sync.cancel.CancelSource,
        started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn run(self: *@This()) void {
            self.started.store(true, .release);
            self.source.cancel();
            self.finished.store(true, .release);
        }
    };

    const Unregisterer = struct {
        registration: *sync.cancel.CancelRegistration,
        started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn run(self: *@This()) void {
            self.started.store(true, .release);
            self.registration.unregister();
            self.finished.store(true, .release);
        }
    };

    var source = sync.cancel.CancelSource{};
    const token = source.token();

    var wake_state = BlockingWakeState{};
    var registration = sync.cancel.CancelRegistration.init(blockingWake, &wake_state);
    try registration.register(token);

    var canceller = Canceller{ .source = &source };
    var canceller_thread = try std.Thread.spawn(.{}, Canceller.run, .{&canceller});
    var canceller_joined = false;
    defer if (!canceller_joined) canceller_thread.join();

    try waitForFlag(&canceller.started, handshake_timeout_ns, "canceller started");
    try waitForFlag(&wake_state.started, handshake_timeout_ns, "blocking wake started");

    var unregisterer = Unregisterer{ .registration = &registration };
    var unregister_thread = try std.Thread.spawn(.{}, Unregisterer.run, .{&unregisterer});
    var unregister_joined = false;
    defer if (!unregister_joined) unregister_thread.join();

    try waitForFlag(&unregisterer.started, handshake_timeout_ns, "unregisterer started");
    try testing.expect(!unregisterer.finished.load(.acquire));
    try testing.expect(!canceller.finished.load(.acquire));

    wake_state.release.store(true, .release);
    try waitForFlag(&wake_state.finished, handshake_timeout_ns, "blocking wake finished");
    try waitForFlag(&unregisterer.finished, handshake_timeout_ns, "unregisterer finished");
    try waitForFlag(&canceller.finished, handshake_timeout_ns, "canceller finished");

    unregister_thread.join();
    unregister_joined = true;
    canceller_thread.join();
    canceller_joined = true;

    try testing.expect(token.isCancelled());
    try testing.expect(registration.state == null);
    try testing.expectEqual(std.math.maxInt(u32), registration.slot_index);

    source.reset();
    try testing.expect(!token.isCancelled());

    var callback_count = std.atomic.Value(u32).init(0);
    var reuse_registration = sync.cancel.CancelRegistration.init(wakeCounter, &callback_count);
    try reuse_registration.register(token);
    source.cancel();
    reuse_registration.unregister();

    try testing.expectEqual(@as(u32, 1), callback_count.load(.acquire));
}

fn blockingWake(ctx: ?*anyopaque) void {
    const state: *BlockingWakeState = @ptrCast(@alignCast(ctx.?));
    state.started.store(true, .release);
    while (!state.release.load(.acquire)) {
        std.Thread.yield() catch {};
    }
    state.finished.store(true, .release);
}

fn wakeCounter(ctx: ?*anyopaque) void {
    const counter: *std.atomic.Value(u32) = @ptrCast(@alignCast(ctx.?));
    _ = counter.fetchAdd(1, .acq_rel);
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
                "static_sync cancel_reset_fault_runtime timeout waiting for {s}\n",
                .{stage_name},
            );
            return error.Timeout;
        }
        std.Thread.yield() catch {};
    }
}
