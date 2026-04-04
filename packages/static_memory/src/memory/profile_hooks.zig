//! Helpers for emitting allocator capacity metrics to external profilers/collectors.

const std = @import("std");
const CapacityReport = @import("capacity_report.zig").CapacityReport;

fn clampU64ToI64(v: u64) i64 {
    const max_i64_u64: u64 = @intCast(std.math.maxInt(i64));
    const result: i64 = if (v > max_i64_u64) std.math.maxInt(i64) else @intCast(v);
    // Postcondition: the result must be non-negative because u64 is unsigned and
    // i64 can only be negative if the cast were to wrap, which the clamp prevents.
    std.debug.assert(result >= 0);
    // Postcondition: the result must not exceed maxInt(i64), enforced by the clamp above.
    std.debug.assert(result <= std.math.maxInt(i64));
    return result;
}

pub fn emitCapacityReportCounters(
    comptime base: []const u8,
    report: CapacityReport,
    ctx: anytype,
    comptime emit: fn (@TypeOf(ctx), []const u8, i64) void,
) void {
    std.debug.assert(base.len != 0);
    std.debug.assert(report.high_water >= report.used);
    if (report.capacity != 0) std.debug.assert(report.capacity >= report.used);

    emit(ctx, base ++ ".used", clampU64ToI64(report.used));
    emit(ctx, base ++ ".high_water", clampU64ToI64(report.high_water));
    emit(ctx, base ++ ".capacity", clampU64ToI64(report.capacity));
    emit(ctx, base ++ ".overflow_count", @intCast(report.overflow_count));
}

test "emitCapacityReportCounters emits stable names and values" {
    // Verifies naming and value clamping for capacity-report counters emitted through an arbitrary callback.
    const testing = std.testing;

    const sample: CapacityReport = .{
        .unit = .bytes,
        .used = 10,
        .high_water = 20,
        .capacity = 30,
        .overflow_count = 2,
    };

    const Collector = struct {
        names: [4][]const u8 = undefined,
        values: [4]i64 = undefined,
        len: u32 = 0,

        fn emit(self: *@This(), name: []const u8, value: i64) void {
            std.debug.assert(self.len < self.names.len);
            self.names[@intCast(self.len)] = name;
            self.values[@intCast(self.len)] = value;
            self.len += 1;
        }
    };

    var c = Collector{};
    emitCapacityReportCounters("mem", sample, &c, Collector.emit);

    try testing.expectEqual(@as(u32, 4), c.len);
    try testing.expectEqualStrings("mem.used", c.names[0]);
    try testing.expectEqualStrings("mem.high_water", c.names[1]);
    try testing.expectEqualStrings("mem.capacity", c.names[2]);
    try testing.expectEqualStrings("mem.overflow_count", c.names[3]);
    try testing.expectEqual(@as(i64, 10), c.values[0]);
    try testing.expectEqual(@as(i64, 20), c.values[1]);
    try testing.expectEqual(@as(i64, 30), c.values[2]);
    try testing.expectEqual(@as(i64, 2), c.values[3]);
}
