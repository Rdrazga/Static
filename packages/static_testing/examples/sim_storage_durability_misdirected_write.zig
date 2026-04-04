const std = @import("std");
const testing = @import("static_testing");

const durability = testing.testing.sim.storage_durability;

pub fn main() !void {
    var pending_storage: [8]durability.PendingOperation(u32) = undefined;
    var stored_storage: [4]durability.StoredValue(u32) = undefined;
    var simulator = try durability.StorageDurability(u32).init(&pending_storage, &stored_storage, .{
        .write_delay = .init(1),
        .read_delay = .init(1),
        .recoverability_policy = .stabilize_after_recover,
        .write_placement = .{ .fixed_slot = 9 },
    });
    var completions = try testing.testing.sim.mailbox.Mailbox(durability.OperationResult(u32)).init(
        std.heap.page_allocator,
        .{ .capacity = 8 },
    );
    defer completions.deinit();

    try simulator.submitWrite(.init(0), 1, 4, 111);
    const fault_summary = try simulator.deliverDueToMailbox(.init(1), &completions, null);
    std.debug.assert(fault_summary.corrupted_count == 1);
    std.debug.assert((try completions.recv()).status == .corrupted);
    std.debug.assert(simulator.storedItems()[0].slot_id == 9);

    _ = try simulator.crash(.init(1), null);
    try simulator.recover(.init(1), null);
    try simulator.submitWrite(.init(1), 2, 4, 222);
    const repair_summary = try simulator.deliverDueToMailbox(.init(2), &completions, null);
    std.debug.assert(repair_summary.write_success_count == 1);
    std.debug.assert((try completions.recv()).status == .success);

    try simulator.submitRead(.init(2), 3, 4);
    const repair_read_summary = try simulator.deliverDueToMailbox(.init(3), &completions, null);
    std.debug.assert(repair_read_summary.read_success_count == 1);
    std.debug.assert((try completions.recv()).value.? == 222);

    std.debug.print(
        "storage durability misdirected the fault-phase write to slot 9, then restabilized writes and reads for slot 4 after recovery\n",
        .{},
    );
}
