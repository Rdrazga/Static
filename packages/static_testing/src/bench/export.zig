//! Human- and machine-readable export helpers for raw benchmark results.

const std = @import("std");
const profile = @import("static_profile");
const runner = @import("runner.zig");
const stats = @import("stats.zig");

/// Supported benchmark export encodings.
pub const ExportFormat = enum(u8) {
    text = 1,
    json = 2,
    csv = 3,
    markdown = 4,
};

pub const TextReportConfig = struct {
    include_samples: bool = true,
    include_derived_summary: bool = true,
};

/// Write a stable plain-text summary for one benchmark run.
pub fn writeText(writer: *std.Io.Writer, result: runner.BenchmarkRunResult) !void {
    return writeTextWithConfig(writer, result, .{});
}

/// Write a stable plain-text summary with a small report-config surface.
pub fn writeTextWithConfig(
    writer: *std.Io.Writer,
    result: runner.BenchmarkRunResult,
    report_config: TextReportConfig,
) !void {
    try writer.print("mode: {s}\n", .{@tagName(result.mode)});
    for (result.case_results) |case_result| {
        try writer.print(
            "case {s} total_elapsed_ns={} samples={}\n",
            .{ case_result.name, case_result.total_elapsed_ns, case_result.samples.len },
        );
        if (report_config.include_samples) {
            for (case_result.samples, 0..) |sample, sample_index| {
                try writer.print(
                    "  sample {} elapsed_ns={} iteration_count={}\n",
                    .{ sample_index, sample.elapsed_ns, sample.iteration_count },
                );
            }
        }
        if (report_config.include_derived_summary) {
            const derived = try stats.computeStats(case_result);
            try writeDerivedSummary(writer, case_result, derived);
        }
    }
}

/// Write a stable JSON object for one benchmark run.
pub fn writeJson(writer: *std.Io.Writer, result: runner.BenchmarkRunResult) !void {
    try writer.writeAll("{\"mode\":");
    try profile.trace.writeJsonString(writer, @tagName(result.mode));
    try writer.writeAll(",\"cases\":[");
    for (result.case_results, 0..) |case_result, case_index| {
        if (case_index != 0) try writer.writeAll(",");
        try writeJsonCase(writer, case_result);
    }
    try writer.writeAll("]}");
}

/// Write one CSV row per recorded benchmark sample.
pub fn writeCsv(writer: *std.Io.Writer, result: runner.BenchmarkRunResult) !void {
    try writer.writeAll("case_name,sample_index,iteration_count,elapsed_ns\n");
    for (result.case_results) |case_result| {
        for (case_result.samples, 0..) |sample, sample_index| {
            try writeCsvField(writer, case_result.name);
            try writer.print(",{},{},{}\n", .{
                sample_index,
                sample.iteration_count,
                sample.elapsed_ns,
            });
        }
    }
}

/// Write a Markdown table with one row per recorded benchmark sample.
pub fn writeMarkdown(writer: *std.Io.Writer, result: runner.BenchmarkRunResult) !void {
    try writer.writeAll("| case | sample | iteration_count | elapsed_ns |\n");
    try writer.writeAll("| --- | ---: | ---: | ---: |\n");
    for (result.case_results) |case_result| {
        for (case_result.samples, 0..) |sample, sample_index| {
            try writer.writeAll("| ");
            try writeMarkdownCell(writer, case_result.name);
            try writer.print(" | {} | {} | {} |\n", .{
                sample_index,
                sample.iteration_count,
                sample.elapsed_ns,
            });
        }
    }
}

fn writeCsvField(writer: *std.Io.Writer, text: []const u8) !void {
    if (!csvFieldNeedsQuotes(text)) {
        try writer.writeAll(text);
        return;
    }

    try writer.writeByte('"');
    for (text) |byte| {
        if (byte == '"') {
            try writer.writeAll("\"\"");
        } else {
            try writer.writeByte(byte);
        }
    }
    try writer.writeByte('"');
}

fn csvFieldNeedsQuotes(text: []const u8) bool {
    for (text) |byte| {
        if (byte == ',' or byte == '"' or byte == '\n' or byte == '\r') return true;
    }
    return false;
}

