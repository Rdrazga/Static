//! SPSC queue throughput benchmark.
//!
//! Measures bounded send/receive throughput using the shared benchmark
//! workflow and retained baseline artifacts.

const std = @import("std");
const assert = std.debug.assert;
const static_queues = @import("static_queues");
const static_testing = @import("static_testing");
const support = @import("support.zig");

const bench = static_testing.bench;
const bench_config = support.default_benchmark_config;
const batch_count: usize = 1024;

const SpscQueue = static_queues.spsc.SpscQueue(u64);

const SpscContext = struct {
    queue: *SpscQueue,
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *SpscContext = @ptrCast(@alignCast(context_ptr));
        assert(context.queue.capacity() == batch_count);
        assert(context.queue.isEmpty());

        var index: usize = 0;
        while (index < batch_count) : (index += 1) {
            const value = bench.case.blackBox(@as(u64, @intCast(index)));
            context.queue.trySend(value) catch unreachable;
        }

        index = 0;
        while (index < batch_count) : (index += 1) {
            const item = context.queue.tryRecv() catch unreachable;
            context.sink = bench.case.blackBox(context.sink + item);
        }

        assert(context.queue.isEmpty());
        assert(context.sink > 0);
    }
};

pub fn main() !void {
    try validateSemanticPreflight(std.heap.page_allocator);

    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    var output_dir = try support.openOutputDir(io, "spsc_throughput");
    defer output_dir.close(io);

    var q = try SpscQueue.init(std.heap.page_allocator, .{ .capacity = batch_count });
    defer q.deinit();

    var context = SpscContext{ .queue = &q };
    var case_storage: [1]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_queues_spsc_throughput",
        .config = bench_config,
    });
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "send_recv_batch",
        .tags = &[_][]const u8{ "static_queues", "spsc", "baseline" },
        .context = &context,
        .run_fn = SpscContext.run,
    }));

    var sample_storage: [bench_config.sample_count]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [1]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(
        &group,
        &sample_storage,
        &case_result_storage,
    );

    try support.writeSingleCaseReport(
        "spsc_throughput",
        run_result,
        io,
        output_dir,
        support.default_environment_note,
    );
}

fn validateSemanticPreflight(allocator: std.mem.Allocator) !void {
    var q = try SpscQueue.init(allocator, .{ .capacity = batch_count });
    defer q.deinit();

    assert(q.capacity() == batch_count);
    assert(q.isEmpty());

    var index: usize = 0;
    while (index < batch_count) : (index += 1) {
        try q.trySend(@as(u64, @intCast(index)));
    }
    assert(q.isFull());
    index = 0;
    while (index < batch_count) : (index += 1) {
        _ = try q.tryRecv();
    }
    assert(q.isEmpty());
}
