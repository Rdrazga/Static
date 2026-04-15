//! `static_sync` cancel lifecycle benchmarks.
//!
//! Scope:
//! - register/unregister steady-state lifecycle;
//! - isolated register, cancel-fanout, and unregister-after-fire attribution;
//! - isolated single-registration cancel, reset-only, and post-reset
//!   re-registration attribution;
//! - end-to-end small-fanout lifecycle continuity; and
//! - cancel plus reset cycles that restore re-registration.

const std = @import("std");
const assert = std.debug.assert;
const static_sync = @import("static_sync");
const support = @import("support.zig");

const bench = support.bench;
const bench_config = support.fast_path_benchmark_config;
const benchmark_name = "cancel_lifecycle_baselines";

const registration_count: usize = 4;

const register_unregister_tags = &[_][]const u8{
    "static_sync",
    "cancel",
    "lifecycle",
    "register_unregister",
    "baseline",
};
const cancel_register_only_tags = &[_][]const u8{
    "static_sync",
    "cancel",
    "register",
    "isolated",
    "baseline",
};
const cancel_fanout_only_tags = &[_][]const u8{
    "static_sync",
    "cancel",
    "fanout",
    "isolated",
    "baseline",
};
const cancel_unregister_after_fire_tags = &[_][]const u8{
    "static_sync",
    "cancel",
    "unregister",
    "after_fire",
    "baseline",
};
const cancel_fanout_tags = &[_][]const u8{
    "static_sync",
    "cancel",
    "fanout",
    "baseline",
};
const cancel_single_registered_tags = &[_][]const u8{
    "static_sync",
    "cancel",
    "single_registered",
    "isolated",
    "baseline",
};
const cancel_reset_only_tags = &[_][]const u8{
    "static_sync",
    "cancel",
    "reset",
    "only",
    "baseline",
};
const cancel_reregister_after_reset_tags = &[_][]const u8{
    "static_sync",
    "cancel",
    "reregister",
    "after_reset",
    "baseline",
};
const cancel_reset_tags = &[_][]const u8{
    "static_sync",
    "cancel",
    "reset",
    "baseline",
};

const CounterContext = struct {
    counter: *std.atomic.Value(u32),

    fn wake(self: *@This()) void {
        _ = self.counter.fetchAdd(1, .acq_rel);
    }
};

fn idleRegistration() static_sync.cancel.CancelRegistration {
    return static_sync.cancel.CancelRegistration.init(counterWake, null);
}

const RegisterUnregisterContext = struct {
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *RegisterUnregisterContext = @ptrCast(@alignCast(context_ptr));

        var source = static_sync.cancel.CancelSource{};
        const token = source.token();
        var counter = std.atomic.Value(u32).init(0);
        var wake_context = CounterContext{ .counter = &counter };
        var registration = static_sync.cancel.CancelRegistration.init(counterWake, &wake_context);

        registration.register(token) catch unreachable;
        registration.unregister();

        assert(counter.load(.acquire) == 0);
        assert(!token.isCancelled());
        context.sink +%= bench.case.blackBox(@as(u64, @intFromBool(token.isCancelled())));
    }
};

const CancelRegisterOnlyContext = struct {
    source: static_sync.cancel.CancelSource = .{},
    counters: [registration_count]std.atomic.Value(u32) = [_]std.atomic.Value(u32){
        std.atomic.Value(u32).init(0),
    } ** registration_count,
    wake_contexts: [registration_count]CounterContext = undefined,
    registrations: [registration_count]static_sync.cancel.CancelRegistration =
        [_]static_sync.cancel.CancelRegistration{idleRegistration()} ** registration_count,
    sink: u64 = 0,

    fn reset(self: *@This()) void {
        inline for (0..registration_count) |index| {
            self.registrations[index].unregister();
        }
        if (self.source.token().isCancelled()) self.source.reset();
        inline for (0..registration_count) |index| {
            self.counters[index].store(0, .release);
            self.wake_contexts[index] = .{ .counter = &self.counters[index] };
            self.registrations[index] = static_sync.cancel.CancelRegistration.init(
                counterWake,
                &self.wake_contexts[index],
            );
        }
    }

    fn prepare(context_ptr: *anyopaque, _: bench.case.BenchmarkRunPhase, _: u32) void {
        const context: *CancelRegisterOnlyContext = @ptrCast(@alignCast(context_ptr));
        context.reset();
    }

    fn run(context_ptr: *anyopaque) void {
        const context: *CancelRegisterOnlyContext = @ptrCast(@alignCast(context_ptr));
        const token = context.source.token();
        var registered_count: u32 = 0;
        inline for (0..registration_count) |index| {
            context.registrations[index].register(token) catch unreachable;
            assert(context.registrations[index].slot_index == index);
            registered_count += 1;
        }
        assert(!token.isCancelled());
        context.sink +%= bench.case.blackBox(@as(u64, registered_count));
    }
};

