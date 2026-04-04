//! CancelToken: cooperative cancellation signal with explicit wake integration.
//!
//! The base signal is an atomic cancelled flag. For cancellable blocking waits,
//! callers may register bounded "wakers" that are invoked once on cancellation.
//!
//! Boundedness: registrations are stored in a fixed-capacity array (no allocation).
//! Safety: `unregister()` waits for an in-flight cancellation callback to finish.

const std = @import("std");
const core = @import("static_core");

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
        std.debug.assert(@intFromPtr(self.state) != 0);
        const is_cancelled = self.state.cancelled.load(.acquire);
        std.debug.assert(is_cancelled == true or is_cancelled == false);
        return is_cancelled;
    }

    pub fn throwIfCancelled(self: CancelToken) error{Cancelled}!void {
        std.debug.assert(@intFromPtr(self.state) != 0);
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
        std.debug.assert(self.state == null);
        std.debug.assert(self.slot_index == invalid_slot);

        if (token.isCancelled()) return error.Cancelled;

        self.fired.store(false, .release);
        self.state = token.state;

        const ptr_value: usize = @intFromPtr(self);
        var index: usize = 0;
        while (index < token.state.registrations.len) : (index += 1) {
            const swapped = token.state.registrations[index].cmpxchgStrong(0, ptr_value, .acq_rel, .acquire);
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

        while (!self.fired.load(.acquire)) {
            std.atomic.spinLoopHint();
        }
        self.state = null;
        self.slot_index = invalid_slot;
        return error.Cancelled;
    }

    pub fn unregister(self: *CancelRegistration) void {
        const state = self.state orelse return;
        const slot_index = self.slot_index;
        if (slot_index == invalid_slot) return;
        std.debug.assert(slot_index < state.registrations.len);

        const ptr_value: usize = @intFromPtr(self);
        const removed = state.registrations[slot_index].swap(0, .acq_rel);
        if (removed == ptr_value) {
            self.state = null;
            self.slot_index = invalid_slot;
            return;
        }

        while (!self.fired.load(.acquire)) {
            std.atomic.spinLoopHint();
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
        std.debug.assert(issued_token.state == &self.state);
        return issued_token;
    }

    pub fn cancel(self: *CancelSource) void {
        const already = self.state.cancelled.swap(true, .acq_rel);
        std.debug.assert(self.state.cancelled.load(.acquire));
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
        std.debug.assert(!self.state.hasRegistrations());
        self.state.cancelled.store(false, .release);
        std.debug.assert(!self.state.cancelled.load(.acquire));
    }
};

test "cancel source propagates to token" {
    var src = CancelSource{};
    const tok = src.token();
    std.debug.assert(!tok.isCancelled());
    try std.testing.expect(!tok.isCancelled());
    src.cancel();
    std.debug.assert(tok.isCancelled());
    try std.testing.expect(tok.isCancelled());
}

test "cancel throwIfCancelled returns Cancelled after cancel" {
    var src = CancelSource{};
    const tok = src.token();
    try tok.throwIfCancelled();
    src.cancel();
    try std.testing.expectError(error.Cancelled, tok.throwIfCancelled());
}

test "cancel reset clears cancelled state" {
    var src = CancelSource{};
    const tok = src.token();
    src.cancel();
    std.debug.assert(tok.isCancelled());
    src.reset();
    try std.testing.expect(!tok.isCancelled());
}

test "cancel is idempotent and shared across issued tokens" {
    var src = CancelSource{};
    const token_a = src.token();
    const token_b = src.token();

    src.cancel();
    src.cancel();
    try std.testing.expect(token_a.isCancelled());
    try std.testing.expect(token_b.isCancelled());

    src.reset();
    src.reset();
    try std.testing.expect(!token_a.isCancelled());
    try std.testing.expect(!token_b.isCancelled());
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
    try std.testing.expectEqual(@as(u32, 1), counter.load(.acquire));
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
        try std.testing.expectEqual(@as(u32, 1), counters[index].load(.acquire));
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
        try std.testing.expectEqual(@as(u32, @intCast(index)), regs[index].slot_index);
    }

    src.cancel();
    index = 0;
    while (index < counters.len) : (index += 1) {
        try std.testing.expectEqual(@as(u32, 1), counters[index].load(.acquire));
        regs[index].unregister();
        try std.testing.expect(regs[index].state == null);
        try std.testing.expectEqual(invalid_slot, regs[index].slot_index);
    }

    src.reset();
    try std.testing.expect(!tok.isCancelled());

    index = 0;
    while (index < regs.len) : (index += 1) {
        try regs[index].register(tok);
        try std.testing.expectEqual(@as(u32, @intCast(index)), regs[index].slot_index);
    }

    src.cancel();
    index = 0;
    while (index < counters.len) : (index += 1) {
        try std.testing.expectEqual(@as(u32, 2), counters[index].load(.acquire));
        regs[index].unregister();
        try std.testing.expect(regs[index].state == null);
        try std.testing.expectEqual(invalid_slot, regs[index].slot_index);
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

    try std.testing.expect(waitForFlagTrue(&canceller.started, 10_000));
    try std.testing.expect(waitForFlagTrue(&wake_state.started, 10_000));

    var unregisterer = Unregisterer{ .reg = &reg };
    var unregister_thread = try std.Thread.spawn(.{}, Unregisterer.run, .{&unregisterer});

    try std.testing.expect(waitForFlagTrue(&unregisterer.started, 10_000));
    var iterations: u32 = 0;
    while (iterations < 1_000) : (iterations += 1) {
        try std.testing.expect(!unregisterer.done.load(.acquire));
        std.Thread.yield() catch {};
    }

    wake_state.release.store(true, .release);
    unregister_thread.join();
    cancel_thread.join();

    try std.testing.expect(wake_state.finished.load(.acquire));
    try std.testing.expect(unregisterer.done.load(.acquire));
    try std.testing.expect(canceller.done.load(.acquire));
    try std.testing.expect(tok.isCancelled());
    try std.testing.expect(reg.state == null);
    try std.testing.expectEqual(invalid_slot, reg.slot_index);
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
        try std.testing.expectEqual(@as(u32, @intCast(index)), regs[index].slot_index);
    }

    var overflow = CancelRegistration.init(noopWake, null);
    try std.testing.expectError(error.WouldBlock, overflow.register(tok));
    try std.testing.expect(overflow.state == null);
    try std.testing.expectEqual(invalid_slot, overflow.slot_index);

    const reused_index: usize = 5;
    regs[reused_index].unregister();
    try std.testing.expect(regs[reused_index].state == null);
    try std.testing.expectEqual(invalid_slot, regs[reused_index].slot_index);

    try overflow.register(tok);
    defer overflow.unregister();
    try std.testing.expectEqual(@as(u32, @intCast(reused_index)), overflow.slot_index);

    index = 0;
    while (index < regs.len) : (index += 1) {
        if (index == reused_index) continue;
        regs[index].unregister();
        try std.testing.expect(regs[index].state == null);
        try std.testing.expectEqual(invalid_slot, regs[index].slot_index);
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

    try std.testing.expect(waitForFlagTrue(&hook_state.state.installed, 10_000));
    src.cancel();
    hook_state.state.release.store(true, .release);
    register_thread.join();

    try std.testing.expect(runner.finished.load(.acquire));
    try std.testing.expectEqual(@as(?RegisterError, error.Cancelled), runner.result);
    try std.testing.expect(tok.isCancelled());
    try std.testing.expectEqual(@as(u32, 1), counter.load(.acquire));
    try std.testing.expect(reg.state == null);
    try std.testing.expectEqual(invalid_slot, reg.slot_index);
}

test "register after cancellation returns Cancelled" {
    var src = CancelSource{};
    src.cancel();
    const tok = src.token();

    var counter = std.atomic.Value(u32).init(0);
    var reg = CancelRegistration.init(wakeCounter, &counter);
    try std.testing.expectError(error.Cancelled, reg.register(tok));
}

fn waitForFlagTrue(flag: *const std.atomic.Value(bool), iterations_max: u32) bool {
    var iterations: u32 = 0;
    while (iterations < iterations_max) : (iterations += 1) {
        if (flag.load(.acquire)) return true;
        std.Thread.yield() catch {};
    }
    return false;
}
