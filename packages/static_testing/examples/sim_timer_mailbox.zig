//! Demonstrates timer delivery, deterministic scheduling, and mailbox handoff.

const std = @import("std");
const testing = @import("static_testing");

pub fn main() !void {
    var sim_fixture: testing.testing.sim.fixture.Fixture(4, 4, 4, 16) = undefined;
    try sim_fixture.init(.{
        .allocator = std.heap.page_allocator,
        .timer_queue_config = .{
            .buckets = 8,
            .timers_max = 8,
        },
        .scheduler_seed = .init(1234),
        .scheduler_config = .{ .strategy = .first },
        .event_loop_config = .{ .step_budget_max = 8 },
        .trace_config = .{ .max_events = 16 },
    });
    defer sim_fixture.deinit();

    var mailbox = try testing.testing.sim.mailbox.Mailbox(u32).init(
        std.heap.page_allocator,
        .{
            .capacity = 4,
        },
    );
    defer mailbox.deinit();

    _ = try sim_fixture.scheduleAfter(.{ .id = 11 }, .init(1));
    _ = try sim_fixture.scheduleAfter(.{ .id = 22 }, .init(2));

    _ = try sim_fixture.step();

    const first = try sim_fixture.step();
    std.debug.assert(first.decision != null);
    const first_snapshot = sim_fixture.traceBufferPtr().?.snapshot();
    const first_decision_sequence_no = first_snapshot.items[first_snapshot.items.len - 1].sequence_no;
    try sim_fixture.traceBufferPtr().?.append(.{
        .timestamp_ns = sim_fixture.sim_clock.now().tick,
        .category = .info,
        .label = "mailbox_send",
        .value = first.decision.?.chosen_id,
        .lineage = .{
            .cause_sequence_no = first_decision_sequence_no,
            .correlation_id = first.decision.?.chosen_id,
            .surface_label = "mailbox",
        },
    });
    try mailbox.send(first.decision.?.chosen_id);

    _ = try sim_fixture.step();
    const second = try sim_fixture.step();
    std.debug.assert(second.decision != null);
    const second_snapshot = sim_fixture.traceBufferPtr().?.snapshot();
    const second_decision_sequence_no = second_snapshot.items[second_snapshot.items.len - 1].sequence_no;
    try sim_fixture.traceBufferPtr().?.append(.{
        .timestamp_ns = sim_fixture.sim_clock.now().tick,
        .category = .info,
        .label = "mailbox_send",
        .value = second.decision.?.chosen_id,
        .lineage = .{
            .cause_sequence_no = second_decision_sequence_no,
            .correlation_id = second.decision.?.chosen_id,
            .surface_label = "mailbox",
        },
    });
    try mailbox.send(second.decision.?.chosen_id);

    std.debug.assert(try mailbox.recv() == 11);
    std.debug.assert(try mailbox.recv() == 22);

    var aw: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer aw.deinit();
    try sim_fixture.traceBufferPtr().?.snapshot().writeCausalityText(&aw.writer);
    std.debug.print("{s}\n", .{aw.written()});
}
