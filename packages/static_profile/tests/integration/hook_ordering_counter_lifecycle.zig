const std = @import("std");
const profile = @import("static_profile");

const hooks = profile.hooks;

const CounterSink = struct {
    trace: *profile.trace.EnabledTrace,
    next_ts: u64,
    tid: u32,

    fn emit(self: *@This(), name: []const u8, value: i64) void {
        self.trace.recordCounter(name, self.next_ts, self.tid, value) catch |err| {
            std.debug.panic("unexpected trace error: {s}", .{@errorName(err)});
        };
        self.next_ts += 1;
    }
};

test "hooks.emitCounters preserves declared order when wired into EnabledTrace" {
    var trace = try profile.trace.EnabledTrace.init(std.testing.allocator, 3);
    defer trace.deinit();

    var sink = CounterSink{
        .trace = &trace,
        .next_ts = 100,
        .tid = 7,
    };

    const values = [_]i64{ 7, 13, 29 };
    hooks.emitCounters("cpu", &.{ "idle", "busy", "steal" }, &values, &sink, CounterSink.emit);

    try std.testing.expectEqual(@as(usize, 3), trace.events.items.len);
    try std.testing.expectEqualStrings("cpu.idle", trace.events.items[0].counter.name);
    try std.testing.expectEqualStrings("cpu.busy", trace.events.items[1].counter.name);
    try std.testing.expectEqualStrings("cpu.steal", trace.events.items[2].counter.name);
    try std.testing.expectEqual(@as(u64, 100), trace.events.items[0].counter.ts);
    try std.testing.expectEqual(@as(u64, 101), trace.events.items[1].counter.ts);
    try std.testing.expectEqual(@as(u64, 102), trace.events.items[2].counter.ts);

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    try trace.writeChromeTraceJson(&aw.writer);

    var out = aw.toArrayList();
    defer out.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "[{\"name\":\"cpu.idle\",\"ph\":\"C\",\"ts\":100,\"pid\":0,\"tid\":7,\"args\":{\"value\":7}},{\"name\":\"cpu.busy\",\"ph\":\"C\",\"ts\":101,\"pid\":0,\"tid\":7,\"args\":{\"value\":13}},{\"name\":\"cpu.steal\",\"ph\":\"C\",\"ts\":102,\"pid\":0,\"tid\":7,\"args\":{\"value\":29}}]",
        out.items,
    );
}

test "repeated same-name counter updates remain distinct events" {
    var trace = try profile.trace.EnabledTrace.init(std.testing.allocator, 4);
    defer trace.deinit();

    try trace.recordCounter("queue_depth", 1, 3, 10);
    try trace.recordCounter("queue_depth", 2, 3, 11);
    try trace.recordCounter("queue_depth", 3, 3, 12);

    try std.testing.expectEqual(@as(usize, 3), trace.events.items.len);
    try std.testing.expectEqualStrings("queue_depth", trace.events.items[0].counter.name);
    try std.testing.expectEqualStrings("queue_depth", trace.events.items[1].counter.name);
    try std.testing.expectEqualStrings("queue_depth", trace.events.items[2].counter.name);
    try std.testing.expectEqual(@as(i64, 10), trace.events.items[0].counter.value);
    try std.testing.expectEqual(@as(i64, 11), trace.events.items[1].counter.value);
    try std.testing.expectEqual(@as(i64, 12), trace.events.items[2].counter.value);

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    try trace.writeChromeTraceJson(&aw.writer);

    var out = aw.toArrayList();
    defer out.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "[{\"name\":\"queue_depth\",\"ph\":\"C\",\"ts\":1,\"pid\":0,\"tid\":3,\"args\":{\"value\":10}},{\"name\":\"queue_depth\",\"ph\":\"C\",\"ts\":2,\"pid\":0,\"tid\":3,\"args\":{\"value\":11}},{\"name\":\"queue_depth\",\"ph\":\"C\",\"ts\":3,\"pid\":0,\"tid\":3,\"args\":{\"value\":12}}]",
        out.items,
    );
}

test "NoSpaceLeft on the last counter append does not corrupt prior export state" {
    var trace = try profile.trace.EnabledTrace.init(std.testing.allocator, 2);
    defer trace.deinit();

    try trace.recordCounter("first", 1, 4, 1);
    try trace.recordCounter("second", 2, 4, 2);

    var aw_before: std.Io.Writer.Allocating = .init(std.testing.allocator);
    try trace.writeChromeTraceJson(&aw_before.writer);
    var before = aw_before.toArrayList();
    defer before.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "[{\"name\":\"first\",\"ph\":\"C\",\"ts\":1,\"pid\":0,\"tid\":4,\"args\":{\"value\":1}},{\"name\":\"second\",\"ph\":\"C\",\"ts\":2,\"pid\":0,\"tid\":4,\"args\":{\"value\":2}}]",
        before.items,
    );

    try std.testing.expectError(profile.trace.Error.NoSpaceLeft, trace.recordCounter("third", 3, 4, 3));
    try std.testing.expectEqual(@as(usize, 2), trace.events.items.len);

    var aw_after: std.Io.Writer.Allocating = .init(std.testing.allocator);
    try trace.writeChromeTraceJson(&aw_after.writer);
    var after = aw_after.toArrayList();
    defer after.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(before.items, after.items);
}

test "NoSpaceLeft on endZone preserves open depth and prior export state" {
    var trace = try profile.trace.EnabledTrace.init(std.testing.allocator, 2);
    defer {
        trace.events.deinit(std.testing.allocator);
        trace = undefined;
    }

    const tok = try trace.beginZone("frame", 10, 8);
    try trace.recordCounter("queued", 11, 8, 1);

    try std.testing.expectError(profile.trace.Error.NoSpaceLeft, trace.endZone(tok, 12));
    try std.testing.expectEqual(@as(u32, 1), trace.zone_depth);
    try std.testing.expectEqual(@as(usize, 2), trace.events.items.len);

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    try trace.writeChromeTraceJson(&aw.writer);
    var out = aw.toArrayList();
    defer out.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "[{\"name\":\"frame\",\"ph\":\"B\",\"ts\":10,\"pid\":0,\"tid\":8},{\"name\":\"queued\",\"ph\":\"C\",\"ts\":11,\"pid\":0,\"tid\":8,\"args\":{\"value\":1}}]",
        out.items,
    );
}