const CancelFanoutOnlyContext = struct {
    source: static_sync.cancel.CancelSource = .{},
    counters: [registration_count]std.atomic.Value(u32) = [_]std.atomic.Value(u32){
        std.atomic.Value(u32).init(0),
    } ** registration_count,
    wake_contexts: [registration_count]CounterContext = undefined,
    registrations: [registration_count]static_sync.cancel.CancelRegistration =
        [_]static_sync.cancel.CancelRegistration{idleRegistration()} ** registration_count,
    sink: u64 = 0,

    fn reset(self: *@This()) void {
        inline for (0..registration_count) |index| {
            self.registrations[index].unregister();
        }
        if (self.source.token().isCancelled()) self.source.reset();
        inline for (0..registration_count) |index| {
            self.counters[index].store(0, .release);
            self.wake_contexts[index] = .{ .counter = &self.counters[index] };
            self.registrations[index] = static_sync.cancel.CancelRegistration.init(
                counterWake,
                &self.wake_contexts[index],
            );
        }
        const token = self.source.token();
        inline for (0..registration_count) |index| {
            self.registrations[index].register(token) catch unreachable;
        }
    }

    fn prepare(context_ptr: *anyopaque, _: bench.case.BenchmarkRunPhase, _: u32) void {
        const context: *CancelFanoutOnlyContext = @ptrCast(@alignCast(context_ptr));
        context.reset();
    }

    fn run(context_ptr: *anyopaque) void {
        const context: *CancelFanoutOnlyContext = @ptrCast(@alignCast(context_ptr));
        context.source.cancel();

        var total_callbacks: u32 = 0;
        inline for (0..registration_count) |index| {
            total_callbacks += context.counters[index].load(.acquire);
        }

        assert(context.source.token().isCancelled());
        assert(total_callbacks == registration_count);
        context.sink +%= bench.case.blackBox(@as(u64, total_callbacks));
    }
};

const CancelUnregisterAfterFireContext = struct {
    source: static_sync.cancel.CancelSource = .{},
    counters: [registration_count]std.atomic.Value(u32) = [_]std.atomic.Value(u32){
        std.atomic.Value(u32).init(0),
    } ** registration_count,
    wake_contexts: [registration_count]CounterContext = undefined,
    registrations: [registration_count]static_sync.cancel.CancelRegistration =
        [_]static_sync.cancel.CancelRegistration{idleRegistration()} ** registration_count,
    sink: u64 = 0,

    fn reset(self: *@This()) void {
        inline for (0..registration_count) |index| {
            self.registrations[index].unregister();
        }
        if (self.source.token().isCancelled()) self.source.reset();
        inline for (0..registration_count) |index| {
            self.counters[index].store(0, .release);
            self.wake_contexts[index] = .{ .counter = &self.counters[index] };
            self.registrations[index] = static_sync.cancel.CancelRegistration.init(
                counterWake,
                &self.wake_contexts[index],
            );
        }
        const token = self.source.token();
        inline for (0..registration_count) |index| {
            self.registrations[index].register(token) catch unreachable;
        }
        self.source.cancel();
        assert(token.isCancelled());
    }

    fn prepare(context_ptr: *anyopaque, _: bench.case.BenchmarkRunPhase, _: u32) void {
        const context: *CancelUnregisterAfterFireContext = @ptrCast(@alignCast(context_ptr));
        context.reset();
    }

    fn run(context_ptr: *anyopaque) void {
        const context: *CancelUnregisterAfterFireContext = @ptrCast(@alignCast(context_ptr));
        var cleared_count: u32 = 0;
        inline for (0..registration_count) |index| {
            context.registrations[index].unregister();
            assert(context.registrations[index].state == null);
            assert(context.registrations[index].slot_index == std.math.maxInt(u32));
            cleared_count += 1;
        }
        assert(cleared_count == registration_count);
        context.sink +%= bench.case.blackBox(@as(u64, cleared_count));
    }
};

