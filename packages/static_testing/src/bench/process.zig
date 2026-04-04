//! Command and process benchmark runner for arbitrary programs.
//!
//! Phase 3 keeps the process benchmark surface intentionally small:
//! - run one configured command repeatedly;
//! - exclude warmups from recorded samples;
//! - optionally enforce a timeout via an external killer and waiter thread; and
//! - allow caller-owned environment maps and prepare hooks.

const builtin = @import("builtin");
const std = @import("std");
const config_mod = @import("config.zig");
const runner = @import("runner.zig");

/// Operating errors surfaced by child-process benchmark execution.
pub const ProcessBenchmarkError = error{
    InvalidConfig,
    Overflow,
    Unsupported,
    Timeout,
    OutOfMemory,
    NoSpaceLeft,
    AccessDenied,
    PermissionDenied,
    NotFound,
    SystemResources,
    ProcessFailed,
};

/// Distinguishes untimed warmups from timed measurement runs.
pub const ProcessRunPhase = enum(u8) {
    warmup = 1,
    measure = 2,
};

/// Deterministic infallible setup hook invoked before each child run.
pub const ProcessPrepareFn = *const fn (
    context: *anyopaque,
    phase: ProcessRunPhase,
    run_index: u32,
) void;

/// Process benchmark runtime configuration.
pub const ProcessBenchmarkConfig = struct {
    benchmark: config_mod.BenchmarkConfig,
    timeout_ns_max: ?u64 = null,
    request_resource_usage_statistics: bool = false,
};

/// Process benchmark case construction options.
pub const ProcessBenchmarkCaseOptions = struct {
    name: []const u8,
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    environ_map: ?*const std.process.Environ.Map = null,
    expand_arg0: std.process.ArgExpansion = .expand,
    create_no_window: bool = true,
    prepare_context: ?*anyopaque = null,
    prepare_fn: ?ProcessPrepareFn = null,
};

/// One child-process benchmark case plus launch configuration.
pub const ProcessBenchmarkCase = struct {
    name: []const u8,
    argv: []const []const u8,
    cwd: ?[]const u8,
    environ_map: ?*const std.process.Environ.Map,
    expand_arg0: std.process.ArgExpansion,
    create_no_window: bool,
    prepare_context: ?*anyopaque,
    prepare_fn: ?ProcessPrepareFn,

    /// Construct one process benchmark case.
    pub fn init(options: ProcessBenchmarkCaseOptions) ProcessBenchmarkCase {
        std.debug.assert(options.name.len > 0);
        assertValidArgv(options.argv);

        return .{
            .name = options.name,
            .argv = options.argv,
            .cwd = options.cwd,
            .environ_map = options.environ_map,
            .expand_arg0 = options.expand_arg0,
            .create_no_window = options.create_no_window,
            .prepare_context = options.prepare_context,
            .prepare_fn = options.prepare_fn,
        };
    }

    /// Invoke deterministic pre-run setup.
    ///
    /// The hook is intentionally infallible so setup does not add an unrelated
    /// operating-error branch to the timed execution contract. Setup that can
    /// fail should happen before `runProcessBenchmark()`, or should be surfaced
    /// by the child command itself.
    pub fn prepare(self: ProcessBenchmarkCase, phase: ProcessRunPhase, run_index: u32) void {
        if (self.prepare_fn) |prepare_fn| {
            std.debug.assert(self.prepare_context != null);
            prepare_fn(self.prepare_context.?, phase, run_index);
        } else {
            std.debug.assert(self.prepare_context == null);
        }
    }
};

/// Raw process benchmark result plus optional RSS summary.
pub const ProcessBenchmarkResult = struct {
    name: []const u8,
    warmup_iterations: u32,
    measure_iterations: u32,
    samples: []const runner.BenchmarkSample,
    total_elapsed_ns: u64,
    max_rss_bytes_max: ?usize,

    /// View the process result as a generic benchmark case result.
    pub fn asCaseResult(self: ProcessBenchmarkResult) runner.BenchmarkCaseResult {
        return .{
            .name = self.name,
            .warmup_iterations = self.warmup_iterations,
            .measure_iterations = self.measure_iterations,
            .samples = self.samples,
            .total_elapsed_ns = self.total_elapsed_ns,
        };
    }
};

