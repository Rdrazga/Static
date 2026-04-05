//! Disruptor publish/consume throughput benchmark.
//!
//! Measures bounded publish/consume throughput using the shared benchmark
//! workflow and retained baseline artifacts.

const std = @import("std");
const assert = std.debug.assert;
const static_queues = @import("static_queues");
const static_testing = @import("static_testing");
const support = @import("support.zig");

const bench = static_testing.bench;
const bench_config = support.default_benchmark_config;
const batch_count: usize = 1024;

const Disruptor = static_queues.disruptor.Disruptor(u64);

const DisruptorContext = struct {
    queue: *Disruptor,
    consumer_id: Disruptor.ConsumerId,
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *DisruptorContext = @ptrCast(@alignCast(context_ptr));
        assert(context.queue.capacity() == batch_count);
        assert(context.queue.activeConsumerCount() == 1);
        assert(context.queue.pending(context.consumer_id) == 0);

        var index: usize = 0;
        while (index < batch_count) : (index += 1) {
            const value = bench.case.blackBox(@as(u64, @intCast(index)));
            context.queue.trySend(value) catch unreachable;
        }

        index = 0;
        while (index < batch_count) : (index += 1) {
            const item = context.queue.tryRecv(context.consumer_id) catch unreachable;
            context.sink = bench.case.blackBox(context.sink + item);
        }

        assert(context.queue.pending(context.consumer_id) == 0);
        assert(context.queue.activeConsumerCount() == 1);
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
    var output_dir = try support.openOutputDir(io, "disruptor_throughput");
    defer output_dir.close(io);

    var disruptor = try Disruptor.init(std.heap.page_allocator, .{
        .capacity = batch_count,
        .consumers_max = 1,
    });
    defer disruptor.deinit();

    const consumer_id = try disruptor.addConsumer();
    defer disruptor.removeConsumer(consumer_id);

    var context = DisruptorContext{ .queue = &disruptor, .consumer_id = consumer_id };
    var case_storage: [1]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_queues_disruptor_throughput",
        .config = bench_config,
    });
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "publish_consume_batch",
        .tags = &[_][]const u8{ "static_queues", "disruptor", "baseline" },
        .context = &context,
        .run_fn = DisruptorContext.run,
    }));

    var sample_storage: [bench_config.sample_count]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [1]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(
        &group,
        &sample_storage,
        &case_result_storage,
    );

    try support.writeSingleCaseReport(
        "disruptor_throughput",
        run_result,
        io,
        output_dir,
        support.default_environment_note,
    );
}

fn validateSemanticPreflight(allocator: std.mem.Allocator) !void {
    var disruptor = try Disruptor.init(allocator, .{
        .capacity = batch_count,
        .consumers_max = 1,
    });
    defer disruptor.deinit();

    const consumer_id = try disruptor.addConsumer();
    defer disruptor.removeConsumer(consumer_id);

    assert(disruptor.capacity() == batch_count);
    assert(disruptor.activeConsumerCount() == 1);
    assert(disruptor.pending(consumer_id) == 0);

    var index: usize = 0;
    while (index < batch_count) : (index += 1) {
        try disruptor.trySend(@as(u64, @intCast(index)));
    }
    index = 0;
    while (index < batch_count) : (index += 1) {
        _ = try disruptor.tryRecv(consumer_id);
    }
    assert(disruptor.pending(consumer_id) == 0);
}
