//! CancelToken: cooperative cancellation signal with explicit wake integration.
//!
//! The base signal is an atomic cancelled flag. For cancellable blocking waits,
//! callers may register bounded "wakers" that are invoked once on cancellation.
//!
//! Boundedness: registrations are stored in a fixed-capacity array (no allocation).
//! Safety: `unregister()` waits for an in-flight cancellation callback to finish.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const core = @import("static_core");
const time = core.time_compat;
const backoff = @import("backoff.zig");

pub const RegisterError = error{
    Cancelled,
    WouldBlock,
};

comptime {
    core.errors.assertVocabularySubset(RegisterError);
    core.errors.assertVocabularySubset(error{Cancelled});
}

pub const WakeFn = *const fn (ctx: ?*anyopaque) void;

const registration_capacity: usize = 16;
const invalid_slot: u32 = std.math.maxInt(u32);
var test_after_register_hook: ?*const fn (reg: *CancelRegistration) void = null;
const test_wait_timeout_ns: u64 = std.time.ns_per_s;
const blocked_observation_ns: u64 = 10 * std.time.ns_per_ms;

const CancelState = struct {
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    registrations: [registration_capacity]std.atomic.Value(usize) = [_]std.atomic.Value(usize){
        std.atomic.Value(usize).init(0),
    } ** registration_capacity,

    fn hasRegistrations(self: *const CancelState) bool {
        var index: usize = 0;
        while (index < self.registrations.len) : (index += 1) {
            if (self.registrations[index].load(.acquire) != 0) return true;
        }
        return false;
    }
};

pub const CancelToken = struct {
    state: *CancelState,

    pub fn isCancelled(self: CancelToken) bool {
        assert(@intFromPtr(self.state) != 0);
        const is_cancelled = self.state.cancelled.load(.acquire);
        assert(is_cancelled == true or is_cancelled == false);
        return is_cancelled;
    }

    pub fn throwIfCancelled(self: CancelToken) error{Cancelled}!void {
        assert(@intFromPtr(self.state) != 0);
        if (self.isCancelled()) return error.Cancelled;
    }
};

pub const CancelRegistration = struct {
    wake: WakeFn,
    ctx: ?*anyopaque = null,

    state: ?*CancelState = null,
    slot_index: u32 = invalid_slot,
    fired: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(wake: WakeFn, ctx: ?*anyopaque) CancelRegistration {
        return .{
            .wake = wake,
            .ctx = ctx,
        };
    }

    pub fn register(self: *CancelRegistration, token: CancelToken) RegisterError!void {
        assert(self.state == null);
        assert(self.slot_index == invalid_slot);

        if (token.isCancelled()) return error.Cancelled;

        self.fired.store(false, .release);
        self.state = token.state;

        const ptr_value: usize = @intFromPtr(self);
        var index: usize = 0;
        while (index < token.state.registrations.len) : (index += 1) {
            const slot = &token.state.registrations[index];
            if (slot.load(.acquire) != 0) continue;
            const swapped = slot.cmpxchgStrong(0, ptr_value, .acq_rel, .acquire);
            if (swapped == null) {
                self.slot_index = @intCast(index);
                break;
            }
        }

        if (self.slot_index == invalid_slot) {
            self.state = null;
            return error.WouldBlock;
        }

        if (test_after_register_hook) |hook| hook(self);

        if (!token.isCancelled()) return;

        const removed = token.state.registrations[self.slot_index].cmpxchgStrong(ptr_value, 0, .acq_rel, .acquire);
        if (removed == null) {
            self.state = null;
            self.slot_index = invalid_slot;
            return error.Cancelled;
        }

        var wait_backoff = backoff.Backoff{};
        while (!self.fired.load(.acquire)) {
            wait_backoff.step();
        }
        self.state = null;
        self.slot_index = invalid_slot;
        return error.Cancelled;
    }

    pub fn unregister(self: *CancelRegistration) void {
        const state = self.state orelse return;
        const slot_index = self.slot_index;
        if (slot_index == invalid_slot) return;
        assert(slot_index < state.registrations.len);

        const ptr_value: usize = @intFromPtr(self);
        const removed = state.registrations[slot_index].swap(0, .acq_rel);
        if (removed == ptr_value) {
            self.state = null;
            self.slot_index = invalid_slot;
            return;
        }

        var wait_backoff = backoff.Backoff{};
        while (!self.fired.load(.acquire)) {
            wait_backoff.step();
        }

        self.state = null;
        self.slot_index = invalid_slot;
    }

    fn fire(self: *CancelRegistration) void {
        self.wake(self.ctx);
        self.fired.store(true, .release);
    }
};