const ChildRunResult = struct {
    elapsed_ns: u64,
    max_rss_bytes: ?usize,
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
            self.mutex.lock();
            defer self.mutex.unlock();
            self.result = result;
            self.done = true;
            self.cond.signal();
            return;
        };
        const result = WaitResult{ .term = term };

        self.mutex.lock();
        defer self.mutex.unlock();
        self.result = result;
        self.done = true;
        self.cond.signal();
    }
};

/// Run one process benchmark into caller-provided sample storage.
pub fn runProcessBenchmark(
    io: std.Io,
    benchmark_case: *const ProcessBenchmarkCase,
    benchmark_config: ProcessBenchmarkConfig,
    sample_storage: []runner.BenchmarkSample,
) ProcessBenchmarkError!ProcessBenchmarkResult {
    try validateProcessInputs(benchmark_case, benchmark_config, sample_storage);
    try runProcessWarmups(io, benchmark_case, benchmark_config);

    var total_elapsed_ns: u64 = 0;
    var max_rss_bytes_max: ?usize = null;
    var sample_index: usize = 0;
    while (sample_index < benchmark_config.benchmark.sample_count) : (sample_index += 1) {
        const sample_run = try runMeasuredSample(
            io,
            benchmark_case,
            benchmark_config,
            @as(u32, @intCast(sample_index)),
        );

        sample_storage[sample_index] = .{
            .elapsed_ns = sample_run.elapsed_ns,
            .iteration_count = benchmark_config.benchmark.measure_iterations,
        };
        total_elapsed_ns = std.math.add(u64, total_elapsed_ns, sample_run.elapsed_ns) catch {
            return error.Overflow;
        };
        max_rss_bytes_max = maxOptionalUsize(max_rss_bytes_max, sample_run.max_rss_bytes);
    }

    return .{
        .name = benchmark_case.name,
        .warmup_iterations = benchmark_config.benchmark.warmup_iterations,
        .measure_iterations = benchmark_config.benchmark.measure_iterations,
        .samples = sample_storage[0..benchmark_config.benchmark.sample_count],
        .total_elapsed_ns = total_elapsed_ns,
        .max_rss_bytes_max = max_rss_bytes_max,
    };
}

fn validateProcessInputs(
    benchmark_case: *const ProcessBenchmarkCase,
    benchmark_config: ProcessBenchmarkConfig,
    sample_storage: []runner.BenchmarkSample,
) ProcessBenchmarkError!void {
    config_mod.validateConfig(benchmark_config.benchmark) catch |err| return switch (err) {
        error.InvalidConfig => error.InvalidConfig,
        error.Overflow => error.Overflow,
    };
    if (benchmark_case.argv.len == 0) return error.InvalidConfig;
    if (benchmark_case.argv[0].len == 0) return error.InvalidConfig;
    if (benchmark_case.name.len == 0) return error.InvalidConfig;
    if (sample_storage.len < benchmark_config.benchmark.sample_count) return error.NoSpaceLeft;
    if (benchmark_case.prepare_fn != null) {
        try validateMeasureRunIndexSpace(benchmark_config.benchmark);
    }
    if (benchmark_config.timeout_ns_max) |timeout_ns_max| {
        if (timeout_ns_max == 0) return error.InvalidConfig;
    }
}

fn runProcessWarmups(
    io: std.Io,
    benchmark_case: *const ProcessBenchmarkCase,
    benchmark_config: ProcessBenchmarkConfig,
) ProcessBenchmarkError!void {
    var warmup_index: u32 = 0;
    while (warmup_index < benchmark_config.benchmark.warmup_iterations) : (warmup_index += 1) {
        _ = try runPreparedChild(io, benchmark_case, benchmark_config, .warmup, warmup_index);
    }
}

fn runPreparedChild(
    io: std.Io,
    benchmark_case: *const ProcessBenchmarkCase,
    benchmark_config: ProcessBenchmarkConfig,
    phase: ProcessRunPhase,
    run_index: u32,
) ProcessBenchmarkError!ChildRunResult {
    benchmark_case.prepare(phase, run_index);
    return runChildOnce(io, benchmark_case, benchmark_config);
}

