const builtin = @import("builtin");
const std = @import("std");
const static_net_native = @import("static_net_native");
const static_testing = @import("static_testing");

const bench = static_testing.bench;
pub const Endpoint = static_net_native.Endpoint;

pub const default_compare_config: bench.baseline.BaselineCompareConfig = .{
    .thresholds = .{
        .median_ratio_ppm = 300_000,
        .p95_ratio_ppm = 400_000,
        .p99_ratio_ppm = 500_000,
    },
};

pub const default_environment_note =
    std.fmt.comptimePrint("os={s},arch={s},adapter={s}", .{
        @tagName(builtin.os.tag),
        @tagName(builtin.cpu.arch),
        switch (builtin.os.tag) {
            .windows => "windows",
            .linux => "linux",
            else => "posix",
        },
    });

pub fn buildIpv4Endpoint(seed_value: u64) Endpoint {
    var octets: [4]u8 = .{
        @truncate(seed_value | 1),
        @truncate(seed_value >> 8),
        @truncate(seed_value >> 16),
        @truncate(seed_value >> 24),
    };
    if (octets[0] == 0) octets[0] = 1;
    return .{ .ipv4 = .{
        .address = .{ .octets = octets },
        .port = 1024 + @as(u16, @intCast(seed_value % 50_000)),
    } };
}

pub fn buildIpv6Endpoint(seed_value: u64) Endpoint {
    var segments: [8]u16 = [_]u16{0} ** 8;
    var index: usize = 0;
    while (index < segments.len) : (index += 1) {
        const shift: u6 = @intCast((index % 4) * 16);
        const lane_seed = (seed_value >> shift) ^ (seed_value *% (index + 1));
        segments[index] = @truncate(lane_seed | 1);
    }
    return .{ .ipv6 = .{
        .address = .{ .segments = segments },
        .port = 1024 + @as(u16, @intCast((seed_value >> 7) % 50_000)),
    } };
}

pub fn digestEndpoint(endpoint: Endpoint) u64 {
    return switch (endpoint) {
        .ipv4 => |ipv4| blk: {
            var digest = foldDigest(0x4950_7634, ipv4.port);
            for (ipv4.address.octets) |octet| {
                digest = foldDigest(digest, octet);
            }
            break :blk digest;
        },
        .ipv6 => |ipv6| blk: {
            var digest = foldDigest(0x4950_7636, ipv6.port);
            for (ipv6.address.segments) |segment| {
                digest = foldDigest(digest, segment);
            }
            break :blk digest;
        },
    };
}

pub fn foldDigest(left: u64, right: u64) u64 {
    return mix64(left ^ (right +% 0x9e37_79b9_7f4a_7c15));
}

fn mix64(value: u64) u64 {
    var mixed = value ^ (value >> 33);
    mixed *%= 0xff51_afd7_ed55_8ccd;
    mixed ^= mixed >> 33;
    mixed *%= 0xc4ce_b9fe_1a85_ec53;
    mixed ^= mixed >> 33;
    return mixed;
}

pub fn openOutputDir(
    io: std.Io,
    benchmark_name: []const u8,
) !std.Io.Dir {
    const cwd = std.Io.Dir.cwd();
    var path_buffer: [192]u8 = undefined;
    const output_dir_path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/static_net_native/benchmarks/{s}",
        .{benchmark_name},
    );
    return cwd.createDirPathOpen(io, output_dir_path, .{});
}

pub fn writeGroupReport(
    run_result: bench.runner.BenchmarkRunResult,
    io: std.Io,
    output_dir: std.Io.Dir,
    environment_note: []const u8,
) !void {
    var stats_storage: [2]bench.stats.BenchmarkStats = undefined;
    var baseline_document_buffer: [2048]u8 = undefined;
    var read_source_buffer: [2048]u8 = undefined;
    var read_parse_buffer: [4096]u8 = undefined;
    var comparisons: [4]bench.baseline.BaselineCaseComparison = undefined;
    var history_existing_buffer: [8192]u8 = undefined;
    var history_record_buffer: [4096]u8 = undefined;
    var history_frame_buffer: [4096]u8 = undefined;
    var history_output_buffer: [8192]u8 = undefined;
    var history_file_buffer: [8192]u8 = undefined;
    var history_cases: [2]bench.stats.BenchmarkStats = undefined;
    var history_names: [256]u8 = undefined;
    var history_tags: [4][]const u8 = undefined;
    var history_comparisons: [4]bench.baseline.BaselineCaseComparison = undefined;
    var aw: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    _ = try bench.workflow.writeTextAndOptionalBaselineReport(&aw.writer, run_result, .{
        .io = io,
        .dir = output_dir,
        .sub_path = "baseline.zon",
        .mode = .record_if_missing_then_compare,
        .compare_config = default_compare_config,
        .enforce_gate = false,
        .stats_storage = &stats_storage,
        .baseline_document_buffer = &baseline_document_buffer,
        .read_buffers = .{
            .source_buffer = &read_source_buffer,
            .parse_buffer = &read_parse_buffer,
        },
        .comparison_storage = &comparisons,
        .history = .{
            .sub_path = "history.binlog",
            .package_name = "static_net_native",
            .environment_note = environment_note,
            .append_buffers = .{
                .existing_file_buffer = &history_existing_buffer,
                .record_buffer = &history_record_buffer,
                .frame_buffer = &history_frame_buffer,
                .output_file_buffer = &history_output_buffer,
            },
            .read_buffers = .{
                .file_buffer = &history_file_buffer,
                .case_storage = &history_cases,
                .string_buffer = &history_names,
                .tag_storage = &history_tags,
            },
            .comparison_storage = &history_comparisons,
        },
    });
    var out = aw.toArrayList();
    defer out.deinit(std.heap.page_allocator);
    std.debug.print("{s}", .{out.items});
}
