const std = @import("std");
const assert = std.debug.assert;
const testing = @import("static_testing");

const durability = testing.testing.sim.storage_durability;

pub fn main() !void {
    var pending_storage: [8]durability.PendingOperation(u32) = undefined;
    var stored_storage: [4]durability.StoredValue(u32) = undefined;
    var simulator = try durability.StorageDurability(u32).init(&pending_storage, &stored_storage, .{
        .write_delay = .init(1),
        .read_delay = .init(1),
        .recoverability_policy = .stabilize_after_recover,
        .write_persistence = .acknowledge_without_store,
    });
    var completions = try testing.testing.sim.mailbox.Mailbox(durability.OperationResult(u32)).init(
        std.heap.page_allocator,
        .{ .capacity = 8 },
    );
    defer completions.deinit();

    try simulator.submitWrite(.init(0), 1, 4, 111);
    const omission_summary = try simulator.deliverDueToMailbox(.init(1), &completions, null);
    assert(omission_summary.write_success_count == 1);
    assert((try completions.recv()).status == .success);
    assert(simulator.storedItems().len == 0);

    try simulator.submitRead(.init(1), 2, 4);
    const missing_summary = try simulator.deliverDueToMailbox(.init(2), &completions, null);
    assert(missing_summary.missing_count == 1);
    assert((try completions.recv()).status == .missing);

    _ = try simulator.crash(.init(2), null);
    try simulator.recover(.init(2), null);
    try simulator.submitWrite(.init(2), 3, 4, 222);
    const repair_summary = try simulator.deliverDueToMailbox(.init(3), &completions, null);
    assert(repair_summary.write_success_count == 1);
    assert((try completions.recv()).value.? == 222);

    try simulator.submitRead(.init(3), 4, 4);
    const repair_read_summary = try simulator.deliverDueToMailbox(.init(4), &completions, null);
    assert(repair_read_summary.read_success_count == 1);
    assert((try completions.recv()).value.? == 222);

    std.debug.print(
        "storage durability acknowledged a fault-phase write without persisting it, then restabilized durability after recovery\n",
        .{},
    );
}
