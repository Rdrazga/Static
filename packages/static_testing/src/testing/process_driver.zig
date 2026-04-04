//! External deterministic driver process orchestration over a fixed binary wire protocol.
//!
//! The phase-4 driver keeps one request in flight at a time. This avoids hidden
//! multiplexing state while still providing a reusable process boundary for
//! replayable integration and end-to-end tests.

const builtin = @import("builtin");
const std = @import("std");
const driver_protocol = @import("driver_protocol.zig");

/// Operating errors surfaced by process driver lifecycle and protocol I/O.
pub const ProcessDriverError = error{
    InvalidConfig,
    InvalidInput,
    Overflow,
    Timeout,
    Unsupported,
    EndOfStream,
    NoSpaceLeft,
    BrokenPipe,
    AccessDenied,
    PermissionDenied,
    NotFound,
    SystemResources,
    ProcessFailed,
};

/// Process driver launch configuration.
pub const ProcessDriverConfig = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    environ_map: ?*const std.process.Environ.Map = null,
    expand_arg0: std.process.ArgExpansion = .expand,
    create_no_window: bool = true,
    timeout_ns_max: ?u64 = null,
    max_payload_bytes: u32 = 4096,
    stderr_capture_buffer: ?[]u8 = null,
};

/// Response view decoded into caller-owned payload storage.
pub const DriverResponse = struct {
    header: driver_protocol.DriverResponseHeader,
    payload: []const u8,
};

/// One bounded process-output capture retained after the child exits.
pub const CapturedProcessOutput = struct {
    bytes: []const u8,
    truncated: bool,
};

