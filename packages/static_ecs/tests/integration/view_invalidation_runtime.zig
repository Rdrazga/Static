const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const static_ecs = @import("static_ecs");

const invalidation_child_env = "STATIC_ECS_VIEW_INVALIDATION_CHILD";

const ChildCase = enum {
    batch,
    iterator,
};

test "view chunk batches panic after structural mutation" {
    if (childCaseFromEnv() == .batch) {
        try runBatchInvalidationChild();
        return;
    }
    try expectInvalidationChild(.batch, "static_ecs.View: ChunkBatch invalidated by structural mutation");
}

test "view iterators panic after structural mutation" {
    if (childCaseFromEnv() == .iterator) {
        try runIteratorInvalidationChild();
        return;
    }
    try expectInvalidationChild(.iterator, "static_ecs.View: Iterator invalidated by structural mutation");
}

fn runBatchInvalidationChild() !void {
    const Position = struct { x: f32, y: f32 };
    const World = static_ecs.World(.{ Position });

    var world = try World.init(testing.allocator, .{
        .entities_max = 4,
        .archetypes_max = 4,
        .components_per_archetype_max = 2,
        .chunks_max = 4,
        .chunk_rows_max = 2,
        .command_buffer_entries_max = 4,
        .command_buffer_payload_bytes_max = 256,
        .empty_chunk_retained_max = 0,
        .budget = null,
    });

    const entity = try world.spawn();
    try world.insert(entity, Position{ .x = 1, .y = 2 });

    var view = world.view(.{
        static_ecs.Write(Position),
    });
    var it = view.iterator();
    const batch = it.next().?;

    try world.despawn(entity);
    _ = batch.entities();
}

fn runIteratorInvalidationChild() !void {
    const Position = struct { x: f32, y: f32 };
    const World = static_ecs.World(.{ Position });

    var world = try World.init(testing.allocator, .{
        .entities_max = 4,
        .archetypes_max = 4,
        .components_per_archetype_max = 2,
        .chunks_max = 4,
        .chunk_rows_max = 2,
        .command_buffer_entries_max = 4,
        .command_buffer_payload_bytes_max = 256,
        .empty_chunk_retained_max = 0,
        .budget = null,
    });

    const entity = try world.spawn();
    try world.insert(entity, Position{ .x = 3, .y = 4 });

    var view = world.view(.{
        static_ecs.Write(Position),
    });
    var it = view.iterator();
    _ = it.next().?;

    _ = try world.spawn();
    _ = it.next();
}

fn childCaseFromEnv() ?ChildCase {
    var env_map = std.process.Environ.createMap(testing.environ, testing.allocator) catch return null;
    defer env_map.deinit();

    const value = env_map.get(invalidation_child_env) orelse return null;
    if (std.mem.eql(u8, value, "batch")) return .batch;
    if (std.mem.eql(u8, value, "iterator")) return .iterator;
    return null;
}

fn expectInvalidationChild(child_case: ChildCase, expected_fragment: []const u8) !void {
    if (builtin.os.tag != .windows and builtin.os.tag != .linux and builtin.os.tag != .serenity) {
        return error.SkipZigTest;
    }

    var env_map = try std.process.Environ.createMap(testing.environ, testing.allocator);
    defer env_map.deinit();
    try env_map.put(invalidation_child_env, switch (child_case) {
        .batch => "batch",
        .iterator => "iterator",
    });

    const exe_path = try currentExePathAlloc(testing.allocator);
    defer testing.allocator.free(exe_path);

    const result = try std.process.run(testing.allocator, testing.io, .{
        .argv = &.{exe_path},
        .environ_map = &env_map,
    });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| try testing.expect(code != 0),
        else => {},
    }
    try testing.expect(std.mem.indexOf(u8, result.stderr, expected_fragment) != null);
}

fn currentExePathAlloc(allocator: std.mem.Allocator) ![]u8 {
    switch (builtin.os.tag) {
        .windows => {
            var path_w_buf: [std.fs.max_path_bytes]u16 = undefined;
            const path_w = std.os.windows.kernel32.GetModuleFileNameW(null, &path_w_buf, path_w_buf.len);
            return std.unicode.utf16LeToUtf8Alloc(allocator, path_w_buf[0..path_w]);
        },
        .linux, .serenity => {
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const len = try std.Io.Dir.readLinkAbsolute(testing.io, "/proc/self/exe", path_buf[0..]);
            return allocator.dupe(u8, path_buf[0..len]);
        },
        else => return error.Unavailable,
    }
}