const CancelFanoutContext = struct {
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *CancelFanoutContext = @ptrCast(@alignCast(context_ptr));

        var source = static_sync.cancel.CancelSource{};
        const token = source.token();
        var counters = [_]std.atomic.Value(u32){
            std.atomic.Value(u32).init(0),
        } ** registration_count;
        var wake_contexts: [registration_count]CounterContext = undefined;
        var registrations: [registration_count]static_sync.cancel.CancelRegistration = undefined;

        inline for (0..registration_count) |index| {
            wake_contexts[index] = .{ .counter = &counters[index] };
            registrations[index] = static_sync.cancel.CancelRegistration.init(
                counterWake,
                &wake_contexts[index],
            );
            registrations[index].register(token) catch unreachable;
        }

        source.cancel();

        var total_callbacks: u32 = 0;
        inline for (0..registration_count) |index| {
            total_callbacks += counters[index].load(.acquire);
            registrations[index].unregister();
        }

        assert(token.isCancelled());
        assert(total_callbacks == registration_count);
        context.sink +%= bench.case.blackBox(@as(u64, total_callbacks));
    }
};

const CancelSingleRegisteredContext = struct {
    source: static_sync.cancel.CancelSource = .{},
    counter: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    wake_context: CounterContext = undefined,
    registration: static_sync.cancel.CancelRegistration = idleRegistration(),
    sink: u64 = 0,

    fn reset(self: *@This()) void {
        self.registration.unregister();
        if (self.source.token().isCancelled()) self.source.reset();
        self.counter.store(0, .release);
        self.wake_context = .{ .counter = &self.counter };
        self.registration = static_sync.cancel.CancelRegistration.init(counterWake, &self.wake_context);
        self.registration.register(self.source.token()) catch unreachable;
        assert(self.counter.load(.acquire) == 0);
        assert(!self.source.token().isCancelled());
    }

    fn prepare(context_ptr: *anyopaque, _: bench.case.BenchmarkRunPhase, _: u32) void {
        const context: *CancelSingleRegisteredContext = @ptrCast(@alignCast(context_ptr));
        context.reset();
    }

    fn run(context_ptr: *anyopaque) void {
        const context: *CancelSingleRegisteredContext = @ptrCast(@alignCast(context_ptr));
        context.source.cancel();
        assert(context.source.token().isCancelled());
        assert(context.counter.load(.acquire) == 1);
        context.sink +%= bench.case.blackBox(@as(u64, context.counter.load(.acquire)));
    }
};

const CancelResetOnlyContext = struct {
    source: static_sync.cancel.CancelSource = .{},
    sink: u64 = 0,

    fn reset(self: *@This()) void {
        if (self.source.token().isCancelled()) self.source.reset();
        self.source.cancel();
        assert(self.source.token().isCancelled());
    }

    fn prepare(context_ptr: *anyopaque, _: bench.case.BenchmarkRunPhase, _: u32) void {
        const context: *CancelResetOnlyContext = @ptrCast(@alignCast(context_ptr));
        context.reset();
    }

    fn run(context_ptr: *anyopaque) void {
        const context: *CancelResetOnlyContext = @ptrCast(@alignCast(context_ptr));
        context.source.reset();
        assert(!context.source.token().isCancelled());
        context.sink +%= bench.case.blackBox(@as(u64, @intFromBool(!context.source.token().isCancelled())));
    }
};