/// Live process-boundary driver session.
pub const ProcessDriver = struct {
    io: std.Io,
    config: ProcessDriverConfig,
    child: ?std.process.Child,
    next_request_id: u32 = 1,
    pending_request_id: ?u32 = null,
    stderr_capture_buffer: ?[]u8 = null,
    stderr_capture_len: u32 = 0,
    stderr_capture_truncated: bool = false,

    /// Spawn and initialize a child driver process.
    pub fn start(io: std.Io, config: ProcessDriverConfig) ProcessDriverError!ProcessDriver {
        try validateConfig(config);

        var child = std.process.spawn(io, .{
            .argv = config.argv,
            .cwd = config.cwd,
            .environ_map = config.environ_map,
            .expand_arg0 = config.expand_arg0,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = if (config.stderr_capture_buffer != null) .pipe else .ignore,
            .request_resource_usage_statistics = false,
            .create_no_window = config.create_no_window,
        }) catch |err| return mapSpawnError(err);
        errdefer child.kill(io);

        std.debug.assert(child.stdin != null);
        std.debug.assert(child.stdout != null);
        return .{
            .io = io,
            .config = config,
            .child = child,
            .stderr_capture_buffer = config.stderr_capture_buffer,
        };
    }

    /// Kill a still-running child if the caller exits without an orderly shutdown.
    pub fn deinit(self: *ProcessDriver) void {
        if (self.child) |*child| {
            child.kill(self.io);
            self.captureStderrBestEffort();
            self.child = null;
        }
        self.pending_request_id = null;
    }

    /// View bounded child `stderr` captured after process termination.
    pub fn capturedStderr(self: *const ProcessDriver) ?CapturedProcessOutput {
        const capture_buffer = self.stderr_capture_buffer orelse return null;
        return .{
            .bytes = capture_buffer[0..self.stderr_capture_len],
            .truncated = self.stderr_capture_truncated,
        };
    }

    /// Send a single request header plus payload to the child process.
    pub fn sendRequest(
        self: *ProcessDriver,
        kind: driver_protocol.DriverMessageKind,
        payload: []const u8,
    ) ProcessDriverError!u32 {
        const request_id = try self.reserveRequestId(payload.len);
        errdefer self.pending_request_id = null;

        var header_bytes: [driver_protocol.request_header_size_bytes]u8 = undefined;
        _ = try driver_protocol.encodeRequestHeader(&header_bytes, .{
            .kind = kind,
            .request_id = request_id,
            .payload_len = @as(u32, @intCast(payload.len)),
        });

        const child = try requireChild(self);
        try writeChildBytes(child.stdin.?, self.io, &header_bytes);
        try writeChildBytes(child.stdin.?, self.io, payload);
        return request_id;
    }

    /// Receive and validate the single in-flight response from the child process.
    ///
    /// If the response payload exceeds `payload_buffer.len`, this drains the
    /// payload, clears the in-flight request, and returns `error.NoSpaceLeft`
    /// while keeping the session usable for the next request. Header decode
    /// failures, mismatched request ids, oversized protocol payloads, and short
    /// reads are terminal: the child is torn down before the error is returned.
    pub fn recvResponse(
        self: *ProcessDriver,
        payload_buffer: []u8,
    ) ProcessDriverError!DriverResponse {
        const expected_request_id = self.pending_request_id orelse return error.InvalidInput;
        const child = try requireChild(self);

        var header_bytes: [driver_protocol.response_header_size_bytes]u8 = undefined;
        readChildBytes(child.stdout.?, self.io, &header_bytes) catch |err| {
            self.teardownTerminalFailure();
            return err;
        };
        const header = driver_protocol.decodeResponseHeader(&header_bytes) catch |err| {
            self.teardownTerminalFailure();
            return mapProtocolError(err);
        };

        if (header.request_id != expected_request_id) {
            self.teardownTerminalFailure();
            return error.InvalidInput;
        }
        if (header.payload_len > self.config.max_payload_bytes) {
            self.teardownTerminalFailure();
            return error.InvalidInput;
        }

        const payload_len: usize = @intCast(header.payload_len);
        if (payload_len > payload_buffer.len) {
            discardChildBytes(child.stdout.?, self.io, payload_len) catch |err| {
                self.teardownTerminalFailure();
                return err;
            };
            self.pending_request_id = null;
            return error.NoSpaceLeft;
        }

        readChildBytes(child.stdout.?, self.io, payload_buffer[0..payload_len]) catch |err| {
            self.teardownTerminalFailure();
            return err;
        };
        self.pending_request_id = null;

        return .{
            .header = header,
            .payload = payload_buffer[0..payload_len],
        };
    }

    /// Send shutdown, consume the terminal response, and wait for process exit.
    pub fn shutdown(self: *ProcessDriver) ProcessDriverError!void {
        if (self.child == null) return;
        if (self.pending_request_id != null) return error.InvalidInput;

        _ = self.sendRequest(.shutdown, &.{}) catch |err| {
            self.deinit();
            return err;
        };

        var payload_buffer: [1]u8 = undefined;
        const response = self.recvResponse(&payload_buffer) catch |err| {
            self.deinit();
            return err;
        };
        if (response.header.kind != .ok) {
            self.deinit();
            return error.ProcessFailed;
        }
        if (response.payload.len != 0) {
            self.deinit();
            return error.InvalidInput;
        }

        const child = try requireChild(self);
        const term = if (self.config.timeout_ns_max) |timeout_ns_max|
            waitForChildWithTimeout(self.io, child, timeout_ns_max) catch |err| {
                self.child = null;
                self.pending_request_id = null;
                return err;
            }
        else
            child.wait(self.io) catch |err| {
                self.deinit();
                return mapWaitError(err);
            };
        assertSuccessfulTerm(term) catch |err| {
            self.child = null;
            self.pending_request_id = null;
            return err;
        };

        self.captureStderrBestEffort();
        self.child = null;
        self.pending_request_id = null;
    }

    fn reserveRequestId(self: *ProcessDriver, payload_len: usize) ProcessDriverError!u32 {
        if (self.child == null) return error.ProcessFailed;
        if (self.pending_request_id != null) return error.InvalidInput;
        if (payload_len > self.config.max_payload_bytes) return error.NoSpaceLeft;
        if (self.next_request_id == 0) return error.Overflow;

        const request_id = self.next_request_id;
        self.next_request_id = std.math.add(u32, self.next_request_id, 1) catch 0;
        self.pending_request_id = request_id;
        return request_id;
    }

    fn captureStderrBestEffort(self: *ProcessDriver) void {
        const child = if (self.child) |*captured_child| captured_child else return;
        const capture_buffer = self.stderr_capture_buffer orelse return;
        const stderr_file = child.stderr orelse return;

        var bytes_captured: usize = self.stderr_capture_len;
        var discard_buffer: [256]u8 = undefined;
        while (true) {
            if (bytes_captured < capture_buffer.len) {
                const capture_target = capture_buffer[bytes_captured..];
                const bytes_read = stderr_file.readStreaming(self.io, &.{capture_target}) catch break;
                if (bytes_read == 0) break;
                bytes_captured += bytes_read;
                continue;
            }

            const bytes_read = stderr_file.readStreaming(self.io, &.{discard_buffer[0..]}) catch break;
            if (bytes_read == 0) break;
            self.stderr_capture_truncated = true;
        }

        std.debug.assert(bytes_captured <= capture_buffer.len);
        self.stderr_capture_len = @intCast(bytes_captured);
    }

    fn teardownTerminalFailure(self: *ProcessDriver) void {
        if (self.child) |*child| {
            self.captureStderrBestEffort();
            if (child.id != null) {
                if (self.config.timeout_ns_max) |timeout_ns_max| {
                    _ = waitForChildWithTimeout(self.io, child, timeout_ns_max) catch {
                        child.kill(self.io);
                    };
                } else {
                    _ = child.wait(self.io) catch {
                        child.kill(self.io);
                    };
                }
            }
            self.child = null;
        }
        self.pending_request_id = null;
    }
};

