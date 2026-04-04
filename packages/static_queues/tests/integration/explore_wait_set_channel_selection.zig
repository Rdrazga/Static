const std = @import("std");
const static_queues = @import("static_queues");
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const explore = static_testing.testing.sim.explore;

const Channel = static_queues.channel.Channel(u8);
const WaitSet = static_queues.wait_set.WaitSet(u8, 2);

const violations = [_]checker.Violation{
    .{
        .code = "static_queues.wait_set_explore",
        .message = "wait set channel selection diverged from the bounded exploration invariant",
    },
};

test "wait set exploration keeps selection rotation and close semantics stable" {
    const Context = struct {
        fn run(_: *const anyopaque, input: explore.ExplorationScenarioInput) !explore.ExplorationScenarioExecution {
            var channel_a = try Channel.init(std.testing.allocator, .{ .capacity = 2 });
            defer channel_a.deinit();
            var channel_b = try Channel.init(std.testing.allocator, .{ .capacity = 2 });
            defer channel_b.deinit();

            var wait_set = WaitSet.init(.{});
            const source_a = try wait_set.registerChannel(&channel_a);
            const source_b = try wait_set.registerChannel(&channel_b);

            const check_result = switch (input.candidate.schedule_index) {
                0 => scenarioSendAThenB(&wait_set, &channel_a, &channel_b, source_a, source_b),
                1 => scenarioSendBThenA(&wait_set, &channel_a, &channel_b, source_a, source_b),
                2 => scenarioClosedPeerDoesNotBlockReadySource(&wait_set, &channel_a, &channel_b, source_a, source_b),
                3 => scenarioBufferedBeforeClosedThenAllClosed(&wait_set, &channel_a, &channel_b, source_a, source_b),
                else => checker.CheckResult.fail(&violations, null),
            };

            return .{
                .check_result = check_result,
                .recorded_decisions = &.{},
            };
        }

        fn scenarioSendAThenB(
            wait_set: *WaitSet,
            channel_a: *Channel,
            channel_b: *Channel,
            source_a: usize,
            source_b: usize,
        ) checker.CheckResult {
            channel_a.trySend(11) catch return checker.CheckResult.fail(&violations, null);
            channel_b.trySend(22) catch return checker.CheckResult.fail(&violations, null);

            const first = wait_set.tryRecvAny() catch return checker.CheckResult.fail(&violations, null);
            const second = wait_set.tryRecvAny() catch return checker.CheckResult.fail(&violations, null);

            if (first.source_index != source_a or first.value != 11) {
                return checker.CheckResult.fail(&violations, null);
            }
            if (second.source_index != source_b or second.value != 22) {
                return checker.CheckResult.fail(&violations, null);
            }
            if (first.source_index == second.source_index) {
                return checker.CheckResult.fail(&violations, null);
            }
            if (wait_set.tryRecvAny()) |_| {
                return checker.CheckResult.fail(&violations, null);
            } else |err| switch (err) {
                error.WouldBlock => {},
                else => return checker.CheckResult.fail(&violations, null),
            }
            return checker.CheckResult.pass(checker.CheckpointDigest.init(
                (@as(u128, first.source_index) << 96) |
                    (@as(u128, first.value) << 64) |
                    (@as(u128, second.source_index) << 32) |
                    @as(u128, second.value),
            ));
        }

        fn scenarioSendBThenA(
            wait_set: *WaitSet,
            channel_a: *Channel,
            channel_b: *Channel,
            source_a: usize,
            source_b: usize,
        ) checker.CheckResult {
            channel_b.trySend(31) catch return checker.CheckResult.fail(&violations, null);
            channel_a.trySend(41) catch return checker.CheckResult.fail(&violations, null);

            const first = wait_set.tryRecvAny() catch return checker.CheckResult.fail(&violations, null);
            const second = wait_set.tryRecvAny() catch return checker.CheckResult.fail(&violations, null);

            if (first.source_index != source_a or first.value != 41) {
                return checker.CheckResult.fail(&violations, null);
            }
            if (second.source_index != source_b or second.value != 31) {
                return checker.CheckResult.fail(&violations, null);
            }
            if (first.source_index == second.source_index) {
                return checker.CheckResult.fail(&violations, null);
            }
            return checker.CheckResult.pass(checker.CheckpointDigest.init(
                (@as(u128, first.source_index) << 96) |
                    (@as(u128, first.value) << 64) |
                    (@as(u128, second.source_index) << 32) |
                    @as(u128, second.value),
            ));
        }

        fn scenarioClosedPeerDoesNotBlockReadySource(
            wait_set: *WaitSet,
            channel_a: *Channel,
            channel_b: *Channel,
            source_a: usize,
            source_b: usize,
        ) checker.CheckResult {
            channel_b.trySend(51) catch return checker.CheckResult.fail(&violations, null);
            channel_a.close();

            const selected = wait_set.tryRecvAny() catch return checker.CheckResult.fail(&violations, null);
            if (selected.source_index != source_b or selected.value != 51) {
                return checker.CheckResult.fail(&violations, null);
            }

            if (wait_set.tryRecvAny()) |_| {
                return checker.CheckResult.fail(&violations, null);
            } else |err| switch (err) {
                error.WouldBlock => {},
                else => return checker.CheckResult.fail(&violations, null),
            }

            channel_b.close();
            if (wait_set.tryRecvAny()) |_| {
                return checker.CheckResult.fail(&violations, null);
            } else |err| switch (err) {
                error.Closed => {},
                else => return checker.CheckResult.fail(&violations, null),
            }

            return checker.CheckResult.pass(checker.CheckpointDigest.init(
                (@as(u128, source_a) << 96) |
                    (@as(u128, source_b) << 64) |
                    (@as(u128, selected.source_index) << 32) |
                    @as(u128, selected.value),
            ));
        }

        fn scenarioBufferedBeforeClosedThenAllClosed(
            wait_set: *WaitSet,
            channel_a: *Channel,
            channel_b: *Channel,
            source_a: usize,
            _: usize,
        ) checker.CheckResult {
            channel_a.trySend(61) catch return checker.CheckResult.fail(&violations, null);
            channel_a.close();

            const selected = wait_set.tryRecvAny() catch return checker.CheckResult.fail(&violations, null);
            if (selected.source_index != source_a or selected.value != 61) {
                return checker.CheckResult.fail(&violations, null);
            }

            if (wait_set.tryRecvAny()) |_| {
                return checker.CheckResult.fail(&violations, null);
            } else |err| switch (err) {
                error.WouldBlock => {},
                else => return checker.CheckResult.fail(&violations, null),
            }

            channel_b.close();
            if (wait_set.tryRecvAny()) |_| {
                return checker.CheckResult.fail(&violations, null);
            } else |err| switch (err) {
                error.Closed => {},
                else => return checker.CheckResult.fail(&violations, null),
            }

            return checker.CheckResult.pass(checker.CheckpointDigest.init(
                (@as(u128, selected.source_index) << 32) | @as(u128, selected.value),
            ));
        }
    };

    const scenario = explore.ExplorationScenario(anyerror){
        .context = undefined,
        .run_fn = Context.run,
    };

    const summary = try explore.runExploration(anyerror, .{
        .base_seed = .init(0x17b4_2026_0000_8401),
        .schedules_max = 4,
    }, scenario, null);

    try std.testing.expectEqual(@as(u32, 4), summary.executed_schedule_count);
    try std.testing.expectEqual(@as(u32, 0), summary.failed_schedule_count);
    try std.testing.expect(summary.first_failure == null);
}
