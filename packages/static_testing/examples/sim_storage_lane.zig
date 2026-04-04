const std = @import("std");
const testing = @import("static_testing");

pub fn main() !void {
    var completions = try testing.testing.sim.mailbox.Mailbox(
        testing.testing.sim.storage_lane.OperationResult(u32),
    ).init(std.heap.page_allocator, .{ .capacity = 4 });
    defer completions.deinit();

    var storage: [4]testing.testing.sim.storage_lane.PendingCompletion(u32) = undefined;
    var lane = try testing.testing.sim.storage_lane.StorageLane(u32).init(&storage, .{
        .default_delay = .init(1),
    });

    try lane.submitFailure(.init(0), 11, 500);
    try lane.submitSuccess(.init(0), 12, 200);
    const delivered = try lane.deliverDueToMailbox(.init(1), &completions, null);
    std.debug.assert(delivered.success_count == 1);
    std.debug.assert(delivered.failure_count == 1);
    std.debug.print("storage lane delivered success=1 failure=1\n", .{});
}