pub const CancelSource = struct {
    state: CancelState = .{},

    pub fn token(self: *CancelSource) CancelToken {
        const issued_token = CancelToken{ .state = &self.state };
        assert(issued_token.state == &self.state);
        return issued_token;
    }

    pub fn cancel(self: *CancelSource) void {
        const already = self.state.cancelled.swap(true, .acq_rel);
        assert(self.state.cancelled.load(.acquire));
        if (already) return;

        var index: usize = 0;
        while (index < self.state.registrations.len) : (index += 1) {
            const ptr_value = self.state.registrations[index].swap(0, .acq_rel);
            if (ptr_value == 0) continue;
            const reg: *CancelRegistration = @ptrFromInt(ptr_value);
            reg.fire();
        }
    }

    pub fn reset(self: *CancelSource) void {
        assert(!self.state.hasRegistrations());
        self.state.cancelled.store(false, .release);
        assert(!self.state.cancelled.load(.acquire));
    }
};

test "cancel source propagates to token" {
    var src = CancelSource{};
    const tok = src.token();
    assert(!tok.isCancelled());
    try testing.expect(!tok.isCancelled());
    src.cancel();
    assert(tok.isCancelled());
    try testing.expect(tok.isCancelled());
}

test "cancel throwIfCancelled returns Cancelled after cancel" {
    var src = CancelSource{};
    const tok = src.token();
    try tok.throwIfCancelled();
    src.cancel();
    try testing.expectError(error.Cancelled, tok.throwIfCancelled());
}

test "cancel reset clears cancelled state" {
    var src = CancelSource{};
    const tok = src.token();
    src.cancel();
    assert(tok.isCancelled());
    src.reset();
    try testing.expect(!tok.isCancelled());
}

test "cancel is idempotent and shared across issued tokens" {
    var src = CancelSource{};
    const token_a = src.token();
    const token_b = src.token();

    src.cancel();
    src.cancel();
    try testing.expect(token_a.isCancelled());
    try testing.expect(token_b.isCancelled());

    src.reset();
    src.reset();
    try testing.expect(!token_a.isCancelled());
    try testing.expect(!token_b.isCancelled());
}

fn wakeCounter(ctx: ?*anyopaque) void {
    const counter: *std.atomic.Value(u32) = @ptrCast(@alignCast(ctx.?));
    _ = counter.fetchAdd(1, .acq_rel);
}