const CancelReregisterAfterResetContext = struct {
    source: static_sync.cancel.CancelSource = .{},
    counter: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    wake_context: CounterContext = undefined,
    registration: static_sync.cancel.CancelRegistration = idleRegistration(),
    sink: u64 = 0,

    fn reset(self: *@This()) void {
        self.registration.unregister();
        if (self.source.token().isCancelled()) self.source.reset();
        self.source.cancel();
        self.source.reset();
        self.counter.store(0, .release);
        self.wake_context = .{ .counter = &self.counter };
        self.registration = static_sync.cancel.CancelRegistration.init(counterWake, &self.wake_context);
        assert(!self.source.token().isCancelled());
    }

    fn prepare(context_ptr: *anyopaque, _: bench.case.BenchmarkRunPhase, _: u32) void {
        const context: *CancelReregisterAfterResetContext = @ptrCast(@alignCast(context_ptr));
        context.reset();
    }

    fn run(context_ptr: *anyopaque) void {
        const context: *CancelReregisterAfterResetContext = @ptrCast(@alignCast(context_ptr));
        const token = context.source.token();
        context.registration.register(token) catch unreachable;
        context.registration.unregister();
        assert(!token.isCancelled());
        assert(context.counter.load(.acquire) == 0);
        context.sink +%= bench.case.blackBox(@as(u64, @intFromBool(!token.isCancelled())));
    }
};

const CancelResetContext = struct {
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *CancelResetContext = @ptrCast(@alignCast(context_ptr));

        var source = static_sync.cancel.CancelSource{};
        var token = source.token();
        var counter = std.atomic.Value(u32).init(0);
        var wake_context = CounterContext{ .counter = &counter };
        var registration = static_sync.cancel.CancelRegistration.init(counterWake, &wake_context);

        registration.register(token) catch unreachable;
        source.cancel();
        registration.unregister();
        assert(counter.load(.acquire) == 1);
        assert(token.isCancelled());

        source.reset();
        token = source.token();
        registration.register(token) catch unreachable;
        registration.unregister();

        assert(!token.isCancelled());
        assert(counter.load(.acquire) == 1);
        context.sink +%= bench.case.blackBox(@as(u64, counter.load(.acquire)));
    }
};

