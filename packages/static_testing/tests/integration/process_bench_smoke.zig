const builtin = @import("builtin");
const std = @import("std");
const testing = @import("static_testing");

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

test "process benchmark smoke runs across a real child-process boundary" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const benchmark_case = testing.bench.process.ProcessBenchmarkCase.init(.{
        .name = "process_smoke",
        .argv = successCommandArgv(),
    });
    var samples: [3]testing.bench.runner.BenchmarkSample = undefined;
    const result = testing.bench.process.runProcessBenchmark(
        threaded_io.io(),
        &benchmark_case,
        .{
            .benchmark = testing.bench.config.BenchmarkConfig.smokeDefaults(),
        },
        &samples,
    ) catch |err| switch (err) {
        error.NotFound => return error.SkipZigTest,
        else => return err,
    };

    const case_result = result.asCaseResult();
    const derived = try testing.bench.stats.computeStats(case_result);

    try std.testing.expectEqualStrings("process_smoke", case_result.name);
    try std.testing.expectEqual(@as(usize, 3), case_result.samples.len);
    try std.testing.expectEqual(@as(u32, 3), derived.sample_count);
    try std.testing.expect(derived.max_elapsed_ns >= derived.min_elapsed_ns);
}

test "process benchmark resource statistics stay opt-in across integration runs" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const benchmark_case = testing.bench.process.ProcessBenchmarkCase.init(.{
        .name = "process_rss",
        .argv = successCommandArgv(),
    });
    var disabled_samples: [1]testing.bench.runner.BenchmarkSample = undefined;
    var enabled_samples: [1]testing.bench.runner.BenchmarkSample = undefined;

    const disabled = testing.bench.process.runProcessBenchmark(
        threaded_io.io(),
        &benchmark_case,
        .{
            .benchmark = .{
                .mode = .smoke,
                .warmup_iterations = 0,
                .measure_iterations = 1,
                .sample_count = 1,
            },
            .request_resource_usage_statistics = false,
        },
        &disabled_samples,
    ) catch |err| switch (err) {
        error.NotFound => return error.SkipZigTest,
        else => return err,
    };
    const enabled = testing.bench.process.runProcessBenchmark(
        threaded_io.io(),
        &benchmark_case,
        .{
            .benchmark = .{
                .mode = .smoke,
                .warmup_iterations = 0,
                .measure_iterations = 1,
                .sample_count = 1,
            },
            .request_resource_usage_statistics = true,
        },
        &enabled_samples,
    ) catch |err| switch (err) {
        error.NotFound => return error.SkipZigTest,
        else => return err,
    };

    try std.testing.expect(disabled.max_rss_bytes_max == null);
    if (enabled.max_rss_bytes_max) |rss_bytes| {
        try std.testing.expect(rss_bytes > 0);
    }
}

test "process benchmark propagates integration timeouts" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const benchmark_case = testing.bench.process.ProcessBenchmarkCase.init(.{
        .name = "process_timeout",
        .argv = timeoutCommandArgv(),
    });
    var samples: [1]testing.bench.runner.BenchmarkSample = undefined;

    try std.testing.expectError(error.Timeout, testing.bench.process.runProcessBenchmark(
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
