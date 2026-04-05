//! Pool alloc/free cycle time benchmark.
//!
//! Measures the cost of a single allocBlock+freeBlock round-trip on the
//! fixed-size block Pool. The pool is pre-warmed by filling and draining it
//! once before timing, so the first-access cache-cold penalty does not skew
//! the steady-state result.
//!
//! Run via `zig build bench` from the workspace root.

const std = @import("std");
const assert = std.debug.assert;
const static_memory = @import("static_memory");
const static_testing = @import("static_testing");
const support = @import("support.zig");

const cycles_count: u64 = 2_097_152;
// Block size and pool capacity chosen to fit within a typical L2 cache,
// giving a stable hot-path measurement rather than a memory-bandwidth number.
const block_size: u32 = 64;
const block_align: u32 = 8;
const pool_capacity: u32 = 1024;
const bench = static_testing.bench;
const PreflightError = error{
    PoolExhaustionContractViolation,
    PoolAvailabilityContractViolation,
};

const bench_config = bench.config.BenchmarkConfig{
    .mode = .full,
    .warmup_iterations = 64,
    .measure_iterations = cycles_count,
    .sample_count = 16,
};

const PoolContext = struct {
    pool: *static_memory.pool.Pool,
    sink: usize = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *PoolContext = @ptrCast(@alignCast(context_ptr));
        assert(context.pool.total() == pool_capacity);

        const block = context.pool.allocBlock() catch unreachable;
        context.pool.freeBlock(block) catch unreachable;
        context.sink = bench.case.blackBox(block.len);
        assert(context.sink == block_size);
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try validateSemanticPreflight(allocator);

    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    var output_dir = try support.openOutputDir(io, "pool_alloc_free");
    defer output_dir.close(io);

    var pool: static_memory.pool.Pool = undefined;
    try static_memory.pool.Pool.init(
        &pool,
        allocator,
        block_size,
        block_align,
        pool_capacity,
    );
    defer pool.deinit();

    var context = PoolContext{ .pool = &pool };
    var case_storage: [1]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_memory_pool_alloc_free",
        .config = bench_config,
    });
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "alloc_free_cycle",
        .tags = &[_][]const u8{ "static_memory", "pool", "baseline" },
        .context = &context,
        .run_fn = PoolContext.run,
    }));

    var sample_storage: [bench_config.sample_count]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [1]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(
        &group,
        &sample_storage,
        &case_result_storage,
    );

    var stats_storage: [1]bench.stats.BenchmarkStats = undefined;
    var baseline_document_buffer: [1024]u8 = undefined;
    var read_source_buffer: [1024]u8 = undefined;
    var read_parse_buffer: [4096]u8 = undefined;
    var comparisons: [2]bench.baseline.BaselineCaseComparison = undefined;
    var history_existing_buffer: [4096]u8 = undefined;
    var history_record_buffer: [2048]u8 = undefined;
    var history_frame_buffer: [2048]u8 = undefined;
    var history_output_buffer: [4096]u8 = undefined;
    var history_file_buffer: [4096]u8 = undefined;
    var history_cases: [1]bench.stats.BenchmarkStats = undefined;
    var history_name_buffer: [256]u8 = undefined;
    var history_tags: [4][]const u8 = undefined;
    var history_comparisons: [2]bench.baseline.BaselineCaseComparison = undefined;
    var report_writer: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer report_writer.deinit();

    _ = try bench.workflow.writeTextAndOptionalBaselineReport(&report_writer.writer, run_result, .{
        .io = io,
        .dir = output_dir,
        .sub_path = "baseline.zon",
        .mode = .record_if_missing_then_compare,
        .compare_config = support.default_compare_config,
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
            .package_name = "static_memory",
            .environment_note = support.default_environment_note,
            .append_buffers = .{
                .existing_file_buffer = &history_existing_buffer,
                .record_buffer = &history_record_buffer,
                .frame_buffer = &history_frame_buffer,
                .output_file_buffer = &history_output_buffer,
            },
            .read_buffers = .{
                .file_buffer = &history_file_buffer,
                .case_storage = &history_cases,
                .string_buffer = &history_name_buffer,
                .tag_storage = &history_tags,
            },
            .comparison_storage = &history_comparisons,
        },
    });

    var report = report_writer.toArrayList();
    defer report.deinit(std.heap.page_allocator);
    std.debug.print("{s}", .{report.items});
}

fn validateSemanticPreflight(allocator: std.mem.Allocator) PreflightError!void {
    var pool: static_memory.pool.Pool = undefined;
    static_memory.pool.Pool.init(
        &pool,
        allocator,
        block_size,
        block_align,
        pool_capacity,
    ) catch unreachable;
    defer pool.deinit();

    var handles: [pool_capacity][]u8 = undefined;
    var count: u32 = 0;
    while (count < pool_capacity) : (count += 1) {
        handles[count] = pool.allocBlock() catch unreachable;
    }
    const exhausted = pool.allocBlock();
    if (exhausted) |_| {
        return error.PoolExhaustionContractViolation;
    } else |err| {
        assert(err == error.NoSpaceLeft);
    }
    var free_idx: u32 = 0;
    while (free_idx < count) : (free_idx += 1) {
        pool.freeBlock(handles[free_idx]) catch unreachable;
    }
    if (pool.available() != pool_capacity) return error.PoolAvailabilityContractViolation;
}
