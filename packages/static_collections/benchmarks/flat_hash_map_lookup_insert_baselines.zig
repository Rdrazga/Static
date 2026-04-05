//! Flat hash map lookup and bounded insert/remove churn benchmark.
//!
//! Uses the shared benchmark workflow and retained baseline artifacts to keep
//! `flat_hash_map` lookup-hit and mutation-heavy churn review on the canonical
//! `baseline.zon` plus `history.binlog` path.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const static_collections = @import("static_collections");
const static_testing = @import("static_testing");
const support = @import("support.zig");

const bench = static_testing.bench;
const bench_config = support.default_benchmark_config;
const FlatHashMap = static_collections.flat_hash_map.FlatHashMap(u32, u32, struct {});

const lookup_key_count: u32 = 1024;
const churn_key_count: u32 = 768;
const reserved_capacity: usize = 2048;
const seeded_hash: u64 = 0xfeed_face_cafe_beef;

const LookupContext = struct {
    map: *FlatHashMap,
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *LookupContext = @ptrCast(@alignCast(context_ptr));
        assert(context.map.len() == lookup_key_count);

        var key: u32 = 0;
        while (key < lookup_key_count) : (key += 1) {
            const value = context.map.getConst(key) orelse unreachable;
            context.sink +%= bench.case.blackBox(@as(u64, value.*));
        }

        assert(context.sink != 0);
    }
};

const ChurnContext = struct {
    map: *FlatHashMap,
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *ChurnContext = @ptrCast(@alignCast(context_ptr));

        context.map.clear();
        assert(context.map.len() == 0);

        var key: u32 = 0;
        while (key < churn_key_count) : (key += 1) {
            context.map.putNoClobber(key, key * 3 + 1) catch unreachable;
        }

        key = 0;
        while (key < churn_key_count) : (key += 2) {
            const removed = context.map.remove(key) catch unreachable;
            context.sink +%= bench.case.blackBox(@as(u64, removed));
        }

        assert(context.map.len() == churn_key_count / 2);
    }
};

pub fn main() !void {
    try validateSemanticPreflight(std.heap.page_allocator);

    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    var output_dir = try support.openOutputDir(io, "flat_hash_map_lookup_insert_baselines");
    defer output_dir.close(io);

    var lookup_map = try initMap(std.heap.page_allocator);
    defer lookup_map.deinit();
    try fillLookupHotset(&lookup_map);

    var churn_map = try initMap(std.heap.page_allocator);
    defer churn_map.deinit();

    var lookup_context = LookupContext{ .map = &lookup_map };
    var churn_context = ChurnContext{ .map = &churn_map };

    var case_storage: [2]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_collections_flat_hash_map_lookup_insert_baselines",
        .config = bench_config,
    });
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "lookup_hit_hotset",
        .tags = &[_][]const u8{ "static_collections", "flat_hash_map", "lookup", "baseline" },
        .context = &lookup_context,
        .run_fn = LookupContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "insert_remove_churn",
        .tags = &[_][]const u8{ "static_collections", "flat_hash_map", "churn", "baseline" },
        .context = &churn_context,
        .run_fn = ChurnContext.run,
    }));

    var sample_storage: [bench_config.sample_count * 2]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [2]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(
        &group,
        &sample_storage,
        &case_result_storage,
    );

    try support.writeGroupReport(
        run_result,
        io,
        output_dir,
        support.default_environment_note,
    );
}

fn initMap(allocator: std.mem.Allocator) !FlatHashMap {
    return FlatHashMap.init(allocator, .{
        .initial_capacity = reserved_capacity,
        .seed = seeded_hash,
        .budget = null,
    });
}

fn fillLookupHotset(map: *FlatHashMap) !void {
    var key: u32 = 0;
    while (key < lookup_key_count) : (key += 1) {
        try map.putNoClobber(key, key * 7 + 3);
    }
}

fn validateSemanticPreflight(allocator: std.mem.Allocator) !void {
    var lookup_map = try initMap(allocator);
    defer lookup_map.deinit();
    try fillLookupHotset(&lookup_map);
    try testing.expectEqual(@as(usize, lookup_key_count), lookup_map.len());
    try testing.expectEqual(@as(u32, 3), lookup_map.getConst(0).?.*);
    try testing.expectEqual(
        @as(u32, (lookup_key_count - 1) * 7 + 3),
        lookup_map.getConst(lookup_key_count - 1).?.*,
    );

    var churn_map = try initMap(allocator);
    defer churn_map.deinit();
    var key: u32 = 0;
    while (key < churn_key_count) : (key += 1) {
        try churn_map.putNoClobber(key, key * 3 + 1);
    }
    try testing.expectEqual(@as(usize, churn_key_count), churn_map.len());

    key = 0;
    while (key < churn_key_count) : (key += 2) {
        try testing.expectEqual(key * 3 + 1, try churn_map.remove(key));
    }
    try testing.expectEqual(@as(usize, churn_key_count / 2), churn_map.len());
    try testing.expect(churn_map.getConst(0) == null);
    try testing.expectEqual(@as(u32, 4), churn_map.getConst(1).?.*);
}
