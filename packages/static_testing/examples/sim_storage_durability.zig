const std = @import("std");
const assert = std.debug.assert;
const testing = @import("static_testing");

const durability = testing.testing.sim.storage_durability;
const temporal = testing.testing.temporal;

pub fn main() !void {
    var sim_fixture: testing.testing.sim.fixture.Fixture(4, 4, 4, 24) = undefined;
    try sim_fixture.init(.{
        .allocator = std.heap.page_allocator,
        .timer_queue_config = .{
            .buckets = 8,
            .timers_max = 8,
        },
        .scheduler_seed = .init(321),
        .scheduler_config = .{ .strategy = .first },
        .event_loop_config = .{ .step_budget_max = 8 },
        .trace_config = .{ .max_events = 24 },
    });
    defer sim_fixture.deinit();

    var pending_storage: [6]durability.PendingOperation(u32) = undefined;
    var stored_storage: [4]durability.StoredValue(u32) = undefined;
    var simulator = try durability.StorageDurability(u32).init(&pending_storage, &stored_storage, .{
        .write_delay = .init(1),
        .read_delay = .init(1),
        .crash_behavior = .drop_pending_writes,
        .recoverability_policy = .stabilize_after_recover,
        .write_corruption = .{ .fixed_value = 700 },
        .read_corruption = .{ .fixed_value = 900 },
    });
    var completions = try testing.testing.sim.mailbox.Mailbox(
        durability.OperationResult(u32),
    ).init(std.heap.page_allocator, .{ .capacity = 6 });
    defer completions.deinit();

    try simulator.submitWrite(sim_fixture.sim_clock.now(), 1, 4, 111);
    _ = try sim_fixture.sim_clock.advance(.init(1));
    _ = try simulator.deliverDueToMailbox(
        sim_fixture.sim_clock.now(),
        &completions,
        sim_fixture.traceBufferPtr(),
    );
    const pre_crash = try completions.recv();
    assert(pre_crash.kind == .write);
    assert(pre_crash.status == .corrupted);
    assert(pre_crash.value.? == 700);

    assert(try simulator.crash(sim_fixture.sim_clock.now(), sim_fixture.traceBufferPtr()) == 0);
    try simulator.recover(sim_fixture.sim_clock.now(), sim_fixture.traceBufferPtr());

    try simulator.submitWrite(sim_fixture.sim_clock.now(), 2, 4, 222);
    _ = try sim_fixture.sim_clock.advance(.init(1));
    const write_summary = try simulator.deliverDueToMailbox(
        sim_fixture.sim_clock.now(),
        &completions,
        sim_fixture.traceBufferPtr(),
    );
    assert(write_summary.write_success_count == 1);
    const write = try completions.recv();
    assert(write.kind == .write);
    assert(write.status == .success);
    assert(write.value.? == 222);

    try simulator.submitRead(sim_fixture.sim_clock.now(), 3, 4);
    _ = try sim_fixture.sim_clock.advance(.init(1));
    const read_summary = try simulator.deliverDueToMailbox(
        sim_fixture.sim_clock.now(),
        &completions,
        sim_fixture.traceBufferPtr(),
    );
    assert(read_summary.read_success_count == 1);
    const read = try completions.recv();
    assert(read.kind == .read);
    assert(read.status == .success);
    assert(read.value.? == 222);

    const snapshot = sim_fixture.traceBufferPtr().?.snapshot();
    const crash_before_recover = try temporal.checkHappensBefore(
        snapshot,
        .{ .label = "storage_durability.crash", .surface_label = "storage_durability" },
        .{ .label = "storage_durability.recover", .surface_label = "storage_durability" },
    );
    assert(crash_before_recover.check_result.passed);

    const recover_before_write = try temporal.checkHappensBefore(
        snapshot,
        .{ .label = "storage_durability.recover", .surface_label = "storage_durability" },
        .{ .label = "storage_durability.write.success", .surface_label = "storage_durability" },
    );
    assert(recover_before_write.check_result.passed);

    std.debug.print(
        "storage durability corrupted the fault-phase write, then stabilized repair-phase write/read after recovery\n",
        .{},
    );
}
