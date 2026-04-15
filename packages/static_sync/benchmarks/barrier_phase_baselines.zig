//! `static_sync` barrier and latch phase benchmarks.
//!
//! Scope:
//! - one-shot latch open cycles as a phase-setup reference;
//! - isolated non-final and final arrival attribution for cyclic barriers; and
//! - reusable single-threaded phase progression continuity.

const std = @import("std");
const assert = std.debug.assert;
const static_sync = @import("static_sync");
const support = @import("support.zig");

const bench = support.bench;
const bench_config = support.fast_path_benchmark_config;
const benchmark_name = "barrier_phase_baselines";

const latch_tags = &[_][]const u8{
    "static_sync",
    "latch",
    "phase",
    "baseline",
};
const barrier_nonfinal_tags = &[_][]const u8{
    "static_sync",
    "barrier",
    "phase",
    "nonfinal_arrival",
    "baseline",
};
const barrier_final_tags = &[_][]const u8{
    "static_sync",
    "barrier",
    "phase",
    "final_arrival",
    "baseline",
};
const barrier_cycle_tags = &[_][]const u8{
    "static_sync",
    "barrier",
    "phase",
    "cycle",
    "baseline",
};

const parties_count: usize = 4;

const LatchContext = struct {
    fn run(_: *anyopaque) void {
        var latch = static_sync.barrier.Latch.init(parties_count);
        latch.countDown(1);
        latch.countDown(1);
        latch.countDown(1);
        latch.countDown(1);
        latch.tryWait() catch unreachable;
        _ = bench.case.blackBox(latch.remaining());
    }
};

const BarrierNonFinalContext = struct {
    barrier: static_sync.barrier.Barrier = undefined,
    sink: u64 = 0,

    fn reset(self: *@This()) void {
        self.barrier = static_sync.barrier.Barrier.init(parties_count) catch unreachable;
        assert(self.barrier.generationNow() == 0);
    }

    fn prepare(context_ptr: *anyopaque, _: bench.case.BenchmarkRunPhase, _: u32) void {
        const context: *BarrierNonFinalContext = @ptrCast(@alignCast(context_ptr));
        context.reset();
    }

    fn run(context_ptr: *anyopaque) void {
        const context: *BarrierNonFinalContext = @ptrCast(@alignCast(context_ptr));
        const generation_before = context.barrier.generationNow();
        assert(!context.barrier.arrive());
        assert(context.barrier.generationNow() == generation_before);
        context.sink +%= bench.case.blackBox(generation_before + 1);
    }
};

const BarrierFinalContext = struct {
    barrier: static_sync.barrier.Barrier = undefined,
    sink: u64 = 0,

    fn reset(self: *@This()) void {
        self.barrier = static_sync.barrier.Barrier.init(parties_count) catch unreachable;
        assert(!self.barrier.arrive());
        assert(!self.barrier.arrive());
        assert(!self.barrier.arrive());
        assert(self.barrier.generationNow() == 0);
    }

    fn prepare(context_ptr: *anyopaque, _: bench.case.BenchmarkRunPhase, _: u32) void {
        const context: *BarrierFinalContext = @ptrCast(@alignCast(context_ptr));
        context.reset();
    }

    fn run(context_ptr: *anyopaque) void {
        const context: *BarrierFinalContext = @ptrCast(@alignCast(context_ptr));
        const generation_before = context.barrier.generationNow();
        assert(context.barrier.arrive());
        context.barrier.tryWait(generation_before) catch unreachable;
        assert(context.barrier.generationNow() == generation_before + 1);
        context.sink +%= bench.case.blackBox(context.barrier.generationNow());
    }
};

const BarrierCycleContext = struct {
    barrier: static_sync.barrier.Barrier,
    phase_count: u64 = 0,

    fn init() !@This() {
        return .{
            .barrier = try static_sync.barrier.Barrier.init(parties_count),
        };
    }

    fn run(context_ptr: *anyopaque) void {
        const context: *BarrierCycleContext = @ptrCast(@alignCast(context_ptr));
        const generation_before = context.barrier.generationNow();
        assert(!context.barrier.arrive());
        assert(!context.barrier.arrive());
        assert(!context.barrier.arrive());
        assert(context.barrier.arrive());
        context.barrier.tryWait(generation_before) catch unreachable;
        assert(context.barrier.generationNow() == generation_before + 1);
        context.phase_count +%= 1;
        _ = bench.case.blackBox(context.phase_count);
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

    var latch_context = LatchContext{};
    var barrier_nonfinal_context = BarrierNonFinalContext{};
    var barrier_final_context = BarrierFinalContext{};
    var barrier_cycle_context = try BarrierCycleContext.init();

    var case_storage: [4]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_sync_barrier_phase_baselines",
        .config = bench_config,
    });
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "latch_open_cycle_4",
        .tags = latch_tags,
        .context = &latch_context,
        .run_fn = LatchContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "barrier_arrive_nonfinal_4",
        .tags = barrier_nonfinal_tags,
        .context = &barrier_nonfinal_context,
        .run_fn = BarrierNonFinalContext.run,
        .prepare_context = &barrier_nonfinal_context,
        .prepare_fn = BarrierNonFinalContext.prepare,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "barrier_arrive_final_4",
        .tags = barrier_final_tags,
        .context = &barrier_final_context,
        .run_fn = BarrierFinalContext.run,
        .prepare_context = &barrier_final_context,
        .prepare_fn = BarrierFinalContext.prepare,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "barrier_phase_cycle_4",
        .tags = barrier_cycle_tags,
        .context = &barrier_cycle_context,
        .run_fn = BarrierCycleContext.run,
    }));

    var sample_storage: [4 * bench_config.sample_count]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [4]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(
        &group,
        &sample_storage,
        &case_result_storage,
    );

    try support.writeGroupReport(
        4,
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
    var latch_context = LatchContext{};
    LatchContext.run(&latch_context);

    var barrier_nonfinal_context = BarrierNonFinalContext{};
    barrier_nonfinal_context.reset();
    BarrierNonFinalContext.run(&barrier_nonfinal_context);
    assert(barrier_nonfinal_context.sink == 1);

    var barrier_final_context = BarrierFinalContext{};
    barrier_final_context.reset();
    BarrierFinalContext.run(&barrier_final_context);
    assert(barrier_final_context.sink == 1);

    var barrier_cycle_context = BarrierCycleContext.init() catch unreachable;
    BarrierCycleContext.run(&barrier_cycle_context);
    assert(barrier_cycle_context.phase_count == 1);
}
