//! Demonstrates a child-process benchmark and derived statistics.

const builtin = @import("builtin");
const std = @import("std");
const testing = @import("static_testing");

pub fn main() !void {
    if (builtin.os.tag == .wasi) return;

    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const benchmark_case = testing.bench.process.ProcessBenchmarkCase.init(.{
        .name = "process_smoke",
        .argv = successCommandArgv(),
    });
    var sample_storage: [3]testing.bench.runner.BenchmarkSample = undefined;
    const result = try testing.bench.process.runProcessBenchmark(
        threaded_io.io(),
        &benchmark_case,
        .{
            .benchmark = testing.bench.config.BenchmarkConfig.smokeDefaults(),
        },
        &sample_storage,
    );
    const stats = try testing.bench.stats.computeStats(result.asCaseResult());

    std.debug.print(
        "process case={s} samples={} median_elapsed_ns={}\n",
        .{ stats.case_name, stats.sample_count, stats.median_elapsed_ns },
    );
}

fn successCommandArgv() []const []const u8 {
    return switch (builtin.os.tag) {
        .windows => &[_][]const u8{ "cmd.exe", "/C", "exit 0" },
        else => &[_][]const u8{ "sh", "-c", "exit 0" },
    };
}