const BlockingWakeState = struct {
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn blockingWake(ctx: ?*anyopaque) void {
    const state: *BlockingWakeState = @ptrCast(@alignCast(ctx.?));
    state.started.store(true, .release);
    while (!state.release.load(.acquire)) {
        std.Thread.yield() catch {};
    }
    state.finished.store(true, .release);
}

test "cancel registration fires wake callback" {
    var src = CancelSource{};
    const tok = src.token();

    var counter = std.atomic.Value(u32).init(0);
    var reg = CancelRegistration.init(wakeCounter, &counter);
    try reg.register(tok);
    defer reg.unregister();

    src.cancel();
    try testing.expectEqual(@as(u32, 1), counter.load(.acquire));
}

test "cancel fanout invokes every registered wake exactly once" {
    var src = CancelSource{};
    const tok = src.token();

    var counters = [_]std.atomic.Value(u32){
        std.atomic.Value(u32).init(0),
        std.atomic.Value(u32).init(0),
        std.atomic.Value(u32).init(0),
    };
    var regs = [_]CancelRegistration{
        CancelRegistration.init(wakeCounter, &counters[0]),
        CancelRegistration.init(wakeCounter, &counters[1]),
        CancelRegistration.init(wakeCounter, &counters[2]),
    };

    var index: usize = 0;
    while (index < regs.len) : (index += 1) {
        try regs[index].register(tok);
    }

    src.cancel();
    src.cancel();

    index = 0;
    while (index < counters.len) : (index += 1) {
        try testing.expectEqual(@as(u32, 1), counters[index].load(.acquire));
    }

    index = 0;
    while (index < regs.len) : (index += 1) {
        regs[index].unregister();
    }
}

test "cancel reset allows fanout registrations to re-register and fire again" {
    var src = CancelSource{};
    const tok = src.token();

    var counters = [_]std.atomic.Value(u32){
        std.atomic.Value(u32).init(0),
        std.atomic.Value(u32).init(0),
        std.atomic.Value(u32).init(0),
    };
    var regs = [_]CancelRegistration{
        CancelRegistration.init(wakeCounter, &counters[0]),
        CancelRegistration.init(wakeCounter, &counters[1]),
        CancelRegistration.init(wakeCounter, &counters[2]),
    };

    var index: usize = 0;
    while (index < regs.len) : (index += 1) {
        try regs[index].register(tok);
        try testing.expectEqual(@as(u32, @intCast(index)), regs[index].slot_index);
    }

    src.cancel();
    index = 0;
    while (index < counters.len) : (index += 1) {
        try testing.expectEqual(@as(u32, 1), counters[index].load(.acquire));
        regs[index].unregister();
        try testing.expect(regs[index].state == null);
        try testing.expectEqual(invalid_slot, regs[index].slot_index);
    }

    src.reset();
    try testing.expect(!tok.isCancelled());

    index = 0;
    while (index < regs.len) : (index += 1) {
        try regs[index].register(tok);
        try testing.expectEqual(@as(u32, @intCast(index)), regs[index].slot_index);
    }

    src.cancel();
    index = 0;
    while (index < counters.len) : (index += 1) {
        try testing.expectEqual(@as(u32, 2), counters[index].load(.acquire));
        regs[index].unregister();
        try testing.expect(regs[index].state == null);
        try testing.expectEqual(invalid_slot, regs[index].slot_index);
    }
}

test "cancel unregister waits for in-flight callback to finish" {
    var src = CancelSource{};
    const tok = src.token();

    var wake_state = BlockingWakeState{};
    var reg = CancelRegistration.init(blockingWake, &wake_state);
    try reg.register(tok);

    const Canceller = struct {
        src: *CancelSource,
        started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn run(self: *@This()) void {
            self.started.store(true, .release);
            self.src.cancel();
            self.done.store(true, .release);
        }
    };

    const Unregisterer = struct {
        reg: *CancelRegistration,
        started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn run(self: *@This()) void {
            self.started.store(true, .release);
            self.reg.unregister();
            self.done.store(true, .release);
        }
    };

    var canceller = Canceller{ .src = &src };
    var cancel_thread = try std.Thread.spawn(.{}, Canceller.run, .{&canceller});
    var cancel_thread_joined = false;
    defer wake_state.release.store(true, .release);
    defer if (!cancel_thread_joined) cancel_thread.join();

    try waitForFlagTrue(&canceller.started, test_wait_timeout_ns);
    try waitForFlagTrue(&wake_state.started, test_wait_timeout_ns);

    var unregisterer = Unregisterer{ .reg = &reg };
    var unregister_thread = try std.Thread.spawn(.{}, Unregisterer.run, .{&unregisterer});
    var unregister_thread_joined = false;
    defer if (!unregister_thread_joined) unregister_thread.join();

    try waitForFlagTrue(&unregisterer.started, test_wait_timeout_ns);
    try expectFlagStaysFalse(&unregisterer.done, blocked_observation_ns);

    wake_state.release.store(true, .release);
    unregister_thread.join();
    unregister_thread_joined = true;
    cancel_thread.join();
    cancel_thread_joined = true;

    try testing.expect(wake_state.finished.load(.acquire));
    try testing.expect(unregisterer.done.load(.acquire));
    try testing.expect(canceller.done.load(.acquire));
    try testing.expect(tok.isCancelled());
    try testing.expect(reg.state == null);
    try testing.expectEqual(invalid_slot, reg.slot_index);
}

fn noopWake(_: ?*anyopaque) void {}

test "cancel registration enforces fixed capacity and reuses freed slot" {
    var src = CancelSource{};
    const tok = src.token();

    var regs: [registration_capacity]CancelRegistration = undefined;
    var index: usize = 0;
    while (index < regs.len) : (index += 1) {
        regs[index] = CancelRegistration.init(noopWake, null);
        try regs[index].register(tok);
        try testing.expectEqual(@as(u32, @intCast(index)), regs[index].slot_index);
    }

    var overflow = CancelRegistration.init(noopWake, null);
    try testing.expectError(error.WouldBlock, overflow.register(tok));
    try testing.expect(overflow.state == null);
    try testing.expectEqual(invalid_slot, overflow.slot_index);

    const reused_index: usize = 5;
    regs[reused_index].unregister();
    try testing.expect(regs[reused_index].state == null);
    try testing.expectEqual(invalid_slot, regs[reused_index].slot_index);

    try overflow.register(tok);
    defer overflow.unregister();
    try testing.expectEqual(@as(u32, @intCast(reused_index)), overflow.slot_index);

    index = 0;
    while (index < regs.len) : (index += 1) {
        if (index == reused_index) continue;
        regs[index].unregister();
        try testing.expect(regs[index].state == null);
        try testing.expectEqual(invalid_slot, regs[index].slot_index);
    }
}

test "cancel registration reports Cancelled when cancel races after slot install" {
    const HookState = struct {
        installed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    };

    const RegisterRunner = struct {
        reg: *CancelRegistration,
        token: CancelToken,
        result: ?RegisterError = null,
        finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn run(self: *@This()) void {
            self.reg.register(self.token) catch |err| {
                self.result = err;
                self.finished.store(true, .release);
                return;
            };
            self.result = null;
            self.finished.store(true, .release);
        }
    };

    const hook_state = struct {
        var state = HookState{};
    };

    const hook = struct {
        fn run(reg: *CancelRegistration) void {
            _ = reg;
            hook_state.state.installed.store(true, .release);
            while (!hook_state.state.release.load(.acquire)) {
                std.Thread.yield() catch {};
            }
        }
    }.run;

    var src = CancelSource{};
    const tok = src.token();
    var counter = std.atomic.Value(u32).init(0);
    var reg = CancelRegistration.init(wakeCounter, &counter);

    hook_state.state = .{};
    test_after_register_hook = hook;
    defer test_after_register_hook = null;

    var runner = RegisterRunner{
        .reg = &reg,
        .token = tok,
    };
    var register_thread = try std.Thread.spawn(.{}, RegisterRunner.run, .{&runner});
    var register_thread_joined = false;
    defer hook_state.state.release.store(true, .release);
    defer if (!register_thread_joined) register_thread.join();

    try waitForFlagTrue(&hook_state.state.installed, test_wait_timeout_ns);
    src.cancel();
    hook_state.state.release.store(true, .release);
    register_thread.join();
    register_thread_joined = true;

    try testing.expect(runner.finished.load(.acquire));
    try testing.expectEqual(@as(?RegisterError, error.Cancelled), runner.result);
    try testing.expect(tok.isCancelled());
    try testing.expectEqual(@as(u32, 1), counter.load(.acquire));
    try testing.expect(reg.state == null);
    try testing.expectEqual(invalid_slot, reg.slot_index);
}

test "register after cancellation returns Cancelled" {
    var src = CancelSource{};
    src.cancel();
    const tok = src.token();

    var counter = std.atomic.Value(u32).init(0);
    var reg = CancelRegistration.init(wakeCounter, &counter);
    try testing.expectError(error.Cancelled, reg.register(tok));
}

fn waitForFlagTrue(flag: *const std.atomic.Value(bool), timeout_ns: u64) !void {
    const start = time.Instant.now() catch return error.SkipZigTest;
    while (!flag.load(.acquire)) {
        const elapsed = (time.Instant.now() catch return error.SkipZigTest).since(start);
        if (elapsed >= timeout_ns) return error.Timeout;
        std.Thread.yield() catch {};
    }
}

fn expectFlagStaysFalse(flag: *const std.atomic.Value(bool), duration_ns: u64) !void {
    const start = time.Instant.now() catch return error.SkipZigTest;
    while (true) {
        try testing.expect(!flag.load(.acquire));
        const elapsed = (time.Instant.now() catch return error.SkipZigTest).since(start);
        if (elapsed >= duration_ns) return;
        std.Thread.yield() catch {};
    }
}