fn writeMarkdownCell(writer: *std.Io.Writer, text: []const u8) !void {
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        const byte = text[index];
        if (byte == '\r') {
            if (index + 1 < text.len and text[index + 1] == '\n') {
                index += 1;
            }
            try writer.writeAll("<br>");
        } else if (byte == '\n') {
            try writer.writeAll("<br>");
        } else if (byte == '\\' or byte == '|') {
            try writer.writeByte('\\');
            try writer.writeByte(byte);
        } else {
            try writer.writeByte(byte);
        }
    }
}

fn writeJsonCase(writer: *std.Io.Writer, case_result: runner.BenchmarkCaseResult) !void {
    try writer.writeAll("{\"name\":");
    try profile.trace.writeJsonString(writer, case_result.name);
    try writer.writeAll(",\"warmup_iterations\":");
    try writer.print("{}", .{case_result.warmup_iterations});
    try writer.writeAll(",\"measure_iterations\":");
    try writer.print("{}", .{case_result.measure_iterations});
    try writer.writeAll(",\"total_elapsed_ns\":");
    try writer.print("{}", .{case_result.total_elapsed_ns});
    try writer.writeAll(",\"samples\":[");
    for (case_result.samples, 0..) |sample, sample_index| {
        if (sample_index != 0) try writer.writeAll(",");
        try writer.print(
            "{{\"elapsed_ns\":{},\"iteration_count\":{}}}",
            .{ sample.elapsed_ns, sample.iteration_count },
        );
    }
    try writer.writeAll("]}");
}

fn writeDerivedSummary(
    writer: *std.Io.Writer,
    case_result: runner.BenchmarkCaseResult,
    derived: stats.BenchmarkStats,
) !void {
    std.debug.assert(case_result.measure_iterations != 0);

    const iteration_count = case_result.measure_iterations;
    const mean_ns_per_op = nsPerOp(derived.mean_elapsed_ns, iteration_count);
    const median_ns_per_op = nsPerOp(derived.median_elapsed_ns, iteration_count);
    const p95_ns_per_op = nsPerOp(derived.p95_elapsed_ns, iteration_count);
    const p99_ns_per_op = nsPerOp(derived.p99_elapsed_ns orelse derived.p95_elapsed_ns, iteration_count);
    const median_ops_per_s = opsPerSecond(derived.median_elapsed_ns, iteration_count);

    try writer.print(
        "  derived mean_ns_per_op={d:.3} median_ns_per_op={d:.3} median_ops_per_s={} p95_ns_per_op={d:.3} p99_ns_per_op={d:.3}\n",
        .{
            mean_ns_per_op,
            median_ns_per_op,
            median_ops_per_s,
            p95_ns_per_op,
            p99_ns_per_op,
        },
    );
}

fn nsPerOp(elapsed_ns: u64, iteration_count: u32) f64 {
    std.debug.assert(iteration_count != 0);
    return @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iteration_count));
}

fn opsPerSecond(elapsed_ns: u64, iteration_count: u32) u64 {
    if (elapsed_ns == 0) return std.math.maxInt(u64);

    const numerator = std.math.mul(u128, std.time.ns_per_s, iteration_count) catch unreachable;
    const quotient = @divFloor(numerator, elapsed_ns);
    return std.math.cast(u64, quotient) orelse std.math.maxInt(u64);
}

test "text export prints samples and derived summary lines" {
    const samples = [_]runner.BenchmarkSample{
        .{ .elapsed_ns = 10, .iteration_count = 3 },
        .{ .elapsed_ns = 20, .iteration_count = 3 },
    };
    const case_results = [_]runner.BenchmarkCaseResult{
        .{
            .name = "alpha",
            .warmup_iterations = 1,
            .measure_iterations = 3,
            .samples = &samples,
            .total_elapsed_ns = 30,
        },
    };
    const result = runner.BenchmarkRunResult{
        .mode = .smoke,
        .case_results = &case_results,
    };

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    try writeText(&aw.writer, result);
    var out = aw.toArrayList();
    defer out.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "mode: smoke\ncase alpha total_elapsed_ns=30 samples=2\n  sample 0 elapsed_ns=10 iteration_count=3\n  sample 1 elapsed_ns=20 iteration_count=3\n  derived mean_ns_per_op=5.000 median_ns_per_op=3.333 median_ops_per_s=300000000 p95_ns_per_op=6.667 p99_ns_per_op=6.667\n",
        out.items,
    );
}

