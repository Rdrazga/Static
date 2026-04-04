//! Once: run-once initialization guard.
//!
//! Thread safety: safe for concurrent use; exactly one caller's `call` function executes even under contention.
//! Single-threaded mode: the mutex is a no-op; `call` executes on the first invocation.
const std = @import("std");
const caps = @import("caps.zig");
const mutex = std.Thread;
const padded_atomic = @import("padded_atomic.zig");

pub const Once = struct {
    // On its own cache line: read on every fast-path call to avoid false sharing
    // with the mutex and other per-instance data.
    done: padded_atomic.PaddedAtomic(bool) = .{ .value = std.atomic.Value(bool).init(false) },
    mutex: mutex.Mutex = .{},

    pub fn call(self: *Once, f: anytype) void {
        if (self.done.load(.acquire)) {
            std.debug.assert(self.done.load(.acquire));
            return;
        }
        self.callSlow(f);
        std.debug.assert(self.done.load(.acquire));
    }

    fn callSlow(self: *Once, f: anytype) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        // Assertion 1: holding the mutex, monotonic and acquire loads must agree
        // on the done flag -- a coherence check that both orderings observe the
        // same value once the write fence from a prior store(release) is visible.
        std.debug.assert(self.done.load(.monotonic) == self.done.load(.acquire));
        // Assertion 2: if done is already true we must not call f again, so
        // document that the flag being set implies acquire load also sees it.
        if (self.done.load(.monotonic)) std.debug.assert(self.done.load(.acquire));

        if (!self.done.load(.monotonic)) {
            f();
            self.done.store(true, .release);
            std.debug.assert(self.done.load(.acquire));
            return;
        }

        std.debug.assert(self.done.load(.acquire));
    }
};

var once_test_count: u32 = 0;
var once_thread_count = std.atomic.Value(u32).init(0);

fn bumpOnceTestCount() void {
    once_test_count += 1;
}

test "once executes function at most once" {
    // Goal: verify repeated calls execute the callback once.
    // Method: invoke twice on same instance and observe shared counter.
    once_test_count = 0;
    var once = Once{};
    once.call(bumpOnceTestCount);
    once.call(bumpOnceTestCount);
    std.debug.assert(once_test_count == 1);
    try std.testing.expectEqual(@as(u32, 1), once_test_count);
}

test "once with zero calls does not invoke function" {
    // Goal: verify construction has no side effects.
    // Method: create instance without calling `call` and check counter.
    once_test_count = 0;
    _ = Once{};
    try std.testing.expectEqual(@as(u32, 0), once_test_count);
}

test "once is idempotent across many calls" {
    // Goal: verify idempotence under repeated sequential calls.
    // Method: loop multiple invocations and assert single execution.
    once_test_count = 0;
    var once = Once{};
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        once.call(bumpOnceTestCount);
    }
    std.debug.assert(once_test_count == 1);
    try std.testing.expectEqual(@as(u32, 1), once_test_count);
}

fn bumpThreadCount() void {
    _ = once_thread_count.fetchAdd(1, .acq_rel);
}

var once_blocking_started = std.atomic.Value(bool).init(false);
var once_blocking_release = std.atomic.Value(bool).init(false);
var once_blocking_executed = std.atomic.Value(u32).init(0);
var once_contender_executed = std.atomic.Value(u32).init(0);

fn blockingOnceInit() void {
    _ = once_blocking_executed.fetchAdd(1, .acq_rel);
    once_blocking_started.store(true, .release);
    while (!once_blocking_release.load(.acquire)) {
        std.Thread.yield() catch {};
    }
}

fn contenderOnceInit() void {
    _ = once_contender_executed.fetchAdd(1, .acq_rel);
}

test "once contending callers do not return before active initializer completes" {
    // Goal: verify competing callers stay blocked until the winning initializer
    // completes and publishes the done flag.
    // Method: hold the first initializer in-flight, race a second caller, and
    // require the second caller to remain incomplete until release.
    if (!caps.Caps.threads_enabled) return error.SkipZigTest;

    const Contender = struct {
        once: *Once,
        started: *std.atomic.Value(bool),
        done: *std.atomic.Value(bool),

        fn run(self: *@This()) void {
            self.started.store(true, .release);
            self.once.call(contenderOnceInit);
            self.done.store(true, .release);
        }
    };

    const InitThread = struct {
        once: *Once,

        fn run(self: *@This()) void {
            self.once.call(blockingOnceInit);
        }
    };

    once_blocking_started.store(false, .release);
    once_blocking_release.store(false, .release);
    once_blocking_executed.store(0, .release);
    once_contender_executed.store(0, .release);
    var contender_started = std.atomic.Value(bool).init(false);
    var contender_done = std.atomic.Value(bool).init(false);
    var once = Once{};

    var init_ctx = InitThread{ .once = &once };
    var init_thread = try std.Thread.spawn(.{}, InitThread.run, .{&init_ctx});

    try std.testing.expect(waitForBoolTrue(&once_blocking_started, 10_000));
    try std.testing.expect(!once.done.load(.acquire));

    var contender = Contender{
        .once = &once,
        .started = &contender_started,
        .done = &contender_done,
    };
    var contender_thread = try std.Thread.spawn(.{}, Contender.run, .{&contender});

    try std.testing.expect(waitForBoolTrue(&contender_started, 10_000));
    try std.testing.expect(flagStaysFalse(&contender_done, 10_000));
    try std.testing.expect(!once.done.load(.acquire));

    once_blocking_release.store(true, .release);
    init_thread.join();
    contender_thread.join();

    try std.testing.expectEqual(@as(u32, 1), once_blocking_executed.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), once_contender_executed.load(.acquire));
    try std.testing.expect(contender_done.load(.acquire));
    try std.testing.expect(once.done.load(.acquire));
}

test "once executes function once across threads" {
    // Goal: verify callback execution remains one-shot under contention.
    // Method: spawn several callers that race on the same `Once`.
    if (!caps.Caps.threads_enabled) return error.SkipZigTest;

    const Context = struct {
        once: *Once,

        fn run(ctx: *@This()) void {
            ctx.once.call(bumpThreadCount);
        }
    };

    once_thread_count.store(0, .release);
    var once = Once{};
    var ctx = Context{ .once = &once };

    var t0 = try std.Thread.spawn(.{}, Context.run, .{&ctx});
    var t1 = try std.Thread.spawn(.{}, Context.run, .{&ctx});
    var t2 = try std.Thread.spawn(.{}, Context.run, .{&ctx});
    defer t0.join();
    defer t1.join();
    defer t2.join();

    once.call(bumpThreadCount);

    try std.testing.expectEqual(@as(u32, 1), once_thread_count.load(.acquire));
}

fn waitForBoolTrue(flag: *const std.atomic.Value(bool), iterations_max: u32) bool {
    var iterations: u32 = 0;
    while (iterations < iterations_max) : (iterations += 1) {
        if (flag.load(.acquire)) return true;
        std.Thread.yield() catch {};
    }
    return false;
}

fn flagStaysFalse(flag: *const std.atomic.Value(bool), iterations_max: u32) bool {
    var iterations: u32 = 0;
    while (iterations < iterations_max) : (iterations += 1) {
        if (flag.load(.acquire)) return false;
        std.Thread.yield() catch {};
    }
    return true;
}
