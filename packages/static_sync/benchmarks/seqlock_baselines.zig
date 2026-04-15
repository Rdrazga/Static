//! `static_sync` seqlock benchmarks.
//!
//! Scope:
//! - isolated stable read-begin and read-retry costs;
//! - isolated writer lock/unlock cost;
//! - combined writer progression plus readback continuity; and
//! - mixed read token invalidation after one write cycle.

const std = @import("std");
const assert = std.debug.assert;
const static_sync = @import("static_sync");
const support = @import("support.zig");

const bench = support.bench;
const bench_config = support.fast_path_benchmark_config;
const benchmark_name = "seqlock_baselines";

const read_begin_tags = &[_][]const u8{
    "static_sync",
    "seqlock",
    "read_heavy",
    "read_begin_only",
    "baseline",
};
const read_retry_tags = &[_][]const u8{
    "static_sync",
    "seqlock",
    "read_heavy",
    "read_retry_only",
    "baseline",
};
const stable_read_tags = &[_][]const u8{
    "static_sync",
    "seqlock",
    "read_heavy",
    "stable_begin_retry",
    "baseline",
};
const write_lock_unlock_tags = &[_][]const u8{
    "static_sync",
    "seqlock",
    "write_heavy",
    "lock_unlock_only",
    "baseline",
};
const write_cycle_tags = &[_][]const u8{
    "static_sync",
    "seqlock",
    "write_heavy",
    "write_cycle",
    "baseline",
};
const token_invalidation_tags = &[_][]const u8{
    "static_sync",
    "seqlock",
    "mixed",
    "token_invalidation",
    "baseline",
};

const ReadBeginContext = struct {
    lock: static_sync.seqlock.SeqLock = .{},
    sink: u64 = 0,

    fn prepare(context_ptr: *anyopaque, _: bench.case.BenchmarkRunPhase, _: u32) void {
        const context: *ReadBeginContext = @ptrCast(@alignCast(context_ptr));
        context.lock = .{};
    }

    fn run(context_ptr: *anyopaque) void {
        const context: *ReadBeginContext = @ptrCast(@alignCast(context_ptr));
        const token = context.lock.readBegin();
        assert((token & 1) == 0);
        context.sink +%= bench.case.blackBox(token);
    }
};

const ReadRetryContext = struct {
    lock: static_sync.seqlock.SeqLock = .{},
    token: u64 = 0,
    sink: u64 = 0,

    fn reset(self: *@This()) void {
        self.lock = .{};
        self.token = self.lock.readBegin();
        assert(!self.lock.readRetry(self.token));
    }

    fn prepare(context_ptr: *anyopaque, _: bench.case.BenchmarkRunPhase, _: u32) void {
        const context: *ReadRetryContext = @ptrCast(@alignCast(context_ptr));
        context.reset();
    }

    fn run(context_ptr: *anyopaque) void {
        const context: *ReadRetryContext = @ptrCast(@alignCast(context_ptr));
        const should_retry = context.lock.readRetry(context.token);
        assert(!should_retry);
        context.sink +%= bench.case.blackBox(@as(u64, @intFromBool(should_retry)));
    }
};

const StableReadContext = struct {
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *StableReadContext = @ptrCast(@alignCast(context_ptr));
        var lock = static_sync.seqlock.SeqLock{};
        const token = lock.readBegin();
        assert(!lock.readRetry(token));
        context.sink +%= bench.case.blackBox(token);
    }
};

const WriteLockUnlockContext = struct {
    lock: static_sync.seqlock.SeqLock = .{},
    sink: u64 = 0,

    fn prepare(context_ptr: *anyopaque, _: bench.case.BenchmarkRunPhase, _: u32) void {
        const context: *WriteLockUnlockContext = @ptrCast(@alignCast(context_ptr));
        context.lock = .{};
    }

    fn run(context_ptr: *anyopaque) void {
        const context: *WriteLockUnlockContext = @ptrCast(@alignCast(context_ptr));
        context.lock.writeLock();
        context.lock.writeUnlock();
        assert(context.lock.seq.load(.acquire) == 2);
        context.sink +%= bench.case.blackBox(context.lock.seq.load(.acquire));
    }
};

