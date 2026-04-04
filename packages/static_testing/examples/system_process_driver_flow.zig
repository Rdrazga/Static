const builtin = @import("builtin");
const std = @import("std");
const testing = @import("static_testing");
const example_options = @import("static_testing_example_options");

const process_driver = testing.testing.process_driver;
const system = testing.testing.system;
const temporal = testing.testing.temporal;

pub fn main() !void {
    if (builtin.os.tag == .wasi) return;

    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    var sim_fixture: testing.testing.sim.fixture.Fixture(4, 4, 4, 16) = undefined;
    try sim_fixture.init(.{
        .allocator = std.heap.page_allocator,
        .timer_queue_config = .{
            .buckets = 8,
            .timers_max = 8,
        },
        .scheduler_seed = .init(707),
        .scheduler_config = .{ .strategy = .first },
        .event_loop_config = .{ .step_budget_max = 8 },
        .trace_config = .{ .max_events = 16 },
    });
    defer sim_fixture.deinit();

    var response_mailbox = try testing.testing.sim.mailbox.Mailbox(u32).init(
        std.heap.page_allocator,
        .{ .capacity = 4 },
    );
    defer response_mailbox.deinit();

    const components = [_]system.ComponentSpec{
        .{ .name = "echo_driver" },
        .{ .name = "response_mailbox" },
    };
    const argv = [_][]const u8{ example_options.driver_echo_path, "echo" };
    const run_identity = testing.testing.identity.makeRunIdentity(.{
        .package_name = "static_testing",
        .run_name = "system_process_driver_flow_example",
        .seed = .init(707),
        .build_mode = .debug,
    });

    const Runner = struct {
        io: std.Io,
        argv: []const []const u8,
        mailbox: *testing.testing.sim.mailbox.Mailbox(u32),
        stderr_capture: [128]u8 = undefined,

        fn run(
            self: *@This(),
            context: *system.SystemContext(@TypeOf(sim_fixture)),
        ) anyerror!testing.testing.checker.CheckResult {
            std.debug.assert(context.hasComponent("echo_driver"));
            std.debug.assert(context.hasComponent("response_mailbox"));

            try context.traceBufferPtr().?.append(.{
                .timestamp_ns = context.fixture.sim_clock.now().tick,
                .category = .decision,
                .label = "system.start",
                .value = 1,
                .lineage = .{ .surface_label = "system" },
            });

            var driver = try process_driver.ProcessDriver.start(self.io, .{
                .argv = self.argv,
                .timeout_ns_max = 500 * std.time.ns_per_ms,
                .stderr_capture_buffer = &self.stderr_capture,
            });
            defer driver.deinit();

            const request_id = try driver.sendRequest(.echo, "hello");
            try context.traceBufferPtr().?.append(.{
                .timestamp_ns = context.fixture.sim_clock.now().tick,
                .category = .input,
                .label = "process.request",
                .value = request_id,
                .lineage = .{ .surface_label = "echo_driver" },
            });

            var payload_buffer: [16]u8 = undefined;
            const response = try driver.recvResponse(&payload_buffer);
            std.debug.assert(response.header.request_id == request_id);
            std.debug.assert(response.header.kind == .ok);
            std.debug.assert(std.mem.eql(u8, response.payload, "hello"));

            _ = try context.fixture.sim_clock.advance(.init(1));
            try context.traceBufferPtr().?.append(.{
                .timestamp_ns = context.fixture.sim_clock.now().tick,
                .category = .info,
                .label = "process.response",
                .value = response.payload.len,
                .lineage = .{
                    .cause_sequence_no = 1,
                    .surface_label = "echo_driver",
                },
            });

            try self.mailbox.send(@intCast(response.payload.len));
            const payload_len = try self.mailbox.recv();
            std.debug.assert(payload_len == response.payload.len);

            try driver.shutdown();

            const snapshot = context.traceSnapshot().?;
            const ordering = try temporal.checkHappensBefore(
                snapshot,
                .{ .label = "process.request", .surface_label = "echo_driver" },
                .{ .label = "process.response", .surface_label = "echo_driver" },
            );
            std.debug.assert(ordering.check_result.passed);

            const response_once = try temporal.checkExactlyOnce(
                snapshot,
                .{ .label = "process.response", .surface_label = "echo_driver" },
            );
            std.debug.assert(response_once.check_result.passed);

            return testing.testing.checker.CheckResult.pass(null);
        }
    };
    var runner = Runner{
        .io = threaded_io.io(),
        .argv = &argv,
        .mailbox = &response_mailbox,
    };

    const execution = try system.runWithFixture(@TypeOf(sim_fixture), Runner, anyerror, &sim_fixture, run_identity, .{
        .components = &components,
    }, &runner, Runner.run);

    std.debug.assert(execution.check_result.passed);
    std.debug.print(
        "system process flow passed run={s} components={} trace_events={}\n",
        .{ execution.run_identity.run_name, execution.component_count, execution.trace_metadata.event_count },
    );
}
