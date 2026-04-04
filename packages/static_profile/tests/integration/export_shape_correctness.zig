const std = @import("std");
const profile = @import("static_profile");

test "EnabledTrace exports an interleaved B/C/B/C/E/E trace exactly" {
    var trace = try profile.trace.EnabledTrace.init(std.testing.allocator, 6);
    defer trace.deinit();

    const outer = try trace.beginZone("frame", 10, 1);
    try trace.recordCounter("fps", 11, 1, 60);
    const inner = try trace.beginZone("draw", 12, 1);
    try trace.recordCounter("triangles", 13, 1, 42_000);
    try trace.endZone(inner, 14);
    try trace.endZone(outer, 15);

    try std.testing.expectEqual(@as(usize, 6), trace.events.items.len);
    try std.testing.expectEqual(@as(u32, 0), trace.zone_depth);

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    try trace.writeChromeTraceJson(&aw.writer);

    var out = aw.toArrayList();
    defer out.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "[{\"name\":\"frame\",\"ph\":\"B\",\"ts\":10,\"pid\":0,\"tid\":1},{\"name\":\"fps\",\"ph\":\"C\",\"ts\":11,\"pid\":0,\"tid\":1,\"args\":{\"value\":60}},{\"name\":\"draw\",\"ph\":\"B\",\"ts\":12,\"pid\":0,\"tid\":1},{\"name\":\"triangles\",\"ph\":\"C\",\"ts\":13,\"pid\":0,\"tid\":1,\"args\":{\"value\":42000}},{\"name\":\"draw\",\"ph\":\"E\",\"ts\":14,\"pid\":0,\"tid\":1},{\"name\":\"frame\",\"ph\":\"E\",\"ts\":15,\"pid\":0,\"tid\":1}]",
        out.items,
    );
}
