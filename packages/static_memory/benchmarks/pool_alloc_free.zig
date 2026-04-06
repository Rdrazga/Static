//! Pool and slab alloc/free cycle time benchmark.
//!
//! Measures the cost of a single allocBlock+freeBlock round-trip on the
//! fixed-size block Pool and two slab cases: a bounded class-routing cycle and
//! a large-allocation fallback cycle. Each allocator is pre-warmed before
//! timing so the first-access cache-cold penalty does not skew the steady-state
//! result.
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
const slab_class_sizes = [_]u32{ 16, 32, 64, 128, 256, 512, 1024, 2048 };
const slab_class_counts = [_]u32{ 64, 64, 64, 64, 64, 64, 64, 64 };
const slab_route_alloc_len: u32 = 1536;
const slab_route_alignment: u32 = 16;
const slab_fallback_alloc_len: u32 = 3072;
const slab_fallback_alignment: u32 = 32;
const case_count = 3;
const bench = static_testing.bench;
const PreflightError = error{
    PoolExhaustionContractViolation,
    PoolAvailabilityContractViolation,
    SlabRoutingContractViolation,
    SlabFallbackContractViolation,
    SlabUnsupportedSizeContractViolation,
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
        const block = context.pool.allocBlock() catch unreachable;
        context.pool.freeBlock(block) catch unreachable;
        context.sink = bench.case.blackBox(block.len);
        assert(context.sink == block_size);
    }
};

const SlabContext = struct {
    slab: *static_memory.slab.Slab,
    alloc_len: u32,
    alignment: u32,
    expected_len: usize,
    sink: usize = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *SlabContext = @ptrCast(@alignCast(context_ptr));
        const block = context.slab.alloc(context.alloc_len, context.alignment) catch unreachable;
        context.slab.free(block, context.alignment) catch unreachable;
        context.sink = bench.case.blackBox(block.len);
        assert(context.sink == context.expected_len);
    }
};

fn validatePoolSemanticPreflight(allocator: std.mem.Allocator) PreflightError!void {
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

fn validateSlabSemanticPreflight(allocator: std.mem.Allocator) PreflightError!void {
    var slab = static_memory.slab.Slab.init(allocator, .{
        .class_sizes = &slab_class_sizes,
        .class_counts = &slab_class_counts,
        .allow_large_fallback = false,
    }) catch unreachable;
    defer slab.deinit();

    const small = slab.alloc(8, 8) catch unreachable;
    const middle = slab.alloc(40, 16) catch unreachable;
    const large = slab.alloc(600, 32) catch unreachable;
    const route_report = slab.report();
    if (route_report.used != @as(u64, 1104)) return error.SlabRoutingContractViolation;

    slab.free(middle, 16) catch unreachable;
    slab.free(small, 8) catch unreachable;
    slab.free(large, 32) catch unreachable;
    if (slab.report().used != 0) return error.SlabRoutingContractViolation;

    const unsupported_block: ?[]u8 = slab.alloc(slab_fallback_alloc_len, slab_fallback_alignment) catch |err| switch (err) {
        error.UnsupportedSize => null,
        else => return error.SlabUnsupportedSizeContractViolation,
    };
    if (unsupported_block != null) {
        return error.SlabUnsupportedSizeContractViolation;
    }

    var fallback_slab = static_memory.slab.Slab.init(allocator, .{
        .class_sizes = &slab_class_sizes,
        .class_counts = &slab_class_counts,
        .allow_large_fallback = true,
    }) catch unreachable;
    defer fallback_slab.deinit();

    const fallback = fallback_slab.alloc(slab_fallback_alloc_len, slab_fallback_alignment) catch unreachable;
    fallback_slab.free(fallback, slab_fallback_alignment) catch unreachable;
    if (fallback_slab.report().used != 0) return error.SlabFallbackContractViolation;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try validatePoolSemanticPreflight(allocator);
    try validateSlabSemanticPreflight(allocator);

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

    var route_slab = try static_memory.slab.Slab.init(allocator, .{
        .class_sizes = &slab_class_sizes,
        .class_counts = &slab_class_counts,
        .allow_large_fallback = false,
    });
    defer route_slab.deinit();

    var fallback_slab = try static_memory.slab.Slab.init(allocator, .{
        .class_sizes = &slab_class_sizes,
        .class_counts = &slab_class_counts,
        .allow_large_fallback = true,
    });
    defer fallback_slab.deinit();

    var pool_context = PoolContext{ .pool = &pool };
    var slab_route_context = SlabContext{
        .slab = &route_slab,
        .alloc_len = slab_route_alloc_len,
        .alignment = slab_route_alignment,
        .expected_len = slab_route_alloc_len,
    };
    var slab_fallback_context = SlabContext{
        .slab = &fallback_slab,
        .alloc_len = slab_fallback_alloc_len,
        .alignment = slab_fallback_alignment,
        .expected_len = slab_fallback_alloc_len,
    };

    var case_storage: [case_count]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_memory_pool_alloc_free",
        .config = bench_config,
    });
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "alloc_free_cycle",
        .tags = &[_][]const u8{ "static_memory", "pool", "baseline" },
        .context = &pool_context,
        .run_fn = PoolContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "slab_class_alloc_free_cycle",
        .tags = &[_][]const u8{ "static_memory", "slab", "class", "baseline" },
        .context = &slab_route_context,
        .run_fn = SlabContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "slab_fallback_alloc_free_cycle",
        .tags = &[_][]const u8{ "static_memory", "slab", "fallback", "baseline" },
        .context = &slab_fallback_context,
        .run_fn = SlabContext.run,
    }));

    var sample_storage: [bench_config.sample_count * case_count]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [case_count]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(
        &group,
        &sample_storage,
        &case_result_storage,
    );

    const baseline_document_len = @max(16 * 1024, case_count * 2048);
    const read_source_len = @max(16 * 1024, case_count * 2048);
    const read_parse_len = @max(32 * 1024, case_count * 4096);
    const comparison_capacity = case_count * 2;
    const history_existing_len = @max(64 * 1024, case_count * 16 * 1024);
    const history_record_len = @max(16 * 1024, case_count * 4096);
    const history_frame_len = @max(16 * 1024, case_count * 4096);
    const history_output_len = @max(64 * 1024, case_count * 16 * 1024);
    const history_file_len = @max(64 * 1024, case_count * 16 * 1024);
    const history_names_len = @max(4096, case_count * 1024);

    var stats_storage: [case_count]bench.stats.BenchmarkStats = undefined;
    var baseline_document_buffer: [baseline_document_len]u8 = undefined;
    var read_source_buffer: [read_source_len]u8 = undefined;
    var read_parse_buffer: [read_parse_len]u8 = undefined;
    var comparisons: [comparison_capacity]bench.baseline.BaselineCaseComparison = undefined;
    var history_existing_buffer: [history_existing_len]u8 = undefined;
    var history_record_buffer: [history_record_len]u8 = undefined;
    var history_frame_buffer: [history_frame_len]u8 = undefined;
    var history_output_buffer: [history_output_len]u8 = undefined;
    var history_file_buffer: [history_file_len]u8 = undefined;
    var history_cases: [case_count]bench.stats.BenchmarkStats = undefined;
    var history_name_buffer: [history_names_len]u8 = undefined;
    var history_tags: [4][]const u8 = undefined;
    var history_comparisons: [comparison_capacity]bench.baseline.BaselineCaseComparison = undefined;
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