fn runMeasuredSample(
    io: std.Io,
    benchmark_case: *const ProcessBenchmarkCase,
    benchmark_config: ProcessBenchmarkConfig,
    sample_index: u32,
) ProcessBenchmarkError!ChildRunResult {
    var elapsed_ns_total: u64 = 0;
    var max_rss_bytes: ?usize = null;
    var measure_index: u32 = 0;
    while (measure_index < benchmark_config.benchmark.measure_iterations) : (measure_index += 1) {
        const run_index = try measuredRunIndex(
            sample_index,
            benchmark_config.benchmark.measure_iterations,
            measure_index,
        );
        const child_run = try runPreparedChild(
            io,
            benchmark_case,
            benchmark_config,
            .measure,
            run_index,
        );

        elapsed_ns_total = std.math.add(u64, elapsed_ns_total, child_run.elapsed_ns) catch {
            return error.Overflow;
        };
        max_rss_bytes = maxOptionalUsize(max_rss_bytes, child_run.max_rss_bytes);
    }

    return .{
        .elapsed_ns = elapsed_ns_total,
        .max_rss_bytes = max_rss_bytes,
    };
}

fn runChildOnce(
    io: std.Io,
    benchmark_case: *const ProcessBenchmarkCase,
    benchmark_config: ProcessBenchmarkConfig,
) ProcessBenchmarkError!ChildRunResult {
    const start_instant = std.time.Instant.now() catch return error.Unsupported;

    var child = std.process.spawn(io, .{
        .argv = benchmark_case.argv,
        .cwd = benchmark_case.cwd,
        .environ_map = benchmark_case.environ_map,
        .expand_arg0 = benchmark_case.expand_arg0,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .request_resource_usage_statistics = benchmark_config.request_resource_usage_statistics,
        .create_no_window = benchmark_case.create_no_window,
    }) catch |err| return mapSpawnError(err);
    errdefer child.kill(io);

    const term = if (benchmark_config.timeout_ns_max) |timeout_ns_max|
        try waitForChildWithTimeout(io, &child, timeout_ns_max)
    else
        child.wait(io) catch |err| return mapWaitError(err);

    try assertSuccessfulTerm(term);
    const stop_instant = std.time.Instant.now() catch return error.Unsupported;

    return .{
        .elapsed_ns = stop_instant.since(start_instant),
        .max_rss_bytes = child.resource_usage_statistics.getMaxRss(),
    };
}

