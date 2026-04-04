//! `static_io` buffer-pool bounded churn baseline benchmark.

const std = @import("std");
const static_io = @import("static_io");
const static_testing = @import("static_testing");
const support = @import("support.zig");

const bench = static_testing.bench;

const churn_capacity = 64;

const bench_config = bench.config.BenchmarkConfig{
    .mode = .full,
    .warmup_iterations = 32,
    .measure_iterations = 131_072,
    .sample_count = 16,
};

const BufferPoolChurnContext = struct {
    pool: *static_io.BufferPool,
    scratch: [churn_capacity]static_io.Buffer = undefined,
    sink: usize = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *BufferPoolChurnContext = @ptrCast(@alignCast(context_ptr));
        std.debug.assert(context.pool.capacity() == churn_capacity);
        std.debug.assert(context.pool.available() == context.pool.capacity());

        var total_bytes: usize = 0;
        for (&context.scratch, 0..) |*buffer, index| {
            buffer.* = context.pool.acquire() catch unreachable;
            std.debug.assert(buffer.*.capacity() != 0);
            total_bytes += buffer.bytes.len + index;
        }
        std.debug.assert(context.pool.available() == 0);

        var release_index = context.scratch.len;
        while (release_index != 0) {
            release_index -= 1;
            context.pool.release(context.scratch[release_index]) catch unreachable;
        }
        std.debug.assert(context.pool.available() == context.pool.capacity());
        context.sink = bench.case.blackBox(total_bytes);
        std.debug.assert(context.sink >= @as(usize, context.pool.capacity()));
    }
};

pub fn main() !void {
    validateSemanticPreflight();

    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    var output_dir = try support.openOutputDir(io, "buffer_pool_bounded_churn");
    defer output_dir.close(io);

    var pool = try static_io.BufferPool.init(std.heap.page_allocator, .{
        .buffer_size = 256,
        .capacity = churn_capacity,
    });
    defer pool.deinit();

    var context = BufferPoolChurnContext{ .pool = &pool };
    var case_storage: [1]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_io_buffer_pool_bounded_churn",
        .config = bench_config,
    });
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "bounded_churn_cycle",
        .tags = &[_][]const u8{ "static_io", "buffer_pool", "churn" },
        .context = &context,
        .run_fn = BufferPoolChurnContext.run,
    }));

    var sample_storage: [bench_config.sample_count]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [1]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(
        &group,
        &sample_storage,
        &case_result_storage,
    );

    std.debug.print("== static_io buffer pool bounded churn ==\n", .{});
    try support.writeSingleCaseReport(
        run_result,
        io,
        output_dir,
        "buffer pool full-capacity acquire/release churn cycle",
    );
}

fn validateSemanticPreflight() void {
    var pool = static_io.BufferPool.init(std.heap.page_allocator, .{
        .buffer_size = 32,
        .capacity = 4,
    }) catch unreachable;
    defer pool.deinit();

    var scratch: [4]static_io.Buffer = undefined;
    for (&scratch) |*buffer| {
        buffer.* = pool.acquire() catch unreachable;
    }
    std.debug.assert(pool.available() == 0);
    for (scratch) |buffer| {
        pool.release(buffer) catch unreachable;
    }
    std.debug.assert(pool.available() == pool.capacity());
}
