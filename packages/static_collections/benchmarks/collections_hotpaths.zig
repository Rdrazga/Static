//! Collection hot-path benchmark coverage for invariant-sensitive containers.
//!
//! This entrypoint exercises the core mutation paths for the handle-based
//! and ordered collection families. It is intended to make ReleaseFast
//! regression review observable once the root benchmark wiring admits it.

const std = @import("std");
const assert = std.debug.assert;
const static_collections = @import("static_collections");
const static_testing = @import("static_testing");
const support = @import("support.zig");

const bench = static_testing.bench;
const bench_config = support.default_benchmark_config;

const IndexPool = static_collections.index_pool.IndexPool;
const SlotMap = static_collections.slot_map.SlotMap(u32);
const SparseSet = static_collections.sparse_set.SparseSet;
const SortedMapCmp = struct {};
const SortedVecMap = static_collections.sorted_vec_map.SortedVecMap(u32, u32, SortedMapCmp);
const HeapCmp = struct {
    pub fn lessThan(_: @This(), a: u32, b: u32) bool {
        return a < b;
    }
};
const MinHeap = static_collections.min_heap.MinHeap(u32, HeapCmp);

const pool_slots = 256;
const heap_capacity = 256;
const slot_map_capacity = 256;
const sparse_universe = 512;
const sorted_map_capacity = 256;
const prefill_count = 128;
const sparse_hot_value: u32 = 64;
const sorted_hot_key: u32 = 64;

const IndexPoolContext = struct {
    pool: IndexPool,
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *IndexPoolContext = @ptrCast(@alignCast(context_ptr));
        const handle = context.pool.allocate() catch unreachable;
        context.sink +%= @as(u64, handle.index);
        context.pool.release(handle) catch unreachable;
        assert(context.sink != 0);
    }
};

const HeapContext = struct {
    heap: MinHeap,
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *HeapContext = @ptrCast(@alignCast(context_ptr));
        const removed = context.heap.popMin().?;
        context.heap.push(@intCast((removed * 7) % 251 + 1)) catch unreachable;
        context.sink +%= @as(u64, removed);
        assert(context.sink != 0);
    }
};

const SlotMapContext = struct {
    map: SlotMap,
    hot_handle: SlotMap.Handle,
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *SlotMapContext = @ptrCast(@alignCast(context_ptr));
        const old = context.map.remove(context.hot_handle) catch unreachable;
        context.hot_handle = context.map.insert(old + 1) catch unreachable;
        context.sink +%= @as(u64, old);
        assert(context.sink != 0);
    }
};

const SparseSetContext = struct {
    set: SparseSet,
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *SparseSetContext = @ptrCast(@alignCast(context_ptr));
        context.set.remove(sparse_hot_value) catch unreachable;
        context.set.insert(sparse_hot_value) catch unreachable;
        context.sink +%= @as(u64, sparse_hot_value);
        assert(context.sink != 0);
    }
};

const SortedVecMapContext = struct {
    map: SortedVecMap,
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *SortedVecMapContext = @ptrCast(@alignCast(context_ptr));
        const old = context.map.remove(sorted_hot_key) catch unreachable;
        context.map.put(sorted_hot_key, old + 1) catch unreachable;
        context.sink +%= @as(u64, old);
        assert(context.sink != 0);
    }
};

pub fn main() !void {
    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    var output_dir = try support.openOutputDir(io, "collections_hotpaths");
    defer output_dir.close(io);

    var pool = try IndexPool.init(std.heap.page_allocator, .{
        .slots_max = pool_slots,
        .budget = null,
    });
    defer pool.deinit();
    var heap = try MinHeap.init(std.heap.page_allocator, .{
        .capacity = heap_capacity,
        .budget = null,
    }, .{});
    defer heap.deinit();
    var slot_map = try SlotMap.init(std.heap.page_allocator, .{
        .budget = null,
        .initial_capacity = slot_map_capacity,
    });
    defer slot_map.deinit();
    var sparse_set = try SparseSet.init(std.heap.page_allocator, .{
        .universe_size = sparse_universe,
        .budget = null,
    });
    defer sparse_set.deinit();
    var sorted_map = try SortedVecMap.init(std.heap.page_allocator, .{
        .budget = null,
        .initial_capacity = sorted_map_capacity,
    });
    defer sorted_map.deinit();

    try sparse_set.ensureDenseCapacity(prefill_count);

    var i: usize = 0;
    while (i < prefill_count) : (i += 1) {
        _ = try pool.allocate();
        try heap.push(@intCast((i * 7) % 251 + 1));
        _ = try slot_map.insert(@intCast(i));
        try sparse_set.insert(@intCast(i * 2));
        try sorted_map.put(@intCast(i), @intCast(i * 3 + 1));
    }

    var pool_context = IndexPoolContext{ .pool = pool };
    var heap_context = HeapContext{ .heap = heap };
    var slot_map_it = slot_map.iterator();
    const hot_handle = slot_map_it.next().?.handle;
    var slot_map_context = SlotMapContext{
        .map = slot_map,
        .hot_handle = hot_handle,
    };
    var sparse_set_context = SparseSetContext{ .set = sparse_set };
    var sorted_map_context = SortedVecMapContext{ .map = sorted_map };

    var case_storage: [5]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_collections_hotpaths",
        .config = bench_config,
    });
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "index_pool_alloc_release",
        .tags = &[_][]const u8{ "static_collections", "index_pool", "hotpath", "baseline" },
        .context = &pool_context,
        .run_fn = IndexPoolContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "min_heap_push_pop",
        .tags = &[_][]const u8{ "static_collections", "min_heap", "hotpath", "baseline" },
        .context = &heap_context,
        .run_fn = HeapContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "slot_map_insert_remove",
        .tags = &[_][]const u8{ "static_collections", "slot_map", "hotpath", "baseline" },
        .context = &slot_map_context,
        .run_fn = SlotMapContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "sparse_set_insert_remove",
        .tags = &[_][]const u8{ "static_collections", "sparse_set", "hotpath", "baseline" },
        .context = &sparse_set_context,
        .run_fn = SparseSetContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "sorted_vec_map_put_remove",
        .tags = &[_][]const u8{ "static_collections", "sorted_vec_map", "hotpath", "baseline" },
        .context = &sorted_map_context,
        .run_fn = SortedVecMapContext.run,
    }));

    var sample_storage: [bench_config.sample_count * 5]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [5]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(
        &group,
        &sample_storage,
        &case_result_storage,
    );

    try support.writeGroupReport(
        case_storage.len,
        run_result,
        io,
        output_dir,
        support.default_environment_note,
    );
}
