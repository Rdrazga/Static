const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const static_net_native = @import("static_net_native");
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const identity = static_testing.testing.identity;
const sim = static_testing.testing.sim;
const system = static_testing.testing.system;
const temporal = static_testing.testing.temporal;
const support = @import("support.zig");

const Fixture = sim.fixture.Fixture(4, 4, 4, 24);

const components = [_]system.ComponentSpec{
    .{ .name = "listener" },
    .{ .name = "client" },
    .{ .name = "accepted" },
};

const loopback_violation = [_]checker.Violation{
    .{
        .code = "static_net_native.loopback_endpoints",
        .message = "native loopback socket endpoint queries lost local/peer agreement",
    },
};

const NativeModule = switch (builtin.os.tag) {
    .windows => static_net_native.windows,
    .linux => static_net_native.linux,
    else => static_net_native.posix,
};

const Runner = struct {
    io: std.Io,
    next_sequence_no: u32 = 0,

    fn run(
        self: *@This(),
        context: *system.SystemContext(Fixture),
    ) anyerror!checker.CheckResult {
        assert(context.hasComponent("listener"));
        assert(context.hasComponent("client"));
        assert(context.hasComponent("accepted"));
        assert(context.traceBufferPtr() != null);

        var listener = try std.Io.net.IpAddress.listen(.{ .ip4 = .loopback(0) }, self.io, .{
            .reuse_address = true,
            .mode = .stream,
            .protocol = .tcp,
        });
        defer listener.deinit(self.io);

        const expected_listener = support.endpointFromIoAddress(listener.socket.address);
        const listener_local = NativeModule.socketLocalEndpoint(listener.socket.handle) orelse
            return checker.CheckResult.fail(&loopback_violation, null);
        const listener_local_seq = try support.appendEvent(
            context,
            &self.next_sequence_no,
            "native.listener.bound",
            .check,
            "listener",
            null,
            support.digestEndpoint(listener_local),
        );
        try testing.expect(std.meta.eql(expected_listener, listener_local));
        try testing.expect(NativeModule.socketPeerEndpoint(listener.socket.handle) == null);

        _ = try context.fixture.sim_clock.advance(.init(1));
        var client = try std.Io.net.IpAddress.connect(listener.socket.address, self.io, .{
            .mode = .stream,
            .protocol = .tcp,
        });
        defer client.close(self.io);

        var accepted = try listener.accept(self.io);
        defer accepted.close(self.io);

        const client_local = NativeModule.socketLocalEndpoint(client.socket.handle) orelse
            return checker.CheckResult.fail(&loopback_violation, null);
        const client_peer = NativeModule.socketPeerEndpoint(client.socket.handle) orelse
            return checker.CheckResult.fail(&loopback_violation, null);
        const client_connect_seq = try support.appendEvent(
            context,
            &self.next_sequence_no,
            "native.client.connected",
            .check,
            "client",
            listener_local_seq,
            support.digestEndpoint(client_local),
        );

        _ = try context.fixture.sim_clock.advance(.init(1));
        const accepted_local = NativeModule.socketLocalEndpoint(accepted.socket.handle) orelse
            return checker.CheckResult.fail(&loopback_violation, null);
        const accepted_peer = NativeModule.socketPeerEndpoint(accepted.socket.handle) orelse
            return checker.CheckResult.fail(&loopback_violation, null);
        const accepted_seq = try support.appendEvent(
            context,
            &self.next_sequence_no,
            "native.accepted.ready",
            .check,
            "accepted",
            client_connect_seq,
            support.digestEndpoint(accepted_peer),
        );

        if (!std.meta.eql(expected_listener, listener_local) or
            !std.meta.eql(expected_listener, accepted_local) or
            !std.meta.eql(client_peer, accepted_local) or
            !std.meta.eql(accepted_peer, client_local))
        {
            return checker.CheckResult.fail(
                &loopback_violation,
                checker.CheckpointDigest.init(
                    (@as(u128, support.digestEndpoint(listener_local)) << 64) |
                        @as(u128, support.digestEndpoint(client_peer)),
                ),
            );
        }

        _ = try context.fixture.sim_clock.advance(.init(1));
        _ = try support.appendEvent(
            context,
            &self.next_sequence_no,
            "native.endpoint.verified",
            .check,
            "accepted",
            accepted_seq,
            support.digestEndpoint(accepted_local),
        );

        if (builtin.os.tag == .windows) {
            try testing.expectEqual(
                std.os.windows.ws2_32.AF.INET,
                static_net_native.windows.socketFamily(listener.socket.handle).?,
            );
            try testing.expectEqual(
                std.os.windows.ws2_32.AF.INET,
                static_net_native.windows.socketFamily(client.socket.handle).?,
            );
            try testing.expectEqual(
                std.os.windows.ws2_32.AF.INET,
                static_net_native.windows.socketFamily(accepted.socket.handle).?,
            );
        }

        const snapshot = context.traceSnapshot().?;
        const bound_before_connect = try temporal.checkHappensBefore(
            snapshot,
            .{ .label = "native.listener.bound", .surface_label = "listener" },
            .{ .label = "native.client.connected", .surface_label = "client" },
        );
        if (!bound_before_connect.check_result.passed) return bound_before_connect.check_result;

        const connect_before_verify = try temporal.checkHappensBefore(
            snapshot,
            .{ .label = "native.client.connected", .surface_label = "client" },
            .{ .label = "native.endpoint.verified", .surface_label = "accepted" },
        );
        if (!connect_before_verify.check_result.passed) return connect_before_verify.check_result;

        const verified_once = try temporal.checkExactlyOnce(snapshot, .{
            .label = "native.endpoint.verified",
            .surface_label = "accepted",
        });
        if (!verified_once.check_result.passed) return verified_once.check_result;

        return checker.CheckResult.pass(checker.CheckpointDigest.init(
            (@as(u128, support.digestEndpoint(client_local)) << 64) |
                @as(u128, support.digestEndpoint(accepted_local)),
        ));
    }
};

test "static_net_native testing.system covers native loopback endpoint queries" {
    var threaded_io = std.Io.Threaded.init(testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    var fixture: Fixture = undefined;
    try fixture.init(.{
        .allocator = testing.allocator,
        .timer_queue_config = .{ .buckets = 8, .timers_max = 8 },
        .scheduler_seed = .init(991),
        .scheduler_config = .{ .strategy = .first },
        .event_loop_config = .{ .step_budget_max = 8 },
        .trace_config = .{ .max_events = 24 },
    });
    defer fixture.deinit();

    var runner = Runner{
        .io = threaded_io.io(),
    };
    const run_identity = identity.makeRunIdentity(.{
        .package_name = "static_net_native",
        .run_name = "loopback_endpoint_queries",
        .seed = .init(0x6e47_6e61_7469_0003),
        .build_mode = .debug,
    });

    const execution = try system.runWithFixture(Fixture, Runner, anyerror, &fixture, run_identity, .{
        .components = &components,
    }, &runner, Runner.run);

    try testing.expect(execution.check_result.passed);
    try testing.expectEqual(@as(usize, components.len), execution.component_count);
    try testing.expect(execution.trace_metadata.event_count >= 4);
    try testing.expect(execution.retained_bundle == null);
}
