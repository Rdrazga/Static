const builtin = @import("builtin");
const std = @import("std");
const static_io = @import("static_io");
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const identity = static_testing.testing.identity;
const sim = static_testing.testing.sim;
const system = static_testing.testing.system;
const temporal = static_testing.testing.temporal;
const support = @import("support.zig");

const Fixture = sim.fixture.Fixture(8, 8, 8, 64);

const components = [_]system.ComponentSpec{
    .{ .name = "runtime" },
    .{ .name = "buffer_pool" },
    .{ .name = "windows_backend" },
};

const backend_violations = [_]checker.Violation{
    .{
        .code = "static_io.windows_backend_flow",
        .message = "windows backend loopback flow did not preserve runtime and buffer invariants",
    },
};

const BackendCase = struct {
    name: []const u8,
    kind: static_io.config.BackendKind,
};

const backend_cases = [_]BackendCase{
    .{ .name = "platform", .kind = .platform },
    .{ .name = "windows_iocp", .kind = .windows_iocp },
};

const WindowsBackendRunner = struct {
    runtime: *static_io.Runtime,
    pool: *static_io.BufferPool,
    next_sequence_no: u32 = 0,

    fn run(
        self: *@This(),
        context: *system.SystemContext(Fixture),
    ) anyerror!checker.CheckResult {
        std.debug.assert(context.hasComponent("runtime"));
        std.debug.assert(context.hasComponent("buffer_pool"));
        std.debug.assert(context.hasComponent("windows_backend"));
        std.debug.assert(context.traceBufferPtr() != null);

        const listener = try self.runtime.listen(.{ .ipv4 = .{
            .address = .init(127, 0, 0, 1),
            .port = 0,
        } }, .{ .backlog = 8 });
        defer self.runtime.closeHandle(listener.handle) catch {};

        const endpoint = try self.runtime.listenerLocalEndpoint(listener);
        _ = try support.appendEvent(context, &self.next_sequence_no, "io.listen.bound", .check, "windows_backend", null, 1);

        const accept_id = try self.runtime.submitAccept(listener, null);
        const connect_id = try self.runtime.submitConnect(endpoint, null);
        const pair = try waitForPair(self.runtime, accept_id, connect_id);
        defer self.runtime.closeHandle(pair.server.handle) catch {};
        defer self.runtime.closeHandle(pair.client.handle) catch {};

        const connected_seq = try support.appendEvent(
            context,
            &self.next_sequence_no,
            "io.loopback.connected",
            .check,
            "windows_backend",
            null,
            1,
        );

        var write_buffer = try self.pool.acquire();
        @memcpy(write_buffer.bytes[0..5], "hello");
        try write_buffer.setUsedLen(5);
        const read_buffer = try self.pool.acquire();
        const write_id = try self.runtime.submitStreamWrite(pair.client, write_buffer, std.time.ns_per_s);
        const read_id = try self.runtime.submitStreamRead(pair.server, read_buffer, std.time.ns_per_s);
        const io_completions = try waitForIoPair(self.runtime, write_id, read_id);

        try std.testing.expectEqual(static_io.types.CompletionStatus.success, io_completions.write.status);
        try std.testing.expectEqual(static_io.types.CompletionStatus.success, io_completions.read.status);
        try std.testing.expectEqual(@as(u32, 5), io_completions.write.bytes_transferred);
        try std.testing.expectEqual(@as(u32, 5), io_completions.read.bytes_transferred);
        try std.testing.expectEqualStrings("hello", io_completions.read.buffer.usedSlice());

        const write_seq = try support.appendEvent(
            context,
            &self.next_sequence_no,
            "io.write.loopback.success",
            .check,
            "runtime",
            connected_seq,
            io_completions.write.bytes_transferred,
        );
        const read_seq = try support.appendEvent(
            context,
            &self.next_sequence_no,
            "io.read.loopback.success",
            .check,
            "runtime",
            write_seq,
            io_completions.read.bytes_transferred,
        );

        try self.pool.release(io_completions.write.buffer);
        try self.pool.release(io_completions.read.buffer);

        const timeout_buffer = try self.pool.acquire();
        const timeout_id = try self.runtime.submitStreamRead(pair.server, timeout_buffer, 0);
        const timeout_completion = try waitForCompletion(self.runtime, timeout_id, 8);
        try std.testing.expectEqual(static_io.types.CompletionStatus.timeout, timeout_completion.status);
        try std.testing.expectEqual(@as(?static_io.types.CompletionErrorTag, .timeout), timeout_completion.err);
        try std.testing.expectEqual(@as(u32, 0), timeout_completion.bytes_transferred);
        _ = try support.appendEvent(
            context,
            &self.next_sequence_no,
            "io.read.loopback.timeout",
            .check,
            "runtime",
            read_seq,
            timeout_completion.bytes_transferred,
        );
        try self.pool.release(timeout_completion.buffer);

        const snapshot = context.traceSnapshot().?;
        const connected_before_write = try temporal.checkHappensBefore(
            snapshot,
            .{ .label = "io.loopback.connected", .surface_label = "windows_backend" },
            .{ .label = "io.write.loopback.success", .surface_label = "runtime" },
        );
        if (!connected_before_write.check_result.passed) return connected_before_write.check_result;

        const write_before_read = try temporal.checkHappensBefore(
            snapshot,
            .{ .label = "io.write.loopback.success", .surface_label = "runtime" },
            .{ .label = "io.read.loopback.success", .surface_label = "runtime" },
        );
        if (!write_before_read.check_result.passed) return write_before_read.check_result;

        const timeout_once = try temporal.checkExactlyOnce(snapshot, .{
            .label = "io.read.loopback.timeout",
            .surface_label = "runtime",
        });
        if (!timeout_once.check_result.passed) return timeout_once.check_result;

        if (self.pool.available() != self.pool.capacity()) {
            return checker.CheckResult.fail(&backend_violations, null);
        }

        return checker.CheckResult.pass(checker.CheckpointDigest.init(
            (@as(u128, snapshot.items.len) << 64) | @as(u128, self.pool.available()),
        ));
    }
};

