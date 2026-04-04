const builtin = @import("builtin");
const std = @import("std");
const static_testing = @import("static_testing");

pub const bench = static_testing.bench;

pub const default_benchmark_config: bench.config.BenchmarkConfig = .{
    .mode = .full,
    .warmup_iterations = 16,
    .measure_iterations = 512,
    .sample_count = 8,
};

pub const default_compare_config: bench.baseline.BaselineCompareConfig = .{
    .thresholds = .{
        .median_ratio_ppm = 300_000,
        .p95_ratio_ppm = 400_000,
        .p99_ratio_ppm = 500_000,
    },
};

pub const default_environment_note =
    std.fmt.comptimePrint("os={s},arch={s}", .{
        @tagName(builtin.os.tag),
        @tagName(builtin.cpu.arch),
    });

pub fn openOutputDir(io: std.Io, benchmark_name: []const u8) !std.Io.Dir {
    const cwd = std.Io.Dir.cwd();
    var path_buffer: [192]u8 = undefined;
    const output_dir_path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/static_spatial/benchmarks/{s}",
        .{benchmark_name},
    );
    return cwd.createDirPathOpen(io, output_dir_path, .{});
}