pub fn main() !void {
    validateSemanticPreflight();

    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    var output_dir = try support.openOutputDir(io, benchmark_name);
    defer output_dir.close(io);

    var register_unregister = RegisterUnregisterContext{};
    var cancel_register_only = CancelRegisterOnlyContext{};
    var cancel_fanout_only = CancelFanoutOnlyContext{};
    var cancel_unregister_after_fire = CancelUnregisterAfterFireContext{};
    var cancel_fanout = CancelFanoutContext{};
    var cancel_single_registered = CancelSingleRegisteredContext{};
    var cancel_reset_only = CancelResetOnlyContext{};
    var cancel_reregister_after_reset = CancelReregisterAfterResetContext{};
    var cancel_reset = CancelResetContext{};

    var case_storage: [9]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_sync_cancel_lifecycle_baselines",
        .config = bench_config,
    });
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "register_unregister_cycle",
        .tags = register_unregister_tags,
        .context = &register_unregister,
        .run_fn = RegisterUnregisterContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "cancel_register_4",
        .tags = cancel_register_only_tags,
        .context = &cancel_register_only,
        .run_fn = CancelRegisterOnlyContext.run,
        .prepare_context = &cancel_register_only,
        .prepare_fn = CancelRegisterOnlyContext.prepare,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "cancel_fanout_only_4",
        .tags = cancel_fanout_only_tags,
        .context = &cancel_fanout_only,
        .run_fn = CancelFanoutOnlyContext.run,
        .prepare_context = &cancel_fanout_only,
        .prepare_fn = CancelFanoutOnlyContext.prepare,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "cancel_unregister_4_after_fire",
        .tags = cancel_unregister_after_fire_tags,
        .context = &cancel_unregister_after_fire,
        .run_fn = CancelUnregisterAfterFireContext.run,
        .prepare_context = &cancel_unregister_after_fire,
        .prepare_fn = CancelUnregisterAfterFireContext.prepare,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "cancel_fanout_4",
        .tags = cancel_fanout_tags,
        .context = &cancel_fanout,
        .run_fn = CancelFanoutContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "cancel_single_registered",
        .tags = cancel_single_registered_tags,
        .context = &cancel_single_registered,
        .run_fn = CancelSingleRegisteredContext.run,
        .prepare_context = &cancel_single_registered,
        .prepare_fn = CancelSingleRegisteredContext.prepare,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "cancel_reset_only",
        .tags = cancel_reset_only_tags,
        .context = &cancel_reset_only,
        .run_fn = CancelResetOnlyContext.run,
        .prepare_context = &cancel_reset_only,
        .prepare_fn = CancelResetOnlyContext.prepare,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "cancel_reregister_after_reset",
        .tags = cancel_reregister_after_reset_tags,
        .context = &cancel_reregister_after_reset,
        .run_fn = CancelReregisterAfterResetContext.run,
        .prepare_context = &cancel_reregister_after_reset,
        .prepare_fn = CancelReregisterAfterResetContext.prepare,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "cancel_reset_reregister_cycle",
        .tags = cancel_reset_tags,
        .context = &cancel_reset,
        .run_fn = CancelResetContext.run,
    }));

    var sample_storage: [9 * bench_config.sample_count]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [9]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(
        &group,
        &sample_storage,
        &case_result_storage,
    );

    try support.writeGroupReport(
        9,
        benchmark_name,
        run_result,
        io,
        output_dir,
        support.fast_path_compare_config,
        .{
            .environment_note = support.default_environment_note,
            .environment_tags = support.fast_path_environment_tags,
        },
    );
}

fn validateSemanticPreflight() void {
    var register_unregister = RegisterUnregisterContext{};
    RegisterUnregisterContext.run(&register_unregister);
    assert(register_unregister.sink == 0);

    var cancel_register_only = CancelRegisterOnlyContext{};
    cancel_register_only.reset();
    CancelRegisterOnlyContext.run(&cancel_register_only);
    assert(cancel_register_only.sink == registration_count);

    var cancel_fanout_only = CancelFanoutOnlyContext{};
    cancel_fanout_only.reset();
    CancelFanoutOnlyContext.run(&cancel_fanout_only);
    assert(cancel_fanout_only.sink == registration_count);

    var cancel_unregister_after_fire = CancelUnregisterAfterFireContext{};
    cancel_unregister_after_fire.reset();
    CancelUnregisterAfterFireContext.run(&cancel_unregister_after_fire);
    assert(cancel_unregister_after_fire.sink == registration_count);

    var cancel_fanout = CancelFanoutContext{};
    CancelFanoutContext.run(&cancel_fanout);
    assert(cancel_fanout.sink == registration_count);

    var cancel_single_registered = CancelSingleRegisteredContext{};
    cancel_single_registered.reset();
    CancelSingleRegisteredContext.run(&cancel_single_registered);
    assert(cancel_single_registered.sink == 1);

    var cancel_reset_only = CancelResetOnlyContext{};
    cancel_reset_only.reset();
    CancelResetOnlyContext.run(&cancel_reset_only);
    assert(cancel_reset_only.sink == 1);

    var cancel_reregister_after_reset = CancelReregisterAfterResetContext{};
    cancel_reregister_after_reset.reset();
    CancelReregisterAfterResetContext.run(&cancel_reregister_after_reset);
    assert(cancel_reregister_after_reset.sink == 1);

    var cancel_reset = CancelResetContext{};
    CancelResetContext.run(&cancel_reset);
    assert(cancel_reset.sink == 1);
}

fn counterWake(ctx: ?*anyopaque) void {
    const context: *CounterContext = @ptrCast(@alignCast(ctx.?));
    context.wake();
}