test "text export config can suppress raw samples while keeping derived summary" {
    const samples = [_]runner.BenchmarkSample{
        .{ .elapsed_ns = 10, .iteration_count = 2 },
        .{ .elapsed_ns = 14, .iteration_count = 2 },
    };
    const case_results = [_]runner.BenchmarkCaseResult{
        .{
            .name = "beta",
            .warmup_iterations = 0,
            .measure_iterations = 2,
            .samples = &samples,
            .total_elapsed_ns = 24,
        },
    };
    const result = runner.BenchmarkRunResult{
        .mode = .full,
        .case_results = &case_results,
    };

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    try writeTextWithConfig(&aw.writer, result, .{ .include_samples = false });
    var out = aw.toArrayList();
    defer out.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "mode: full\ncase beta total_elapsed_ns=24 samples=2\n  derived mean_ns_per_op=6.000 median_ns_per_op=5.000 median_ops_per_s=200000000 p95_ns_per_op=7.000 p99_ns_per_op=7.000\n",
        out.items,
    );
}

test "json export uses stable field order" {
    // Method: Use a quoted case name so the assertion covers stable field order
    // and JSON string escaping in one round-trip.
    const samples = [_]runner.BenchmarkSample{
        .{ .elapsed_ns = 10, .iteration_count = 2 },
    };
    const case_results = [_]runner.BenchmarkCaseResult{
        .{
            .name = "case\"one",
            .warmup_iterations = 0,
            .measure_iterations = 2,
            .samples = &samples,
            .total_elapsed_ns = 10,
        },
    };
    const result = runner.BenchmarkRunResult{
        .mode = .full,
        .case_results = &case_results,
    };

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    try writeJson(&aw.writer, result);
    var out = aw.toArrayList();
    defer out.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "{\"mode\":\"full\",\"cases\":[{\"name\":\"case\\\"one\",\"warmup_iterations\":0,\"measure_iterations\":2,\"total_elapsed_ns\":10,\"samples\":[{\"elapsed_ns\":10,\"iteration_count\":2}]}]}",
        out.items,
    );
}

test "csv and markdown export handle empty case lists" {
    const empty_results = [_]runner.BenchmarkCaseResult{};
    const result = runner.BenchmarkRunResult{
        .mode = .smoke,
        .case_results = &empty_results,
    };

    var csv_aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    try writeCsv(&csv_aw.writer, result);
    var csv_out = csv_aw.toArrayList();
    defer csv_out.deinit(std.testing.allocator);

    var md_aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    try writeMarkdown(&md_aw.writer, result);
    var md_out = md_aw.toArrayList();
    defer md_out.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("case_name,sample_index,iteration_count,elapsed_ns\n", csv_out.items);
    try std.testing.expectEqualStrings(
        "| case | sample | iteration_count | elapsed_ns |\n| --- | ---: | ---: | ---: |\n",
        md_out.items,
    );
}

test "csv export quotes case names with commas quotes and newlines" {
    const samples = [_]runner.BenchmarkSample{
        .{ .elapsed_ns = 10, .iteration_count = 1 },
    };
    const case_results = [_]runner.BenchmarkCaseResult{
        .{
            .name = "case,\"quoted\"\nnext",
            .warmup_iterations = 0,
            .measure_iterations = 1,
            .samples = &samples,
            .total_elapsed_ns = 10,
        },
    };
    const result = runner.BenchmarkRunResult{
        .mode = .smoke,
        .case_results = &case_results,
    };

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    try writeCsv(&aw.writer, result);
    var out = aw.toArrayList();
    defer out.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "case_name,sample_index,iteration_count,elapsed_ns\n\"case,\"\"quoted\"\"\nnext\",0,1,10\n",
        out.items,
    );
}

test "markdown export escapes pipes and normalizes embedded newlines" {
    const samples = [_]runner.BenchmarkSample{
        .{ .elapsed_ns = 12, .iteration_count = 2 },
    };
    const case_results = [_]runner.BenchmarkCaseResult{
        .{
            .name = "left|right\r\nnext\\tail",
            .warmup_iterations = 0,
            .measure_iterations = 2,
            .samples = &samples,
            .total_elapsed_ns = 12,
        },
    };
    const result = runner.BenchmarkRunResult{
        .mode = .smoke,
        .case_results = &case_results,
    };

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    try writeMarkdown(&aw.writer, result);
    var out = aw.toArrayList();
    defer out.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "| case | sample | iteration_count | elapsed_ns |\n| --- | ---: | ---: | ---: |\n| left\\|right<br>next\\\\tail | 0 | 2 | 12 |\n",
        out.items,
    );
}
