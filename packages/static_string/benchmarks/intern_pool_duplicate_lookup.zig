//! `static_string` intern-pool duplicate and resolve baselines.

const std = @import("std");
const assert = std.debug.assert;
const static_string = @import("static_string");
const static_testing = @import("static_testing");
const support = @import("support.zig");

const bench = static_testing.bench;

const bench_config = bench.config.BenchmarkConfig{
    .mode = .full,
    .warmup_iterations = 32,
    .measure_iterations = 1_048_576,
    .sample_count = 16,
};

const DuplicateContext = struct {
    entries: [8]static_string.Entry = undefined,
    bytes: [64]u8 = undefined,
    pool: static_string.InternPool = undefined,
    target_symbol: static_string.Symbol = 0,
    sink: u64 = 0,

    fn init(self: *@This()) void {
        self.pool = static_string.InternPool.init(self.entries[0..], self.bytes[0..]) catch unreachable;
        _ = self.pool.intern("header-name") catch unreachable;
        self.target_symbol = self.pool.intern("content-type") catch unreachable;
        _ = self.pool.intern("caf\xc3\xa9") catch unreachable;
        assert(self.pool.len() == 3);
    }

    fn run(context_ptr: *anyopaque) void {
        const context: *DuplicateContext = @ptrCast(@alignCast(context_ptr));
        const symbol = context.pool.intern("content-type") catch unreachable;
        if (symbol != context.target_symbol) unreachable;
        context.sink = bench.case.blackBox(@as(u64, symbol));
        assert(context.sink == context.target_symbol);
    }
};

const ResolveContext = struct {
    entries: [8]static_string.Entry = undefined,
    bytes: [64]u8 = undefined,
    pool: static_string.InternPool = undefined,
    target_symbol: static_string.Symbol = 0,
    sink: u64 = 0,

    fn init(self: *@This()) void {
        self.pool = static_string.InternPool.init(self.entries[0..], self.bytes[0..]) catch unreachable;
        _ = self.pool.intern("alpha") catch unreachable;
        self.target_symbol = self.pool.intern("x-request-id") catch unreachable;
        _ = self.pool.intern("emoji-\xf0\x9f\x98\x80") catch unreachable;
        assert(self.pool.len() == 3);
    }

    fn run(context_ptr: *anyopaque) void {
        const context: *ResolveContext = @ptrCast(@alignCast(context_ptr));
        const resolved = context.pool.resolve(context.target_symbol) catch unreachable;
        if (!std.mem.eql(u8, resolved, "x-request-id")) unreachable;
        context.sink = bench.case.blackBox(@as(u64, @intCast(resolved.len)));
        assert(context.sink == "x-request-id".len);
    }
};

pub fn main() !void {
    validateSemanticPreflight();

    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    var output_dir = try support.openOutputDir(io, "intern_pool_duplicate_lookup");
    defer output_dir.close(io);

    var duplicate_context = DuplicateContext{};
    duplicate_context.init();
    var resolve_context = ResolveContext{};
    resolve_context.init();

    var case_storage: [2]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_string_intern_pool_duplicate_lookup",
        .config = bench_config,
    });
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "duplicate_intern_symbol",
        .tags = &[_][]const u8{ "static_string", "intern_pool", "duplicate" },
        .context = &duplicate_context,
        .run_fn = DuplicateContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "resolve_existing_symbol",
        .tags = &[_][]const u8{ "static_string", "intern_pool", "resolve" },
        .context = &resolve_context,
        .run_fn = ResolveContext.run,
    }));

    var sample_storage: [bench_config.sample_count * 2]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [2]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(
        &group,
        &sample_storage,
        &case_result_storage,
    );

    std.debug.print("== static_string intern pool duplicate and resolve ==\n", .{});
    try support.writeGroupReport(
        run_result,
        io,
        output_dir,
        "duplicate intern and resolve lookups over bounded pool state",
    );
}

fn validateSemanticPreflight() void {
    var duplicate_context = DuplicateContext{};
    duplicate_context.init();
    DuplicateContext.run(&duplicate_context);

    var resolve_context = ResolveContext{};
    resolve_context.init();
    ResolveContext.run(&resolve_context);
}
