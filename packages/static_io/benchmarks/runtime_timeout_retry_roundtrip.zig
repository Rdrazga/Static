//! `static_io` runtime timeout+retry roundtrip baseline benchmark.

const std = @import("std");
const static_io = @import("static_io");
const static_testing = @import("static_testing");
const support = @import("support.zig");

const bench = static_testing.bench;

const endpoint = static_io.Endpoint{
    .ipv4 = .{
        .address = .init(127, 0, 0, 1),
        .port = 9021,
    },
};

const bench_config = bench.config.BenchmarkConfig{
    .mode = .full,
    .warmup_iterations = 16,
    .measure_iterations = 131_072,
    .sample_count = 16,
};

const RuntimeContext = struct {
    pool: *static_io.BufferPool,
    runtime: *static_io.Runtime,
    stream: static_io.types.Stream,
    sink: u32 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *RuntimeContext = @ptrCast(@alignCast(context_ptr));
        std.debug.assert(context.pool.capacity() >= 3);
        std.debug.assert(context.runtime.cfg.max_in_flight >= 3);

        const timeout_buffer = context.pool.acquire() catch unreachable;
        const timeout_id = context.runtime.submitStreamRead(context.stream, timeout_buffer, 0) catch unreachable;
        _ = context.runtime.pump(1) catch unreachable;
        const timeout_completion = context.runtime.poll() orelse unreachable;
        if (timeout_completion.operation_id != timeout_id) unreachable;
        if (timeout_completion.status != .timeout) unreachable;
        if (timeout_completion.err != .timeout) unreachable;
        context.pool.release(timeout_completion.buffer) catch unreachable;

        var write_buffer = context.pool.acquire() catch unreachable;
        @memcpy(write_buffer.bytes[0..2], "ok");
        write_buffer.setUsedLen(2) catch unreachable;
        const write_id = context.runtime.submitStreamWrite(context.stream, write_buffer, null) catch unreachable;
        _ = context.runtime.pump(1) catch unreachable;
        const write_completion = context.runtime.poll() orelse unreachable;
        if (write_completion.operation_id != write_id) unreachable;
        if (write_completion.status != .success) unreachable;
        context.pool.release(write_completion.buffer) catch unreachable;

        const read_buffer = context.pool.acquire() catch unreachable;
        const read_id = context.runtime.submitStreamRead(context.stream, read_buffer, null) catch unreachable;
        _ = context.runtime.pump(1) catch unreachable;
        const read_completion = context.runtime.poll() orelse unreachable;
        if (read_completion.operation_id != read_id) unreachable;
        if (read_completion.status != .success) unreachable;
        if (!std.mem.eql(u8, read_completion.buffer.usedSlice(), "ok")) unreachable;
        context.pool.release(read_completion.buffer) catch unreachable;

        if (context.runtime.poll() != null) unreachable;
        context.sink = bench.case.blackBox(
            timeout_completion.operation_id ^
                write_completion.operation_id ^
                read_completion.operation_id ^
                read_completion.bytes_transferred,
        );
        std.debug.assert(context.sink != 0);
        std.debug.assert(context.pool.available() == context.pool.capacity());
    }
};

pub fn main() !void {
    validateSemanticPreflight();

    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    var output_dir = try support.openOutputDir(io, "runtime_timeout_retry_roundtrip");
    defer output_dir.close(io);

    var pool = try static_io.BufferPool.init(std.heap.page_allocator, .{
        .buffer_size = 128,
        .capacity = 8,
    });
    defer pool.deinit();

    var runtime = try static_io.Runtime.init(std.heap.page_allocator, .{
        .max_in_flight = 8,
        .submission_queue_capacity = 8,
        .completion_queue_capacity = 8,
        .handles_max = 8,
        .backend_kind = .fake,
    });
    defer runtime.deinit();

    const connect_id = try runtime.submitConnect(endpoint, null);
    _ = try runtime.pump(1);
    const connect_completion = runtime.poll() orelse return error.MissingCompletion;
    if (connect_completion.operation_id != connect_id) return error.UnexpectedCompletion;
    if (connect_completion.status != .success) return error.UnexpectedCompletion;
    if (connect_completion.handle == null) return error.UnexpectedCompletion;

    var context = RuntimeContext{
        .pool = &pool,
        .runtime = &runtime,
        .stream = .{ .handle = connect_completion.handle.? },
    };
    defer runtime.closeHandle(context.stream.handle) catch {};
    var case_storage: [1]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_io_runtime_timeout_retry_roundtrip",
        .config = bench_config,
    });
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "timeout_then_retry_read",
        .tags = &[_][]const u8{ "static_io", "runtime", "retry", "timeout" },
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

    std.debug.print("== static_io runtime timeout+retry roundtrip ==\n", .{});
    try support.writeSingleCaseReport(
        run_result,
        io,
        output_dir,
        "fake-backend immediate-timeout read followed by write/read recovery roundtrip",
    );
}

fn validateSemanticPreflight() void {
    var pool = static_io.BufferPool.init(std.heap.page_allocator, .{
        .buffer_size = 32,
        .capacity = 4,
    }) catch unreachable;
    defer pool.deinit();

    var runtime = static_io.Runtime.init(std.heap.page_allocator, static_io.RuntimeConfig.initForTest(4)) catch unreachable;
    defer runtime.deinit();

    const connect_id = runtime.submitConnect(endpoint, null) catch unreachable;
    _ = runtime.pump(1) catch unreachable;
    const connect_completion = runtime.poll() orelse unreachable;
    std.debug.assert(connect_completion.operation_id == connect_id);
    std.debug.assert(connect_completion.status == .success);
    const stream = static_io.types.Stream{ .handle = connect_completion.handle.? };
    defer runtime.closeHandle(stream.handle) catch unreachable;

    const timeout_buffer = pool.acquire() catch unreachable;
    const timeout_id = runtime.submitStreamRead(stream, timeout_buffer, 0) catch unreachable;
    _ = runtime.pump(1) catch unreachable;
    const timeout_completion = runtime.poll() orelse unreachable;
    std.debug.assert(timeout_completion.operation_id == timeout_id);
    std.debug.assert(timeout_completion.status == .timeout);
    pool.release(timeout_completion.buffer) catch unreachable;

    var write_buffer = pool.acquire() catch unreachable;
    @memcpy(write_buffer.bytes[0..2], "ok");
    write_buffer.setUsedLen(2) catch unreachable;
    const write_id = runtime.submitStreamWrite(stream, write_buffer, null) catch unreachable;
    _ = runtime.pump(1) catch unreachable;
    const write_completion = runtime.poll() orelse unreachable;
    std.debug.assert(write_completion.operation_id == write_id);
    std.debug.assert(write_completion.status == .success);
    pool.release(write_completion.buffer) catch unreachable;

    const read_buffer = pool.acquire() catch unreachable;
    const read_id = runtime.submitStreamRead(stream, read_buffer, null) catch unreachable;
    _ = runtime.pump(1) catch unreachable;
    const read_completion = runtime.poll() orelse unreachable;
    std.debug.assert(read_completion.operation_id == read_id);
    std.debug.assert(read_completion.status == .success);
    std.debug.assert(std.mem.eql(u8, read_completion.buffer.usedSlice(), "ok"));
    pool.release(read_completion.buffer) catch unreachable;
    std.debug.assert(pool.available() == pool.capacity());
}