const WaitThreadState = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    done: bool = false,
    result: ?WaitResult = null,
    child: *std.process.Child,
    io: std.Io,

    const WaitResult = union(enum) {
        term: std.process.Child.Term,
        access_denied: void,
        process_failed: void,
    };

    fn waitThreadMain(self: *WaitThreadState) void {
        const term = self.child.wait(self.io) catch |err| {
            const result = switch (err) {
                error.AccessDenied => WaitResult{ .access_denied = {} },
                else => WaitResult{ .process_failed = {} },
            };
            self.finish(result);
            return;
        };
        self.finish(.{ .term = term });
    }

    fn finish(self: *WaitThreadState, result: WaitResult) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.result = result;
        self.done = true;
        self.cond.signal();
    }
};

fn validateConfig(config: ProcessDriverConfig) ProcessDriverError!void {
    if (config.argv.len == 0) return error.InvalidConfig;
    if (config.argv[0].len == 0) return error.InvalidConfig;
    if (config.max_payload_bytes == 0) return error.InvalidConfig;
    if (config.timeout_ns_max) |timeout_ns_max| {
        if (timeout_ns_max == 0) return error.InvalidConfig;
    }
}

fn requireChild(self: *ProcessDriver) ProcessDriverError!*std.process.Child {
    if (self.child == null) return error.ProcessFailed;
    return &self.child.?;
}

const FileWriteStreamingError = @typeInfo(
    @typeInfo(@TypeOf(std.Io.File.writeStreamingAll)).@"fn".return_type.?,
).error_union.error_set;

const FileReadStreamingError = @typeInfo(
    @typeInfo(@TypeOf(std.Io.File.readStreaming)).@"fn".return_type.?,
).error_union.error_set;

fn writeChildBytes(file: std.Io.File, io: std.Io, bytes: []const u8) ProcessDriverError!void {
    file.writeStreamingAll(io, bytes) catch |err| return mapWriteError(err);
}

fn readChildBytes(file: std.Io.File, io: std.Io, buffer: []u8) ProcessDriverError!void {
    var index: usize = 0;
    while (index < buffer.len) {
        const bytes_read = file.readStreaming(io, &.{buffer[index..]}) catch |err| {
            return mapReadError(err);
        };
        if (bytes_read == 0) return error.EndOfStream;
        index += bytes_read;
    }
}

fn discardChildBytes(file: std.Io.File, io: std.Io, bytes_total: usize) ProcessDriverError!void {
    var discard_storage: [256]u8 = undefined;
    var remaining_bytes = bytes_total;
    while (remaining_bytes > 0) {
        const chunk_len = @min(remaining_bytes, discard_storage.len);
        try readChildBytes(file, io, discard_storage[0..chunk_len]);
        remaining_bytes -= chunk_len;
    }
}

fn waitForChildWithTimeout(
    io: std.Io,
    child: *std.process.Child,
    timeout_ns_max: u64,
) ProcessDriverError!std.process.Child.Term {
    std.debug.assert(child.id != null);
    std.debug.assert(timeout_ns_max > 0);

    const child_id = child.id.?;
    var wait_state = WaitThreadState{
        .child = child,
        .io = io,
    };
    var waiter = std.Thread.spawn(.{}, WaitThreadState.waitThreadMain, .{&wait_state}) catch {
        return error.SystemResources;
    };
    defer waiter.join();

    const start_instant = std.time.Instant.now() catch return error.Unsupported;
    wait_state.mutex.lock();
    defer wait_state.mutex.unlock();

    var remaining_ns = timeout_ns_max;
    while (!wait_state.done) {
        wait_state.cond.timedWait(&wait_state.mutex, remaining_ns) catch |err| switch (err) {
            error.Timeout => {
                wait_state.mutex.unlock();
                try terminateTimedOutChildAndReap(&wait_state, child_id);
                return error.Timeout;
            },
        };

        if (!wait_state.done) {
            const elapsed_ns = (std.time.Instant.now() catch return error.Unsupported).since(start_instant);
            if (elapsed_ns >= timeout_ns_max) {
                wait_state.mutex.unlock();
                try terminateTimedOutChildAndReap(&wait_state, child_id);
                return error.Timeout;
            }
            remaining_ns = timeout_ns_max - elapsed_ns;
        }
    }

    return switch (wait_state.result.?) {
        .term => |term| term,
        .access_denied => error.AccessDenied,
        .process_failed => error.ProcessFailed,
    };
}

