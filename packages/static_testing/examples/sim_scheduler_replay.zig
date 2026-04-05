//! Demonstrates deterministic scheduler recording and replay against one ready set.

const std = @import("std");
const assert = std.debug.assert;
const testing = @import("static_testing");

pub fn main() !void {
    var ready_record: [3]testing.testing.sim.scheduler.ReadyItem = undefined;
    var decisions_record: [3]testing.testing.sim.scheduler.ScheduleDecision = undefined;
    var recorder = try testing.testing.sim.scheduler.Scheduler.init(
        .init(1234),
        &ready_record,
        &decisions_record,
        .{ .strategy = .seeded },
        null,
    );
    try recorder.enqueueReady(.{ .id = 10, .value = 100 });
    try recorder.enqueueReady(.{ .id = 20, .value = 200 });
    try recorder.enqueueReady(.{ .id = 30, .value = 300 });
    const recorded = try recorder.nextDecision();

    var ready_replay: [3]testing.testing.sim.scheduler.ReadyItem = undefined;
    var decisions_replay: [3]testing.testing.sim.scheduler.ScheduleDecision = undefined;
    var replayer = try testing.testing.sim.scheduler.Scheduler.init(
        .init(9999),
        &ready_replay,
        &decisions_replay,
        .{ .strategy = .first },
        null,
    );
    try replayer.enqueueReady(.{ .id = 10, .value = 100 });
    try replayer.enqueueReady(.{ .id = 20, .value = 200 });
    try replayer.enqueueReady(.{ .id = 30, .value = 300 });
    const replayed = try replayer.applyRecordedDecision(recorded);

    assert(replayed.step_index == recorded.step_index);
    assert(replayed.chosen_id == recorded.chosen_id);
    assert(replayer.recordedDecisions().len == 1);
    assert(replayer.readyCount() == 2);
    std.debug.print("scheduler chose id={} at step={}\n", .{
        replayed.chosen_id,
        replayed.step_index,
    });
}
