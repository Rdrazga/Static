const std = @import("std");
const testing = @import("static_testing");

const durability = testing.testing.sim.storage_durability;

pub fn main() !void {
    var source_pending_storage: [6]durability.PendingOperation(u32) = undefined;
    var source_stored_storage: [4]durability.StoredValue(u32) = undefined;
    var source = try durability.StorageDurability(u32).init(&source_pending_storage, &source_stored_storage, .{
        .write_delay = .init(1),
        .read_delay = .init(1),
        .recoverability_policy = .stabilize_after_recover,
        .write_corruption = .{ .fixed_value = 700 },
        .read_corruption = .{ .fixed_value = 900 },
    });
    var completions = try testing.testing.sim.mailbox.Mailbox(durability.OperationResult(u32)).init(
        std.heap.page_allocator,
        .{ .capacity = 6 },
    );
    defer completions.deinit();

    try source.submitWrite(.init(0), 1, 4, 111);
    _ = try source.deliverDueToMailbox(.init(1), &completions, null);
    std.debug.assert((try completions.recv()).value.? == 700);

    _ = try source.crash(.init(1), null);
    try source.recover(.init(1), null);
    try source.submitWrite(.init(1), 2, 8, 222);
    try source.submitRead(.init(1), 3, 4);

    var recorded_pending: [6]durability.PendingOperation(u32) = undefined;
    var recorded_stored: [4]durability.StoredValue(u32) = undefined;
    const recorded = try source.recordState(&recorded_pending, &recorded_stored);

    var replay_pending_storage: [6]durability.PendingOperation(u32) = undefined;
    var replay_stored_storage: [4]durability.StoredValue(u32) = undefined;
    var replay = try durability.StorageDurability(u32).init(&replay_pending_storage, &replay_stored_storage, .{
        .write_delay = .init(9),
        .read_delay = .init(9),
        .recoverability_policy = .stabilize_after_recover,
        .write_corruption = .{ .fixed_value = 1_700 },
        .read_corruption = .{ .fixed_value = 1_900 },
    });
    try replay.replayRecordedState(recorded);

    const replay_summary = try replay.deliverDueToMailbox(.init(2), &completions, null);
    std.debug.assert(replay_summary.write_success_count == 1);
    std.debug.assert(replay_summary.read_success_count == 1);

    const replay_write = try completions.recv();
    const replay_read = try completions.recv();
    std.debug.assert(replay_write.value.? == 222);
    std.debug.assert(replay_read.value.? == 700);

    std.debug.print(
        "storage durability replay restored {d} stored slots and {d} pending operations in stabilized repair state\n",
        .{ recorded.stored.len, recorded.pending.len },
    );
}
