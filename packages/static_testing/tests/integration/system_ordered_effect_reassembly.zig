const std = @import("std");
const testing = std.testing;
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const ordered_effect = static_testing.testing.ordered_effect;
const system = static_testing.testing.system;
const temporal = static_testing.testing.temporal;

test "system harness reassembles out-of-order replies through ordered effect sequencing" {
    var sim_fixture: static_testing.testing.sim.fixture.Fixture(4, 4, 4, 24) = undefined;
    try sim_fixture.init(.{
        .allocator = testing.allocator,
        .timer_queue_config = .{
            .buckets = 8,
            .timers_max = 8,
        },
        .scheduler_seed = .init(919),
        .scheduler_config = .{ .strategy = .first },
        .event_loop_config = .{ .step_budget_max = 8 },
        .trace_config = .{ .max_events = 24 },
    });
    defer sim_fixture.deinit();

    var release_mailbox = try static_testing.testing.sim.mailbox.Mailbox(u32).init(
        testing.allocator,
        .{ .capacity = 4 },
    );
    defer release_mailbox.deinit();

    const components = [_]system.ComponentSpec{
        .{ .name = "ordered_effects" },
        .{ .name = "release_mailbox" },
    };
    const run_identity = static_testing.testing.identity.makeRunIdentity(.{
        .package_name = "static_testing",
        .run_name = "system_ordered_effect_reassembly",
        .seed = .init(919),
        .build_mode = .debug,
    });

    const Runner = struct {
        mailbox: *static_testing.testing.sim.mailbox.Mailbox(u32),
        sequencer: ordered_effect.OrderedEffectSequencer(u32, 4) = ordered_effect.OrderedEffectSequencer(u32, 4).init(),
        next_expected_effect_sequence_no: u64 = 0,
        next_trace_sequence_no: u32 = 0,
        arrival_trace_sequence_by_effect: [3]?u32 = [_]?u32{ null, null, null },

        const Arrival = struct {
            effect_sequence_no: u64,
            payload: u32,
        };

        fn run(
            self: *@This(),
            context: *system.SystemContext(@TypeOf(sim_fixture)),
        ) anyerror!checker.CheckResult {
            try testing.expect(context.hasComponent("ordered_effects"));
            try testing.expect(context.hasComponent("release_mailbox"));

            _ = try context.appendTraceEvent(
                &self.next_trace_sequence_no,
                "system.start",
                .decision,
                "system",
                null,
                1,
            );

            const arrivals = [_]Arrival{
                .{ .effect_sequence_no = 1, .payload = 22 },
                .{ .effect_sequence_no = 0, .payload = 11 },
                .{ .effect_sequence_no = 2, .payload = 33 },
            };

            for (arrivals) |arrival| {
                const arrival_trace_sequence_no = try context.appendTraceEvent(
                    &self.next_trace_sequence_no,
                    "reply.arrival",
                    .input,
                    "ordered_effects",
                    null,
                    arrival.payload,
                );
                self.arrival_trace_sequence_by_effect[@intCast(arrival.effect_sequence_no)] = arrival_trace_sequence_no;

                try testing.expectEqual(
                    ordered_effect.InsertStatus.accepted,
                    self.sequencer.insert(
                        self.next_expected_effect_sequence_no,
                        arrival.effect_sequence_no,
                        arrival.payload,
                    ),
                );

                while (self.sequencer.popReady(&self.next_expected_effect_sequence_no)) |ready| {
                    try self.mailbox.send(ready.effect);
                    _ = try context.fixture.sim_clock.advance(.init(1));
                    _ = try context.appendTraceEvent(
                        &self.next_trace_sequence_no,
                        "reply.release",
                        .info,
                        "ordered_effects",
                        self.arrival_trace_sequence_by_effect[@intCast(ready.sequence_no)].?,
                        ready.effect,
                    );
                }
            }

            try testing.expectEqual(@as(usize, 0), self.sequencer.pendingCount());
            try testing.expectEqual(@as(usize, 4), self.sequencer.free());
            try testing.expectEqual(@as(u32, 11), try self.mailbox.recv());
            try testing.expectEqual(@as(u32, 22), try self.mailbox.recv());
            try testing.expectEqual(@as(u32, 33), try self.mailbox.recv());

            const snapshot = context.traceSnapshot().?;

            const arrivals_out_of_order = try temporal.checkHappensBefore(
                snapshot,
                .{ .label = "reply.arrival", .surface_label = "ordered_effects", .value = 22 },
                .{ .label = "reply.arrival", .surface_label = "ordered_effects", .value = 11 },
            );
            try testing.expect(arrivals_out_of_order.check_result.passed);

            const first_release_before_second = try temporal.checkHappensBefore(
                snapshot,
                .{ .label = "reply.release", .surface_label = "ordered_effects", .value = 11 },
                .{ .label = "reply.release", .surface_label = "ordered_effects", .value = 22 },
            );
            try testing.expect(first_release_before_second.check_result.passed);

            const second_release_before_third = try temporal.checkHappensBefore(
                snapshot,
                .{ .label = "reply.release", .surface_label = "ordered_effects", .value = 22 },
                .{ .label = "reply.release", .surface_label = "ordered_effects", .value = 33 },
            );
            try testing.expect(second_release_before_third.check_result.passed);

            return checker.CheckResult.pass(null);
        }
    };

    var runner = Runner{
        .mailbox = &release_mailbox,
    };

    const execution = try system.runWithFixture(@TypeOf(sim_fixture), Runner, anyerror, &sim_fixture, run_identity, .{
        .components = &components,
    }, &runner, Runner.run);

    try testing.expect(execution.check_result.passed);
    try testing.expectEqual(@as(u32, 7), execution.trace_metadata.event_count);
}
