const std = @import("std");
const testing = @import("static_testing");

const network = testing.testing.sim.network_link;
const retry_mod = testing.testing.sim.retry_queue;
const storage_mod = testing.testing.sim.storage_lane;
const temporal = testing.testing.temporal;
const system = testing.testing.system;

pub fn main() !void {
    var sim_fixture: testing.testing.sim.fixture.Fixture(4, 4, 4, 32) = undefined;
    try sim_fixture.init(.{
        .allocator = std.heap.page_allocator,
        .timer_queue_config = .{
            .buckets = 8,
            .timers_max = 8,
        },
        .scheduler_seed = .init(990),
        .scheduler_config = .{ .strategy = .first },
        .event_loop_config = .{ .step_budget_max = 8 },
        .trace_config = .{ .max_events = 32 },
    });
    defer sim_fixture.deinit();

    var network_storage: [4]network.Delivery(u32) = undefined;
    var link = try network.NetworkLink(u32).init(&network_storage, .{
        .default_delay = .init(1),
    });
    var storage_pending: [4]storage_mod.PendingCompletion(u32) = undefined;
    var storage_lane = try storage_mod.StorageLane(u32).init(&storage_pending, .{
        .default_delay = .init(1),
    });
    var retry_pending: [4]retry_mod.PendingRetry(u32) = undefined;
    var retry_queue = try retry_mod.RetryQueue(u32).init(&retry_pending, .{
        .backoff = .init(1),
        .max_attempts = 2,
    });

    var request_mailbox = try testing.testing.sim.mailbox.Mailbox(u32).init(
        std.heap.page_allocator,
        .{ .capacity = 4 },
    );
    defer request_mailbox.deinit();
    var completion_mailbox = try testing.testing.sim.mailbox.Mailbox(
        storage_mod.OperationResult(u32),
    ).init(std.heap.page_allocator, .{ .capacity = 4 });
    defer completion_mailbox.deinit();
    var retry_mailbox = try testing.testing.sim.mailbox.Mailbox(
        retry_mod.RetryEnvelope(u32),
    ).init(std.heap.page_allocator, .{ .capacity = 4 });
    defer retry_mailbox.deinit();

    const components = [_]system.ComponentSpec{
        .{ .name = "network_link" },
        .{ .name = "storage_lane" },
        .{ .name = "retry_queue" },
    };
    const run_identity = testing.testing.identity.makeRunIdentity(.{
        .package_name = "static_testing",
        .run_name = "system_storage_retry_flow_example",
        .seed = .init(990),
        .build_mode = .debug,
    });

    const Runner = struct {
        link: *network.NetworkLink(u32),
        storage_lane: *storage_mod.StorageLane(u32),
        retry_queue: *retry_mod.RetryQueue(u32),
        request_mailbox: *testing.testing.sim.mailbox.Mailbox(u32),
        completion_mailbox: *testing.testing.sim.mailbox.Mailbox(storage_mod.OperationResult(u32)),
        retry_mailbox: *testing.testing.sim.mailbox.Mailbox(retry_mod.RetryEnvelope(u32)),

        fn run(
            self: *@This(),
            context: *system.SystemContext(@TypeOf(sim_fixture)),
        ) anyerror!testing.testing.checker.CheckResult {
            std.debug.assert(context.hasComponent("network_link"));
            std.debug.assert(context.hasComponent("storage_lane"));
            std.debug.assert(context.hasComponent("retry_queue"));

            try self.link.send(context.fixture.sim_clock.now(), 1, 11, 41);
            _ = try context.fixture.sim_clock.advance(.init(1));
            _ = try self.link.deliverDueToMailbox(context.fixture.sim_clock.now(), 11, self.request_mailbox, context.traceBufferPtr());
            std.debug.assert(try self.request_mailbox.recv() == 41);

            try self.storage_lane.submitFailure(context.fixture.sim_clock.now(), 41, 500);
            _ = try context.fixture.sim_clock.advance(.init(1));
            _ = try self.storage_lane.deliverDueToMailbox(context.fixture.sim_clock.now(), self.completion_mailbox, context.traceBufferPtr());
            const failed = try self.completion_mailbox.recv();
            std.debug.assert(failed.status == .failed);

            const retry_decision = try self.retry_queue.scheduleNext(context.fixture.sim_clock.now(), 0, failed.request_id, failed.request_id);
            std.debug.assert(retry_decision == .queued);
            _ = try context.fixture.sim_clock.advance(.init(1));
            std.debug.assert(try self.retry_queue.emitDueToMailbox(context.fixture.sim_clock.now(), self.retry_mailbox, context.traceBufferPtr()) == 1);
            const retry = try self.retry_mailbox.recv();
            std.debug.assert(retry.attempt == 1);

            try self.link.send(context.fixture.sim_clock.now(), 1, 11, retry.payload);
            _ = try context.fixture.sim_clock.advance(.init(1));
            _ = try self.link.deliverDueToMailbox(context.fixture.sim_clock.now(), 11, self.request_mailbox, context.traceBufferPtr());
            std.debug.assert(try self.request_mailbox.recv() == 41);

            try self.storage_lane.submitSuccess(context.fixture.sim_clock.now(), 41, 200);
            _ = try context.fixture.sim_clock.advance(.init(1));
            _ = try self.storage_lane.deliverDueToMailbox(context.fixture.sim_clock.now(), self.completion_mailbox, context.traceBufferPtr());
            const success = try self.completion_mailbox.recv();
            std.debug.assert(success.status == .success);

            const snapshot = context.traceSnapshot().?;
            const retry_before_success = try temporal.checkHappensBefore(
                snapshot,
                .{ .label = "retry_queue.emit", .surface_label = "retry_queue" },
                .{ .label = "storage_lane.success", .surface_label = "storage_lane" },
            );
            std.debug.assert(retry_before_success.check_result.passed);

            return testing.testing.checker.CheckResult.pass(null);
        }
    };
    var runner = Runner{
        .link = &link,
        .storage_lane = &storage_lane,
        .retry_queue = &retry_queue,
        .request_mailbox = &request_mailbox,
        .completion_mailbox = &completion_mailbox,
        .retry_mailbox = &retry_mailbox,
    };

    const execution = try system.runWithFixture(@TypeOf(sim_fixture), Runner, anyerror, &sim_fixture, run_identity, .{
        .components = &components,
    }, &runner, Runner.run);

    std.debug.assert(execution.check_result.passed);
    std.debug.print(
        "system flow passed run={s} components={} trace_events={}\n",
        .{ execution.run_identity.run_name, execution.component_count, execution.trace_metadata.event_count },
    );
}
