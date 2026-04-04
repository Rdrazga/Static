//! Demonstrates a minimal in-process benchmark group and text export.

const std = @import("std");
const testing = @import("static_testing");

pub fn main() !void {
    var counter: u64 = 0;
    const Context = struct {
        fn run(ctx: *anyopaque) void {
            const value: *u64 = @ptrCast(@alignCast(ctx));
            value.* += 1;
            _ = testing.bench.case.blackBox(value.*);
        }
    };

    const benchmark_case = testing.bench.case.BenchmarkCase.init(.{
        .name = "increment",
        .tags = &[_][]const u8{"smoke"},
        .context = &counter,
        .run_fn = Context.run,
    });

    var group_storage: [1]testing.bench.case.BenchmarkCase = undefined;
    var benchmark_group = try testing.bench.group.BenchmarkGroup.init(&group_storage, .{
        .name = "bench_smoke",
        .config = testing.bench.config.BenchmarkConfig.smokeDefaults(),
    });
    try benchmark_group.addCase(benchmark_case);

    var sample_storage: [3]testing.bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [1]testing.bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try testing.bench.runner.runGroup(
        &benchmark_group,
        &sample_storage,
        &case_result_storage,
    );

    var aw: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    try testing.bench.exports.writeText(&aw.writer, run_result);

    var out = aw.toArrayList();
    defer out.deinit(std.heap.page_allocator);
    std.debug.print("{s}", .{out.items});
}