fn waitForChildWithTimeout(
    io: std.Io,
    child: *std.process.Child,
    timeout_ns_max: u64,
) ProcessBenchmarkError!std.process.Child.Term {
    std.debug.assert(child.id != null);
    std.debug.assert(timeout_ns_max > 0);

    const child_id = child.id.?;
    var wait_state = WaitThreadState{
        .child = child,
        .io = io,
    };
    var waiter = std.Thread.spawn(.{}, WaitThreadState.waitThreadMain, .{&wait_state}) catch {
        return error.OutOfMemory;
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
) ProcessBenchmarkError!void {
    const terminate_result = terminateChildId(child_id);

    wait_state.mutex.lock();
    while (!wait_state.done) wait_state.cond.wait(&wait_state.mutex);
    terminate_result catch |err| return err;
}

fn terminateChildId(child_id: std.process.Child.Id) ProcessBenchmarkError!void {
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

fn assertSuccessfulTerm(term: std.process.Child.Term) ProcessBenchmarkError!void {
    switch (term) {
        .exited => |exit_code| {
            if (exit_code != 0) return error.ProcessFailed;
        },
        else => return error.ProcessFailed,
    }
}

fn mapSpawnError(err: std.process.SpawnError) ProcessBenchmarkError {
    return switch (err) {
        error.OperationUnsupported => error.Unsupported,
        error.OutOfMemory => error.OutOfMemory,
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

fn mapWaitError(err: std.process.Child.WaitError) ProcessBenchmarkError {
    return switch (err) {
        error.AccessDenied => error.AccessDenied,
        else => error.ProcessFailed,
    };
}

fn maxOptionalUsize(current: ?usize, candidate: ?usize) ?usize {
    if (current == null) return candidate;
    if (candidate == null) return current;
    return @max(current.?, candidate.?);
}

fn validateMeasureRunIndexSpace(benchmark: config_mod.BenchmarkConfig) ProcessBenchmarkError!void {
    std.debug.assert(benchmark.measure_iterations > 0);
    std.debug.assert(benchmark.sample_count > 0);

    const measure_runs_total = std.math.mul(u64, benchmark.sample_count, benchmark.measure_iterations) catch {
        return error.Overflow;
    };
    const run_index_limit_exclusive = @as(u64, std.math.maxInt(u32)) + 1;
    if (measure_runs_total > run_index_limit_exclusive) return error.Overflow;
}

fn measuredRunIndex(
    sample_index: u32,
    measure_iterations: u32,
    measure_index: u32,
) ProcessBenchmarkError!u32 {
    std.debug.assert(measure_iterations > 0);
    std.debug.assert(measure_index < measure_iterations);

    const run_index_base = std.math.mul(u32, sample_index, measure_iterations) catch {
        return error.Overflow;
    };
    return std.math.add(u32, run_index_base, measure_index) catch {
        return error.Overflow;
    };
}

fn assertValidArgv(argv: []const []const u8) void {
    std.debug.assert(argv.len > 0);
    for (argv) |arg| {
        std.debug.assert(arg.len > 0);
    }
}

fn successCommandArgv() []const []const u8 {
    return switch (builtin.os.tag) {
        .windows => &[_][]const u8{ "cmd.exe", "/C", "exit 0" },
        else => &[_][]const u8{ "sh", "-c", "exit 0" },
    };
}

fn timeoutCommandArgv() []const []const u8 {
    return switch (builtin.os.tag) {
        .windows => &[_][]const u8{ "cmd.exe", "/C", "ping 127.0.0.1 -n 3 >NUL" },
        else => &[_][]const u8{ "sh", "-c", "sleep 1" },
    };
}

fn failingCommandArgv() []const []const u8 {
    return switch (builtin.os.tag) {
        .windows => &[_][]const u8{ "cmd.exe", "/C", "exit 7" },
        else => &[_][]const u8{ "sh", "-c", "exit 7" },
    };
}

fn envCommandArgv() []const []const u8 {
    return switch (builtin.os.tag) {
        .windows => &[_][]const u8{ "cmd.exe", "/C", "if \"%STATIC_TESTING_PREP%\"==\"ready\" (exit 0) else (exit 7)" },
        else => &[_][]const u8{ "sh", "-c", "test \"$STATIC_TESTING_PREP\" = \"ready\"" },
    };
}

test "process benchmark config rejects invalid inputs" {
    const benchmark_case = ProcessBenchmarkCase.init(.{
        .name = "success",
        .argv = successCommandArgv(),
    });
    var samples: [1]runner.BenchmarkSample = undefined;

    try std.testing.expectError(error.InvalidConfig, runProcessBenchmark(
        std.testing.io,
        &benchmark_case,
        .{
            .benchmark = .{
                .mode = .smoke,
                .warmup_iterations = 0,
                .measure_iterations = 1,
                .sample_count = 1,
            },
            .timeout_ns_max = 0,
        },
        &samples,
    ));
}

test "runProcessBenchmark executes a trivial command and excludes warmups" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const benchmark_case = ProcessBenchmarkCase.init(.{
        .name = "success",
        .argv = successCommandArgv(),
    });
    var samples: [3]runner.BenchmarkSample = undefined;
    const result = runProcessBenchmark(
        threaded_io.io(),
        &benchmark_case,
        .{
            .benchmark = config_mod.BenchmarkConfig.smokeDefaults(),
        },
        &samples,
    ) catch |err| switch (err) {
        error.NotFound => return error.SkipZigTest,
        else => return err,
    };

    try std.testing.expectEqual(@as(usize, 3), result.samples.len);
    try std.testing.expectEqual(@as(u32, 1), result.warmup_iterations);
    try std.testing.expectEqual(
        config_mod.BenchmarkConfig.smokeDefaults().measure_iterations,
        result.measure_iterations,
    );
    try std.testing.expectEqual(
        config_mod.BenchmarkConfig.smokeDefaults().measure_iterations,
        result.samples[0].iteration_count,
    );
    try std.testing.expectEqualStrings("success", result.asCaseResult().name);
}

test "runProcessBenchmark returns timeout for a long-running command" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const benchmark_case = ProcessBenchmarkCase.init(.{
        .name = "timeout",
        .argv = timeoutCommandArgv(),
    });
    var samples: [1]runner.BenchmarkSample = undefined;

    try std.testing.expectError(error.Timeout, runProcessBenchmark(
        threaded_io.io(),
        &benchmark_case,
        .{
            .benchmark = .{
                .mode = .smoke,
                .warmup_iterations = 0,
                .measure_iterations = 1,
                .sample_count = 1,
            },
            .timeout_ns_max = 50 * std.time.ns_per_ms,
        },
        &samples,
    ));
}

test "runProcessBenchmark propagates warmup process failures" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const benchmark_case = ProcessBenchmarkCase.init(.{
        .name = "warmup_failure",
        .argv = failingCommandArgv(),
    });
    var samples: [1]runner.BenchmarkSample = undefined;

    try std.testing.expectError(error.ProcessFailed, runProcessBenchmark(
        threaded_io.io(),
        &benchmark_case,
        .{
            .benchmark = .{
                .mode = .smoke,
                .warmup_iterations = 1,
                .measure_iterations = 1,
                .sample_count = 1,
            },
        },
        &samples,
    ));
}

test "runProcessBenchmark supports env maps and prepare hooks" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();
    try environ_map.put("STATIC_TESTING_PREP", "ready");

    const PrepareContext = struct {
        warmups_total: u32 = 0,
        measures_total: u32 = 0,

        fn prepare(context_ptr: *anyopaque, phase: ProcessRunPhase, _: u32) void {
            const context: *@This() = @ptrCast(@alignCast(context_ptr));
            switch (phase) {
                .warmup => context.warmups_total += 1,
                .measure => context.measures_total += 1,
            }
        }
    };
    var prepare_context = PrepareContext{};
    const benchmark_case = ProcessBenchmarkCase.init(.{
        .name = "env_prepare",
        .argv = envCommandArgv(),
        .environ_map = &environ_map,
        .prepare_context = &prepare_context,
        .prepare_fn = PrepareContext.prepare,
    });
    var samples: [2]runner.BenchmarkSample = undefined;

    const result = runProcessBenchmark(
        threaded_io.io(),
        &benchmark_case,
        .{
            .benchmark = .{
                .mode = .smoke,
                .warmup_iterations = 1,
                .measure_iterations = 1,
                .sample_count = 2,
            },
        },
        &samples,
    ) catch |err| switch (err) {
        error.NotFound => return error.SkipZigTest,
        else => return err,
    };

    try std.testing.expectEqual(@as(u32, 1), prepare_context.warmups_total);
    try std.testing.expectEqual(@as(u32, 2), prepare_context.measures_total);
    try std.testing.expectEqual(@as(usize, 2), result.samples.len);
}

test "process benchmark defaults leave resource statistics disabled" {
    const benchmark_config = ProcessBenchmarkConfig{
        .benchmark = config_mod.BenchmarkConfig.smokeDefaults(),
    };

    try std.testing.expect(!benchmark_config.request_resource_usage_statistics);
}

test "process benchmark rejects prepare-hook configs whose measured run indexes overflow u32" {
    var prepare_context: u8 = 0;
    const PrepareContext = struct {
        fn prepare(_: *anyopaque, _: ProcessRunPhase, _: u32) void {}
    };
    const benchmark_case = ProcessBenchmarkCase.init(.{
        .name = "overflow_prepare",
        .argv = successCommandArgv(),
        .prepare_context = &prepare_context,
        .prepare_fn = PrepareContext.prepare,
    });
    var samples: [2]runner.BenchmarkSample = undefined;

    try std.testing.expectError(error.Overflow, runProcessBenchmark(
        std.testing.io,
        &benchmark_case,
        .{
            .benchmark = .{
                .mode = .full,
                .warmup_iterations = 0,
                .measure_iterations = std.math.maxInt(u32),
                .sample_count = 2,
            },
        },
        &samples,
    ));
}