test "static_io testing.system covers Windows loopback backends" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    if (!static_io.caps.windowsBackendEnabled()) return error.SkipZigTest;

    inline for (backend_cases) |backend_case| {
        var fixture: Fixture = undefined;
        try fixture.init(.{
            .allocator = std.testing.allocator,
            .timer_queue_config = .{ .buckets = 8, .timers_max = 8 },
            .scheduler_seed = .init(901),
            .scheduler_config = .{ .strategy = .first },
            .event_loop_config = .{ .step_budget_max = 8 },
            .trace_config = .{ .max_events = 64 },
        });
        defer fixture.deinit();

        var pool = try static_io.BufferPool.init(std.testing.allocator, .{
            .buffer_size = 64,
            .capacity = 4,
        });
        defer pool.deinit();

        var runtime_config = static_io.RuntimeConfig.initForTest(16);
        runtime_config.backend_kind = backend_case.kind;
        runtime_config.threaded_worker_count = 2;
        var runtime = try static_io.Runtime.init(std.testing.allocator, runtime_config);
        defer runtime.deinit();

        var runner = WindowsBackendRunner{
            .runtime = &runtime,
            .pool = &pool,
        };
        const run_identity = identity.makeRunIdentity(.{
            .package_name = "static_io",
            .run_name = backend_case.name,
            .seed = .init(902),
            .build_mode = .debug,
        });

        const execution = try system.runWithFixture(Fixture, WindowsBackendRunner, anyerror, &fixture, run_identity, .{
            .components = &components,
        }, &runner, WindowsBackendRunner.run);

        try std.testing.expect(execution.check_result.passed);
        try std.testing.expectEqual(@as(usize, components.len), execution.component_count);
        try std.testing.expect(execution.trace_metadata.event_count >= 4);
        try std.testing.expect(execution.retained_bundle == null);
    }
}

fn waitForPair(
    runtime: *static_io.Runtime,
    accept_id: static_io.types.OperationId,
    connect_id: static_io.types.OperationId,
) !struct { server: static_io.types.Stream, client: static_io.types.Stream } {
    var server: ?static_io.types.Stream = null;
    var client: ?static_io.types.Stream = null;
    var attempt: u32 = 0;
    while (attempt < 8 and (server == null or client == null)) : (attempt += 1) {
        _ = try runtime.wait(2, std.time.ns_per_s, null);
        while (runtime.poll()) |completion| {
            switch (completion.tag) {
                .accept => {
                    try std.testing.expectEqual(accept_id, completion.operation_id);
                    try std.testing.expectEqual(static_io.types.CompletionStatus.success, completion.status);
                    server = .{ .handle = completion.handle.? };
                },
                .connect => {
                    try std.testing.expectEqual(connect_id, completion.operation_id);
                    try std.testing.expectEqual(static_io.types.CompletionStatus.success, completion.status);
                    client = .{ .handle = completion.handle.? };
                },
                else => {},
            }
        }
    }
    if (server == null or client == null) return error.MissingCompletion;
    return .{
        .server = server.?,
        .client = client.?,
    };
}

fn waitForIoPair(
    runtime: *static_io.Runtime,
    write_id: static_io.types.OperationId,
    read_id: static_io.types.OperationId,
) !struct { write: static_io.types.Completion, read: static_io.types.Completion } {
    var write_completion: ?static_io.types.Completion = null;
    var read_completion: ?static_io.types.Completion = null;
    var attempt: u32 = 0;
    while (attempt < 8 and (write_completion == null or read_completion == null)) : (attempt += 1) {
        _ = try runtime.wait(2, std.time.ns_per_s, null);
        while (runtime.poll()) |completion| {
            if (completion.operation_id == write_id) {
                write_completion = completion;
            } else if (completion.operation_id == read_id) {
                read_completion = completion;
            }
        }
    }
    if (write_completion == null or read_completion == null) return error.MissingCompletion;
    return .{
        .write = write_completion.?,
        .read = read_completion.?,
    };
}

fn waitForCompletion(
    runtime: *static_io.Runtime,
    operation_id: static_io.types.OperationId,
    attempts_max: u32,
) !static_io.types.Completion {
    var attempt: u32 = 0;
    while (attempt < attempts_max) : (attempt += 1) {
        _ = try runtime.wait(1, std.time.ns_per_s, null);
        while (runtime.poll()) |completion| {
            if (completion.operation_id == operation_id) return completion;
        }
    }
    return error.MissingCompletion;
}
