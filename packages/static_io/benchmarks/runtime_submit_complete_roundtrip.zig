//! `static_io` runtime submit/complete roundtrip baseline benchmark.

const std = @import("std");
const assert = std.debug.assert;
const static_io = @import("static_io");
const static_testing = @import("static_testing");
const support = @import("support.zig");

const bench = static_testing.bench;

const bench_config = bench.config.BenchmarkConfig{
    .mode = .full,
    .warmup_iterations = 32,
    .measure_iterations = 262_144,
    .sample_count = 16,
};

const RuntimeContext = struct {
    pool: *static_io.BufferPool,
    runtime: *static_io.Runtime,
    sink: u32 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *RuntimeContext = @ptrCast(@alignCast(context_ptr));
        assert(context.pool.capacity() != 0);
        assert(context.runtime.cfg.max_in_flight != 0);

        const buffer = context.pool.acquire() catch unreachable;
        const op_id = context.runtime.submit(.{ .nop = buffer }) catch unreachable;
        _ = context.runtime.pump(1) catch unreachable;

        const completion = context.runtime.poll() orelse unreachable;
        if (completion.operation_id != op_id) unreachable;
        if (completion.status != .success) unreachable;
        context.pool.release(completion.buffer) catch unreachable;
        context.sink = bench.case.blackBox(completion.operation_id);
        assert(context.sink != 0);
    }
};

pub fn main() !void {
    validateSemanticPreflight();

    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    var output_dir = try support.openOutputDir(io, "runtime_submit_complete_roundtrip");
    defer output_dir.close(io);

    var pool = try static_io.BufferPool.init(std.heap.page_allocator, .{
        .buffer_size = 128,
        .capacity = 256,
    });
    defer pool.deinit();

    var runtime = try static_io.Runtime.init(std.heap.page_allocator, .{
        .max_in_flight = 256,
        .submission_queue_capacity = 256,
        .completion_queue_capacity = 256,
        .handles_max = 256,
        .backend_kind = .fake,
    });
    defer runtime.deinit();

    var context = RuntimeContext{
        .pool = &pool,
        .runtime = &runtime,
    };
    var case_storage: [1]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_io_runtime_submit_complete_roundtrip",
        .config = bench_config,
    });
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "submit_complete_nop",
        .tags = &[_][]const u8{ "static_io", "runtime", "baseline" },
        .context = &context,
        .run_fn = RuntimeContext.run,
    }));

    var sample_storage: [bench_config.sample_count]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [1]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(
        &group,
        &sample_storage,
        &case_result_storage,
    );

    std.debug.print("== static_io runtime submit/complete roundtrip ==\n", .{});
    try support.writeSingleCaseReport(
        run_result,
        io,
        output_dir,
        "fake-backend runtime nop submit/pump/poll/release roundtrip",
    );
}

fn validateSemanticPreflight() void {
    var pool = static_io.BufferPool.init(std.heap.page_allocator, .{
        .buffer_size = 32,
        .capacity = 2,
    }) catch unreachable;
    defer pool.deinit();

    var runtime = static_io.Runtime.init(std.heap.page_allocator, static_io.RuntimeConfig.initForTest(2)) catch unreachable;
    defer runtime.deinit();

    const buffer = pool.acquire() catch unreachable;
    const op_id = runtime.submit(.{ .nop = buffer }) catch unreachable;
    _ = runtime.pump(1) catch unreachable;
    const completion = runtime.poll() orelse unreachable;
    assert(completion.operation_id == op_id);
    assert(completion.status == .success);
    pool.release(completion.buffer) catch unreachable;
    assert(pool.available() == pool.capacity());
}
