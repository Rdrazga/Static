//! RingBuffer push/pop throughput benchmark.
//!
//! Measures bounded push/pop throughput on the single-threaded ring buffer
//! using the shared benchmark workflow and retained baseline artifacts.

const std = @import("std");
const assert = std.debug.assert;
const static_queues = @import("static_queues");
const static_testing = @import("static_testing");
const support = @import("support.zig");

const bench = static_testing.bench;
const bench_config = support.default_benchmark_config;
const batch_count: usize = 1024;

const RingBuffer = static_queues.ring_buffer.RingBuffer(u64);

const RingBufferContext = struct {
    queue: *RingBuffer,
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *RingBufferContext = @ptrCast(@alignCast(context_ptr));
        assert(context.queue.capacity() == batch_count);
        assert(context.queue.isEmpty());

        var index: usize = 0;
        while (index < batch_count) : (index += 1) {
            const value = bench.case.blackBox(@as(u64, @intCast(index)));
            context.queue.tryPush(value) catch unreachable;
        }

        index = 0;
        while (index < batch_count) : (index += 1) {
            const item = context.queue.tryPop() catch unreachable;
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
    var output_dir = try support.openOutputDir(io, "ring_buffer_throughput");
    defer output_dir.close(io);

    var rb = try RingBuffer.init(std.heap.page_allocator, .{ .capacity = batch_count });
    defer rb.deinit();

    var context = RingBufferContext{ .queue = &rb };
    var case_storage: [1]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_queues_ring_buffer_throughput",
        .config = bench_config,
    });
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "push_pop_batch",
        .tags = &[_][]const u8{ "static_queues", "ring_buffer", "baseline" },
        .context = &context,
        .run_fn = RingBufferContext.run,
    }));

    var sample_storage: [bench_config.sample_count]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [1]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(
        &group,
        &sample_storage,
        &case_result_storage,
    );

    try support.writeSingleCaseReport(
        "ring_buffer_throughput",
        run_result,
        io,
        output_dir,
        support.default_environment_note,
    );
}

fn validateSemanticPreflight(allocator: std.mem.Allocator) !void {
    var rb = try RingBuffer.init(allocator, .{ .capacity = batch_count });
    defer rb.deinit();

    assert(rb.capacity() == batch_count);
    assert(rb.isEmpty());

    var index: usize = 0;
    while (index < batch_count) : (index += 1) {
        try rb.tryPush(@as(u64, @intCast(index)));
    }
    assert(rb.isFull());
    index = 0;
    while (index < batch_count) : (index += 1) {
        _ = try rb.tryPop();
    }
    assert(rb.isEmpty());
}
