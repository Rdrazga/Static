const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const memory = @import("static_memory");

pub const Error = error{
    InvalidConfig,
    Overflow,
};

pub const WorldConfig = struct {
    entities_max: u32,
    archetypes_max: u32,
    components_per_archetype_max: u32,
    chunks_max: u32,
    chunk_rows_max: u32,
    query_cache_entries_max: u32 = 0,
    command_buffer_entries_max: u32,
    side_index_entries_max: u32 = 0,
    budget: ?*memory.budget.Budget = null,

    pub fn validate(self: WorldConfig) Error!void {
        self.assertStructuralInvariants();

        if (self.entities_max == 0) return error.InvalidConfig;
        if (self.archetypes_max == 0) return error.InvalidConfig;
        if (self.components_per_archetype_max == 0) return error.InvalidConfig;
        if (self.chunks_max == 0) return error.InvalidConfig;
        if (self.chunk_rows_max == 0) return error.InvalidConfig;
        if (self.command_buffer_entries_max == 0) return error.InvalidConfig;

        const rows_total_max = try self.rowsTotalMax();
        if (rows_total_max < self.entities_max) return error.InvalidConfig;

        assert(self.entities_max > 0);
        assert(rows_total_max >= self.entities_max);
    }

    pub fn rowsTotalMax(self: WorldConfig) Error!u64 {
        self.assertStructuralInvariants();
        const rows_total_max = std.math.mul(u64, self.chunks_max, self.chunk_rows_max) catch return error.Overflow;
        assert(rows_total_max >= self.chunks_max);
        assert(rows_total_max >= self.chunk_rows_max);
        return rows_total_max;
    }

    fn assertStructuralInvariants(self: WorldConfig) void {
        _ = self;
        assert(@sizeOf(WorldConfig) >= @sizeOf(?*memory.budget.Budget));
        assert(@alignOf(WorldConfig) >= @alignOf(?*memory.budget.Budget));
    }
};

test "world config accepts explicit bounded values" {
    const config: WorldConfig = .{
        .entities_max = 128,
        .archetypes_max = 16,
        .components_per_archetype_max = 8,
        .chunks_max = 8,
        .chunk_rows_max = 32,
        .query_cache_entries_max = 0,
        .command_buffer_entries_max = 64,
        .side_index_entries_max = 0,
        .budget = null,
    };

    try config.validate();
    try testing.expectEqual(@as(u64, 256), try config.rowsTotalMax());
}

test "world config rejects zero-bound core surfaces" {
    const config: WorldConfig = .{
        .entities_max = 0,
        .archetypes_max = 1,
        .components_per_archetype_max = 1,
        .chunks_max = 1,
        .chunk_rows_max = 1,
        .query_cache_entries_max = 0,
        .command_buffer_entries_max = 1,
        .side_index_entries_max = 0,
        .budget = null,
    };

    try testing.expectError(error.InvalidConfig, config.validate());
}

test "world config rejects total-row bounds below entity bound" {
    const config: WorldConfig = .{
        .entities_max = 65,
        .archetypes_max = 4,
        .components_per_archetype_max = 4,
        .chunks_max = 2,
        .chunk_rows_max = 32,
        .query_cache_entries_max = 0,
        .command_buffer_entries_max = 16,
        .side_index_entries_max = 0,
        .budget = null,
    };

    try testing.expectError(error.InvalidConfig, config.validate());
}
