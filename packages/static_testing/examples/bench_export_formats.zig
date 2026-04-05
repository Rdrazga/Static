//! Demonstrates JSON, CSV, and Markdown export for one benchmark run result.

const std = @import("std");
const assert = std.debug.assert;
const testing = @import("static_testing");

pub fn main() !void {
    const samples = [_]testing.bench.runner.BenchmarkSample{
        .{ .elapsed_ns = 100, .iteration_count = 4 },
        .{ .elapsed_ns = 120, .iteration_count = 4 },
    };
    const case_results = [_]testing.bench.runner.BenchmarkCaseResult{
        .{
            .name = "export_case",
            .warmup_iterations = 1,
            .measure_iterations = 4,
            .samples = &samples,
            .total_elapsed_ns = 220,
        },
    };
    const run_result = testing.bench.runner.BenchmarkRunResult{
        .mode = .smoke,
        .case_results = &case_results,
    };

    var json = try renderFormat(testing.bench.exports.writeJson, run_result);
    defer json.deinit(std.heap.page_allocator);
    var csv = try renderFormat(testing.bench.exports.writeCsv, run_result);
    defer csv.deinit(std.heap.page_allocator);
    var markdown = try renderFormat(testing.bench.exports.writeMarkdown, run_result);
    defer markdown.deinit(std.heap.page_allocator);

    assert(std.mem.eql(
        u8,
        json.items,
        "{\"mode\":\"smoke\",\"cases\":[{\"name\":\"export_case\",\"warmup_iterations\":1,\"measure_iterations\":4,\"total_elapsed_ns\":220,\"samples\":[{\"elapsed_ns\":100,\"iteration_count\":4},{\"elapsed_ns\":120,\"iteration_count\":4}]}]}",
    ));
    assert(std.mem.eql(
        u8,
        csv.items,
        "case_name,sample_index,iteration_count,elapsed_ns\nexport_case,0,4,100\nexport_case,1,4,120\n",
    ));
    assert(std.mem.eql(
        u8,
        markdown.items,
        "| case | sample | iteration_count | elapsed_ns |\n| --- | ---: | ---: | ---: |\n| export_case | 0 | 4 | 100 |\n| export_case | 1 | 4 | 120 |\n",
    ));

    std.debug.print("{s}\n{s}\n{s}", .{ json.items, csv.items, markdown.items });
}

fn renderFormat(
    comptime writeFn: fn (*std.Io.Writer, testing.bench.runner.BenchmarkRunResult) anyerror!void,
    run_result: testing.bench.runner.BenchmarkRunResult,
) !std.ArrayList(u8) {
    var aw: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    try writeFn(&aw.writer, run_result);
    return aw.toArrayList();
}
