const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const memory = @import("static_memory");
const collections = @import("static_collections");
const entity_mod = @import("entity.zig");

pub const Error = collections.index_pool.Error;

pub const Config = struct {
    entities_max: u32,
    budget: ?*memory.budget.Budget,
};

pub const EntityPool = struct {
    pool: collections.index_pool.IndexPool,

    pub fn init(allocator: std.mem.Allocator, config: Config) Error!EntityPool {
        assert(config.entities_max > 0);
        var self: EntityPool = .{
            .pool = try collections.index_pool.IndexPool.init(allocator, .{
                .slots_max = config.entities_max,
                .budget = config.budget,
            }),
        };
        self.assertInvariants();
        return self;
    }

    pub fn deinit(self: *EntityPool) void {
        self.assertInvariants();
        self.pool.deinit();
        self.* = undefined;
    }

    pub fn capacity(self: *const EntityPool) u32 {
        self.assertInvariants();
        const capacity_value = self.pool.capacity();
        assert(capacity_value > 0);
        return capacity_value;
    }

    pub fn freeCount(self: *const EntityPool) u32 {
        self.assertInvariants();
        const free_count = self.pool.freeCount();
        assert(free_count <= self.capacity());
        return free_count;
    }

    pub fn activeCount(self: *const EntityPool) u32 {
        self.assertInvariants();
        const active_count = self.capacity() - self.freeCount();
        assert(active_count <= self.capacity());
        return active_count;
    }

    pub fn allocate(self: *EntityPool) Error!entity_mod.Entity {
        self.assertInvariants();
        const entity = entity_mod.Entity.fromHandle(try self.pool.allocate());
        assert(entity.isValid());
        self.assertInvariants();
        return entity;
    }

    pub fn release(self: *EntityPool, entity: entity_mod.Entity) Error!void {
        self.assertInvariants();
        try self.pool.release(entity.toHandle());
        assert(!self.contains(entity));
        self.assertInvariants();
    }

    pub fn contains(self: *const EntityPool, entity: entity_mod.Entity) bool {
        self.assertInvariants();
        return self.pool.contains(entity.toHandle());
    }

    fn assertInvariants(self: *const EntityPool) void {
        assert(self.pool.capacity() > 0);
        assert(self.pool.freeCount() <= self.pool.capacity());
    }
};

test "entity pool allocates, rejects stale entities, and reuses slots safely" {
    var pool = try EntityPool.init(testing.allocator, .{
        .entities_max = 2,
        .budget = null,
    });
    defer pool.deinit();

    const first = try pool.allocate();
    try testing.expect(pool.contains(first));
    try testing.expectEqual(@as(u32, 1), pool.activeCount());

    try pool.release(first);
    try testing.expect(!pool.contains(first));
    try testing.expectEqual(@as(u32, 0), pool.activeCount());

    const second = try pool.allocate();
    try testing.expect(second.isValid());
    try testing.expectEqual(first.index, second.index);
    try testing.expect(second.generation != first.generation);
}

test "entity pool reports bounded exhaustion" {
    var pool = try EntityPool.init(testing.allocator, .{
        .entities_max = 1,
        .budget = null,
    });
    defer pool.deinit();

    _ = try pool.allocate();
    try testing.expectEqual(@as(u32, 0), pool.freeCount());
    try testing.expectError(error.NoSpaceLeft, pool.allocate());
}