fn terminateTimedOutChildAndReap(
    wait_state: *WaitThreadState,
    child_id: std.process.Child.Id,
) ProcessDriverError!void {
    const terminate_result = terminateChildId(child_id);

    wait_state.mutex.lock();
    while (!wait_state.done) wait_state.cond.wait(&wait_state.mutex);
    terminate_result catch |err| return err;
}

fn terminateChildId(child_id: std.process.Child.Id) ProcessDriverError!void {
    switch (builtin.os.tag) {
        .windows => {
            if (std.os.windows.kernel32.TerminateProcess(child_id, 1) == 0) {
                return error.ProcessFailed;
            }
        },
        .wasi => {},
        else => {
            std.posix.kill(child_id, std.posix.SIG.KILL) catch |err| switch (err) {
                error.ProcessNotFound => {},
                else => return error.ProcessFailed,
            };
        },
    }
}

fn assertSuccessfulTerm(term: std.process.Child.Term) ProcessDriverError!void {
    switch (term) {
        .exited => |exit_code| {
            if (exit_code != 0) return error.ProcessFailed;
        },
        else => return error.ProcessFailed,
    }
}

fn mapProtocolError(err: driver_protocol.DriverProtocolError) ProcessDriverError {
    return switch (err) {
        error.NoSpaceLeft => error.NoSpaceLeft,
        error.EndOfStream => error.EndOfStream,
        error.InvalidInput => error.InvalidInput,
        error.Unsupported => error.Unsupported,
        error.Overflow => error.Overflow,
    };
}

fn mapSpawnError(err: std.process.SpawnError) ProcessDriverError {
    return switch (err) {
        error.OperationUnsupported => error.Unsupported,
        error.OutOfMemory => error.SystemResources,
        error.AccessDenied => error.AccessDenied,
        error.PermissionDenied => error.PermissionDenied,
        error.SystemResources => error.SystemResources,
        error.ProcessFdQuotaExceeded => error.SystemResources,
        error.SystemFdQuotaExceeded => error.SystemResources,
        error.ResourceLimitReached => error.SystemResources,
        error.FileNotFound => error.NotFound,
        error.NotDir => error.NotFound,
        error.IsDir => error.NotFound,
        error.SymLinkLoop => error.NotFound,
        error.InvalidExe => error.NotFound,
        error.InvalidName => error.InvalidConfig,
        error.InvalidWtf8 => error.InvalidConfig,
        error.InvalidBatchScriptArg => error.InvalidConfig,
        error.NoDevice => error.Unsupported,
        error.FileSystem => error.NotFound,
        error.FileBusy => error.ProcessFailed,
        error.ProcessAlreadyExec => error.ProcessFailed,
        error.Canceled => error.ProcessFailed,
        error.Unexpected => error.ProcessFailed,
        error.NameTooLong => error.InvalidConfig,
        error.BadPathName => error.InvalidConfig,
        error.InvalidUserId => error.InvalidConfig,
        error.InvalidProcessGroupId => error.InvalidConfig,
    };
}

fn mapWriteError(err: FileWriteStreamingError) ProcessDriverError {
    return switch (err) {
        error.BrokenPipe => error.BrokenPipe,
        error.AccessDenied => error.AccessDenied,
        error.PermissionDenied => error.PermissionDenied,
        error.NoSpaceLeft => error.NoSpaceLeft,
        error.SystemResources => error.SystemResources,
        else => error.ProcessFailed,
    };
}

fn mapReadError(err: FileReadStreamingError) ProcessDriverError {
    return switch (err) {
        error.AccessDenied => error.AccessDenied,
        error.BrokenPipe => error.BrokenPipe,
        error.SystemResources => error.SystemResources,
        else => error.ProcessFailed,
    };
}

fn mapWaitError(err: std.process.Child.WaitError) ProcessDriverError {
    return switch (err) {
        error.AccessDenied => error.AccessDenied,
        else => error.ProcessFailed,
    };
}

test "process driver config rejects empty argv and zero timeout" {
    try std.testing.expectError(error.InvalidConfig, validateConfig(.{
        .argv = &.{},
    }));
    try std.testing.expectError(error.InvalidConfig, validateConfig(.{
        .argv = &[_][]const u8{"child"},
        .timeout_ns_max = 0,
    }));
}

test "process driver deinit is idempotent after empty session" {
    var driver = ProcessDriver{
        .io = std.testing.io,
        .config = .{
            .argv = &[_][]const u8{"child"},
        },
        .child = null,
    };
    driver.deinit();
    driver.deinit();
    try std.testing.expect(driver.child == null);
}
