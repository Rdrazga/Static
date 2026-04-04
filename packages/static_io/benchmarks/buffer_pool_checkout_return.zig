//! `static_io` buffer-pool checkout/return baseline benchmark.

const std = @import("std");
const static_io = @import("static_io");
const static_testing = @import("static_testing");
const support = @import("support.zig");

const bench = static_testing.bench;

const bench_config = bench.config.BenchmarkConfig{
    .mode = .full,
    .warmup_iterations = 64,
    .measure_iterations = 2_097_152,
    .sample_count = 16,
};

const BufferPoolContext = struct {
    pool: *static_io.BufferPool,
    sink: usize = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *BufferPoolContext = @ptrCast(@alignCast(context_ptr));
        std.debug.assert(context.pool.capacity() != 0);

        const buffer = context.pool.acquire() catch unreachable;
        context.pool.release(buffer) catch unreachable;
        context.sink = bench.case.blackBox(buffer.bytes.len);
        std.debug.assert(context.sink != 0);
    }
};

pub fn main() !void {
    validateSemanticPreflight();

    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    var output_dir = try support.openOutputDir(io, "buffer_pool_checkout_return");
    defer output_dir.close(io);

    var pool = try static_io.BufferPool.init(std.heap.page_allocator, .{
        .buffer_size = 256,
        .capacity = 1024,
    });
    defer pool.deinit();

    var context = BufferPoolContext{ .pool = &pool };
    var case_storage: [1]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_io_buffer_pool_checkout_return",
        .config = bench_config,
    });
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "checkout_return_cycle",
        .tags = &[_][]const u8{ "static_io", "buffer_pool", "baseline" },
        .context = &context,
        .run_fn = BufferPoolContext.run,
    }));

    var sample_storage: [bench_config.sample_count]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [1]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(
        &group,
        &sample_storage,
        &case_result_storage,
    );

    std.debug.print("== static_io buffer pool checkout/return ==\n", .{});
    try support.writeSingleCaseReport(
        run_result,
        io,
        output_dir,
        "buffer pool steady-state checkout/return microbenchmark",
    );
}

fn validateSemanticPreflight() void {
    var pool = static_io.BufferPool.init(std.heap.page_allocator, .{
        .buffer_size = 32,
        .capacity = 2,
    }) catch unreachable;
    defer pool.deinit();

    const first = pool.acquire() catch unreachable;
    const second = pool.acquire() catch unreachable;
    std.debug.assert(pool.available() == 0);
    pool.release(first) catch unreachable;
    pool.release(second) catch unreachable;
    std.debug.assert(pool.available() == pool.capacity());
}
