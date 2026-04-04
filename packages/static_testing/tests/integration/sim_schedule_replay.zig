const std = @import("std");
const testing = @import("static_testing");

test "simulation scheduler replay reproduces recorded decisions" {
    var record_clock = testing.testing.sim.clock.SimClock.init(.init(0));
    var record_queue = try testing.testing.sim.timer_queue.TimerQueue(testing.testing.sim.scheduler.ReadyItem).init(
        std.testing.allocator,
        &record_clock,
        .{
            .buckets = 8,
            .timers_max = 8,
        },
    );
    defer record_queue.deinit(std.testing.allocator);

    var record_ready_storage: [4]testing.testing.sim.scheduler.ReadyItem = undefined;
    var record_decision_storage: [4]testing.testing.sim.scheduler.ScheduleDecision = undefined;
    var recorder = try testing.testing.sim.scheduler.Scheduler.init(
        .init(12345),
        &record_ready_storage,
        &record_decision_storage,
        .{},
        null,
    );

    _ = try record_queue.scheduleAfter(.{ .id = 10, .value = 1 }, .init(1));
    _ = try record_queue.scheduleAfter(.{ .id = 20, .value = 2 }, .init(1));
    _ = try record_clock.advance(.init(1));

    var due_ready: [4]testing.testing.sim.scheduler.ReadyItem = undefined;
    const due_count = try record_queue.drainDue(&due_ready);
    for (due_ready[0..due_count]) |ready_item| {
        try recorder.enqueueReady(ready_item);
    }

    const recorded = try recorder.nextDecision();

    var replay_clock = testing.testing.sim.clock.SimClock.init(.init(0));
    var replay_queue = try testing.testing.sim.timer_queue.TimerQueue(testing.testing.sim.scheduler.ReadyItem).init(
        std.testing.allocator,
        &replay_clock,
        .{
            .buckets = 8,
            .timers_max = 8,
        },
    );
    defer replay_queue.deinit(std.testing.allocator);

    var replay_ready_storage: [4]testing.testing.sim.scheduler.ReadyItem = undefined;
    var replay_decision_storage: [4]testing.testing.sim.scheduler.ScheduleDecision = undefined;
    var replayer = try testing.testing.sim.scheduler.Scheduler.init(
        .init(99999),
        &replay_ready_storage,
        &replay_decision_storage,
        .{},
        null,
    );

    _ = try replay_queue.scheduleAfter(.{ .id = 10, .value = 1 }, .init(1));
    _ = try replay_queue.scheduleAfter(.{ .id = 20, .value = 2 }, .init(1));
    _ = try replay_clock.advance(.init(1));

    const replay_due_count = try replay_queue.drainDue(&due_ready);
    for (due_ready[0..replay_due_count]) |ready_item| {
        try replayer.enqueueReady(ready_item);
    }

    const replayed = try replayer.applyRecordedDecision(recorded);
    try std.testing.expectEqual(recorded.chosen_id, replayed.chosen_id);
    try std.testing.expectEqual(recorded.chosen_value, replayed.chosen_value);
}