const WriteCycleContext = struct {
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *WriteCycleContext = @ptrCast(@alignCast(context_ptr));
        var lock = static_sync.seqlock.SeqLock{};
        lock.writeLock();
        lock.writeUnlock();
        const token = lock.readBegin();
        assert(!lock.readRetry(token));
        assert(token == 2);
        context.sink +%= bench.case.blackBox(token);
    }
};

const TokenInvalidationContext = struct {
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *TokenInvalidationContext = @ptrCast(@alignCast(context_ptr));
        var lock = static_sync.seqlock.SeqLock{};
        const before = lock.readBegin();
        lock.writeLock();
        lock.writeUnlock();
        assert(lock.readRetry(before));
        const after = lock.readBegin();
        assert(!lock.readRetry(after));
        assert(after == before + 2);
        context.sink +%= bench.case.blackBox(after);
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

    var read_begin_context = ReadBeginContext{};
    var read_retry_context = ReadRetryContext{};
    var stable_read_context = StableReadContext{};
    var write_lock_unlock_context = WriteLockUnlockContext{};
    var write_cycle_context = WriteCycleContext{};
    var token_invalidation_context = TokenInvalidationContext{};

    var case_storage: [6]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_sync_seqlock_baselines",
        .config = bench_config,
    });
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "seqlock_read_begin_only_stable",
        .tags = read_begin_tags,
        .context = &read_begin_context,
        .run_fn = ReadBeginContext.run,
        .prepare_context = &read_begin_context,
        .prepare_fn = ReadBeginContext.prepare,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "seqlock_read_retry_only_stable",
        .tags = read_retry_tags,
        .context = &read_retry_context,
        .run_fn = ReadRetryContext.run,
        .prepare_context = &read_retry_context,
        .prepare_fn = ReadRetryContext.prepare,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "seqlock_read_begin_retry_stable",
        .tags = stable_read_tags,
        .context = &stable_read_context,
        .run_fn = StableReadContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "seqlock_write_lock_unlock_only",
        .tags = write_lock_unlock_tags,
        .context = &write_lock_unlock_context,
        .run_fn = WriteLockUnlockContext.run,
        .prepare_context = &write_lock_unlock_context,
        .prepare_fn = WriteLockUnlockContext.prepare,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "seqlock_write_cycle",
        .tags = write_cycle_tags,
        .context = &write_cycle_context,
        .run_fn = WriteCycleContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "seqlock_write_invalidates_old_token",
        .tags = token_invalidation_tags,
        .context = &token_invalidation_context,
        .run_fn = TokenInvalidationContext.run,
    }));

    var sample_storage: [6 * bench_config.sample_count]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [6]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(
        &group,
        &sample_storage,
        &case_result_storage,
    );

    try support.writeGroupReport(
        6,
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
    var read_begin_context = ReadBeginContext{};
    ReadBeginContext.prepare(&read_begin_context, .measure, 0);
    ReadBeginContext.run(&read_begin_context);
    assert(read_begin_context.sink == 0);

    var read_retry_context = ReadRetryContext{};
    read_retry_context.reset();
    ReadRetryContext.run(&read_retry_context);
    assert(read_retry_context.sink == 0);

    var stable_read_context = StableReadContext{};
    StableReadContext.run(&stable_read_context);
    assert(stable_read_context.sink == 0);

    var write_lock_unlock_context = WriteLockUnlockContext{};
    WriteLockUnlockContext.prepare(&write_lock_unlock_context, .measure, 0);
    WriteLockUnlockContext.run(&write_lock_unlock_context);
    assert(write_lock_unlock_context.sink == 2);

    var write_cycle_context = WriteCycleContext{};
    WriteCycleContext.run(&write_cycle_context);
    assert(write_cycle_context.sink == 2);

    var token_invalidation_context = TokenInvalidationContext{};
    TokenInvalidationContext.run(&token_invalidation_context);
    assert(token_invalidation_context.sink == 2);
}
