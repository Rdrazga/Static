//! Bounded deterministic system/e2e composition harness over shared simulation,
//! trace, and failure-bundle surfaces.

const std = @import("std");
const checker = @import("checker.zig");
const failure_bundle = @import("failure_bundle.zig");
const identity = @import("identity.zig");
const liveness = @import("liveness.zig");
const trace = @import("trace.zig");

pub const SystemHarnessError = error{
    InvalidConfig,
} || failure_bundle.FailureBundleWriteError;

pub const ComponentSpec = struct {
    name: []const u8,
};

pub const SystemTraceArtifact = enum(u8) {
    none = 0,
    summary = 1,
    retained = 2,
    summary_and_retained = 3,

    fn writeSummary(self: @This()) bool {
        return self == .summary or self == .summary_and_retained;
    }

    fn writeRetained(self: @This()) bool {
        return self == .retained or self == .summary_and_retained;
    }
};

pub const SystemArtifactSelection = struct {
    trace_artifact: SystemTraceArtifact = .summary,
};

pub const SystemFailurePersistence = struct {
    bundle_persistence: failure_bundle.FailureBundlePersistence,
    artifact_selection: SystemArtifactSelection = .{},
    stdout_capture: ?failure_bundle.FailureBundleTextCapture = null,
    stderr_capture: ?failure_bundle.FailureBundleTextCapture = null,
};

pub const SystemHarnessConfig = struct {
    components: []const ComponentSpec,
    failure_persistence: ?SystemFailurePersistence = null,
};

pub const SystemRepairLivenessConfig = struct {
    components: []const ComponentSpec,
    liveness_config: liveness.RepairLivenessConfig,
    failure_persistence: ?SystemFailurePersistence = null,
};

pub const SystemExecution = struct {
    run_identity: identity.RunIdentity,
    component_count: usize,
    trace_metadata: trace.TraceMetadata,
    check_result: checker.CheckResult,
    retained_bundle: ?failure_bundle.FailureBundleMeta = null,
};

pub const SystemRepairLivenessExecution = struct {
    run_identity: identity.RunIdentity,
    component_count: usize,
    trace_metadata: trace.TraceMetadata,
    summary: liveness.RepairLivenessSummary,
    retained_bundle: ?failure_bundle.FailureBundleMeta = null,
};

pub fn SystemContext(comptime FixtureType: type) type {
    return struct {
        const Self = @This();

        run_identity: identity.RunIdentity,
        fixture: *FixtureType,
        components: []const ComponentSpec,

        pub fn hasComponent(self: Self, name: []const u8) bool {
            std.debug.assert(name.len > 0);
            for (self.components) |component| {
                if (std.mem.eql(u8, component.name, name)) return true;
            }
            return false;
        }

        pub fn traceBufferPtr(self: *Self) ?*trace.TraceBuffer {
            return self.fixture.traceBufferPtr();
        }

        pub fn traceSnapshot(self: *Self) ?trace.TraceSnapshot {
            if (self.traceBufferPtr()) |buffer| return buffer.snapshot();
            return null;
        }

        pub fn appendTraceEvent(
            self: *Self,
            next_sequence_no: *u32,
            label: []const u8,
            category: trace.TraceCategory,
            surface_label: []const u8,
            cause_sequence_no: ?u32,
            value: u64,
        ) trace.TraceAppendError!u32 {
            std.debug.assert(label.len > 0);
            std.debug.assert(surface_label.len > 0);
            std.debug.assert(self.traceBufferPtr() != null);

            const sequence_no = next_sequence_no.*;
            next_sequence_no.* += 1;
            try self.traceBufferPtr().?.append(.{
                .timestamp_ns = self.fixture.sim_clock.now().tick,
                .category = category,
                .label = label,
                .value = value,
                .lineage = .{
                    .cause_sequence_no = cause_sequence_no,
                    .surface_label = surface_label,
                },
            });
            return sequence_no;
        }
    };
}

pub fn SystemRepairLivenessRunner(
    comptime FixtureType: type,
    comptime UserContext: type,
    comptime RunError: type,
) type {
    return struct {
        const Self = @This();

        run_fault_phase_fn: *const fn (*UserContext, *SystemContext(FixtureType), u32) RunError!liveness.PhaseExecution,
        transition_to_repair_fn: *const fn (*UserContext, *SystemContext(FixtureType)) void,
        run_repair_phase_fn: *const fn (*UserContext, *SystemContext(FixtureType), u32) RunError!liveness.PhaseExecution,
        pending_reason_fn: *const fn (*UserContext, *SystemContext(FixtureType)) RunError!?liveness.PendingReasonDetail,

        pub fn runFaultPhase(
            self: Self,
            user_context: *UserContext,
            system_context: *SystemContext(FixtureType),
            steps_max: u32,
        ) RunError!liveness.PhaseExecution {
            return self.run_fault_phase_fn(user_context, system_context, steps_max);
        }

        pub fn transitionToRepair(
            self: Self,
            user_context: *UserContext,
            system_context: *SystemContext(FixtureType),
        ) void {
            self.transition_to_repair_fn(user_context, system_context);
        }

        pub fn runRepairPhase(
            self: Self,
            user_context: *UserContext,
            system_context: *SystemContext(FixtureType),
            steps_max: u32,
        ) RunError!liveness.PhaseExecution {
            return self.run_repair_phase_fn(user_context, system_context, steps_max);
        }

        pub fn pendingReason(
            self: Self,
            user_context: *UserContext,
            system_context: *SystemContext(FixtureType),
        ) RunError!?liveness.PendingReasonDetail {
            return self.pending_reason_fn(user_context, system_context);
        }
    };
}

pub fn runWithFixture(
    comptime FixtureType: type,
    comptime UserContext: type,
    comptime RunError: type,
    fixture: *FixtureType,
    run_identity: identity.RunIdentity,
    config: SystemHarnessConfig,
    user_context: *UserContext,
    run_fn: *const fn (*UserContext, *SystemContext(FixtureType)) RunError!checker.CheckResult,
) (RunError || SystemHarnessError)!SystemExecution {
    try validateConfig(FixtureType, fixture, config);

    var context = SystemContext(FixtureType){
        .run_identity = run_identity,
        .fixture = fixture,
        .components = config.components,
    };
    const check_result = try run_fn(user_context, &context);
    assertCheckResult(check_result);

    const snapshot = context.traceSnapshot();
    const trace_metadata = if (snapshot) |trace_snapshot|
        trace_snapshot.metadata()
    else
        emptyTraceMetadata();

    const retained_bundle = if (!check_result.passed)
        if (config.failure_persistence) |persistence|
            try persistFailureBundle(run_identity, trace_metadata, check_result, persistence, snapshot, null)
        else
            null
    else
        null;

    return .{
        .run_identity = run_identity,
        .component_count = config.components.len,
        .trace_metadata = trace_metadata,
        .check_result = check_result,
        .retained_bundle = retained_bundle,
    };
}

pub fn runRepairLivenessWithFixture(
    comptime FixtureType: type,
    comptime UserContext: type,
    comptime RunError: type,
    fixture: *FixtureType,
    run_identity: identity.RunIdentity,
    config: SystemRepairLivenessConfig,
    user_context: *UserContext,
    runner: SystemRepairLivenessRunner(FixtureType, UserContext, RunError),
) (RunError || SystemHarnessError || liveness.RepairLivenessError)!SystemRepairLivenessExecution {
    try validateConfig(FixtureType, fixture, .{
        .components = config.components,
        .failure_persistence = config.failure_persistence,
    });

    var system_context = SystemContext(FixtureType){
        .run_identity = run_identity,
        .fixture = fixture,
        .components = config.components,
    };
    const Bridge = struct {
        user_context: *UserContext,
        system_context: *SystemContext(FixtureType),
        runner: SystemRepairLivenessRunner(FixtureType, UserContext, RunError),

        fn runFaultPhase(context: *anyopaque, steps_max: u32) RunError!liveness.PhaseExecution {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.runner.runFaultPhase(self.user_context, self.system_context, steps_max);
        }

        fn transitionToRepair(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.runner.transitionToRepair(self.user_context, self.system_context);
        }

        fn runRepairPhase(context: *anyopaque, steps_max: u32) RunError!liveness.PhaseExecution {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.runner.runRepairPhase(self.user_context, self.system_context, steps_max);
        }

        fn pendingReason(context: *anyopaque) RunError!?liveness.PendingReasonDetail {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.runner.pendingReason(self.user_context, self.system_context);
        }
    };

    var bridge = Bridge{
        .user_context = user_context,
        .system_context = &system_context,
        .runner = runner,
    };
    const summary = try liveness.runRepairLiveness(RunError, config.liveness_config, .{
        .context = &bridge,
        .run_fault_phase_fn = Bridge.runFaultPhase,
        .transition_to_repair_fn = Bridge.transitionToRepair,
        .run_repair_phase_fn = Bridge.runRepairPhase,
        .pending_reason_fn = Bridge.pendingReason,
    });

    const snapshot = system_context.traceSnapshot();
    const trace_metadata = if (snapshot) |trace_snapshot|
        trace_snapshot.metadata()
    else
        emptyTraceMetadata();

    var pending_violation_storage = [_]checker.Violation{undefined};
    var pending_message_buffer: [160]u8 = undefined;
    const retained_bundle = if (!summary.converged)
        if (config.failure_persistence) |persistence|
            try persistFailureBundle(
                run_identity,
                trace_metadata,
                systemRepairLivenessFailureCheckResult(
                    summary,
                    &pending_violation_storage,
                    &pending_message_buffer,
                ),
                persistence,
                snapshot,
                summary.pending_reason,
            )
        else
            null
    else
        null;

    return .{
        .run_identity = run_identity,
        .component_count = config.components.len,
        .trace_metadata = trace_metadata,
        .summary = summary,
        .retained_bundle = retained_bundle,
    };
}

fn validateConfig(
    comptime FixtureType: type,
    fixture: *FixtureType,
    config: SystemHarnessConfig,
) SystemHarnessError!void {
    if (config.components.len == 0) return error.InvalidConfig;

    for (config.components, 0..) |component, index| {
        if (component.name.len == 0) return error.InvalidConfig;

        var other_index: usize = 0;
        while (other_index < index) : (other_index += 1) {
            if (std.mem.eql(u8, component.name, config.components[other_index].name)) {
                return error.InvalidConfig;
            }
        }
    }

    if (config.failure_persistence) |persistence| {
        if (persistence.artifact_selection.trace_artifact.writeRetained() and fixture.traceBufferPtr() == null) {
            return error.InvalidConfig;
        }
    }
}

fn persistFailureBundle(
    run_identity: identity.RunIdentity,
    trace_metadata: trace.TraceMetadata,
    check_result: checker.CheckResult,
    persistence: SystemFailurePersistence,
    snapshot: ?trace.TraceSnapshot,
    pending_reason: ?liveness.PendingReasonDetail,
) SystemHarnessError!failure_bundle.FailureBundleMeta {
    return failure_bundle.writeFailureBundle(
        persistence.bundle_persistence,
        run_identity,
        trace_metadata,
        check_result,
        makeFailureBundleContext(persistence, snapshot, pending_reason),
    );
}

fn makeFailureBundleContext(
    persistence: SystemFailurePersistence,
    snapshot: ?trace.TraceSnapshot,
    pending_reason: ?liveness.PendingReasonDetail,
) failure_bundle.FailureBundleContext {
    return .{
        .artifact_selection = .{
            .trace_artifact = switch (persistence.artifact_selection.trace_artifact) {
                .none => .none,
                .summary => .summary,
                .retained => .retained,
                .summary_and_retained => .summary_and_retained,
            },
        },
        .pending_reason = pending_reason,
        .trace_provenance_summary = if (snapshot) |trace_snapshot| trace_snapshot.provenanceSummary() else null,
        .retained_trace_snapshot = if (persistence.artifact_selection.trace_artifact.writeRetained()) snapshot else null,
        .stdout_capture = persistence.stdout_capture,
        .stderr_capture = persistence.stderr_capture,
    };
}

fn systemRepairLivenessFailureCheckResult(
    summary: liveness.RepairLivenessSummary,
    violation_storage: *[1]checker.Violation,
    message_buffer: []u8,
) checker.CheckResult {
    if (!summary.fault_phase.check_result.passed) {
        return summary.fault_phase.check_result;
    }
    if (summary.repair_phase) |repair_phase| {
        if (!repair_phase.check_result.passed) {
            return repair_phase.check_result;
        }
    }

    const pending_reason = summary.pending_reason orelse return checker.CheckResult.pass(null);
    violation_storage[0] = .{
        .code = "system_repair_liveness.pending_reason",
        .message = formatPendingReasonMessage(message_buffer, pending_reason),
    };
    return checker.CheckResult.fail(violation_storage, null);
}

fn formatPendingReasonMessage(
    buffer: []u8,
    pending_reason: liveness.PendingReasonDetail,
) []const u8 {
    if (pending_reason.label) |label| {
        return std.fmt.bufPrint(
            buffer,
            "repair phase still pending: {s} count={d} value={d} label={s}",
            .{
                @tagName(pending_reason.reason),
                pending_reason.count,
                pending_reason.value,
                label,
            },
        ) catch "repair phase still pending";
    }
    return std.fmt.bufPrint(
        buffer,
        "repair phase still pending: {s} count={d} value={d}",
        .{
            @tagName(pending_reason.reason),
            pending_reason.count,
            pending_reason.value,
        },
    ) catch "repair phase still pending";
}

fn assertCheckResult(check_result: checker.CheckResult) void {
    if (check_result.passed) {
        std.debug.assert(check_result.violations.len == 0);
    } else {
        std.debug.assert(check_result.violations.len > 0);
    }
}

fn emptyTraceMetadata() trace.TraceMetadata {
    return .{
        .event_count = 0,
        .truncated = false,
        .has_range = false,
        .first_sequence_no = 0,
        .last_sequence_no = 0,
        .first_timestamp_ns = 0,
        .last_timestamp_ns = 0,
    };
}

test "runWithFixture rejects duplicate component names" {
    const sim = @import("sim/root.zig");

    var fixture: sim.fixture.Fixture(4, 4, 4, 0) = undefined;
    try fixture.init(.{
        .allocator = std.testing.allocator,
        .timer_queue_config = .{ .buckets = 4, .timers_max = 4 },
        .scheduler_seed = .init(1),
        .event_loop_config = .{ .step_budget_max = 4 },
    });
    defer fixture.deinit();

    const components = [_]ComponentSpec{
        .{ .name = "network" },
        .{ .name = "network" },
    };

    const run_identity = identity.makeRunIdentity(.{
        .package_name = "static_testing",
        .run_name = "system_duplicate_component_names",
        .seed = .init(1),
        .build_mode = .debug,
    });

    const Context = struct {
        fn run(_: *void, _: *SystemContext(@TypeOf(fixture))) error{}!checker.CheckResult {
            return checker.CheckResult.pass(null);
        }
    };
    var user_context = {};

    try std.testing.expectError(
        error.InvalidConfig,
        runWithFixture(@TypeOf(fixture), void, error{}, &fixture, run_identity, .{
            .components = &components,
        }, &user_context, Context.run),
    );
}

test "runWithFixture shares run identity and persists failure bundles" {
    const sim = @import("sim/root.zig");

    var fixture: sim.fixture.Fixture(4, 4, 4, 8) = undefined;
    try fixture.init(.{
        .allocator = std.testing.allocator,
        .timer_queue_config = .{ .buckets = 4, .timers_max = 4 },
        .scheduler_seed = .init(3),
        .event_loop_config = .{ .step_budget_max = 4 },
        .trace_config = .{ .max_events = 8 },
    });
    defer fixture.deinit();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    var entry_name_buffer: [128]u8 = undefined;
    var artifact_buffer: [256]u8 = undefined;
    var manifest_buffer: [2048]u8 = undefined;
    var trace_buffer_storage: [512]u8 = undefined;
    var retained_trace_file_buffer: [2048]u8 = undefined;
    var retained_trace_frame_buffer: [512]u8 = undefined;
    var violations_buffer: [1024]u8 = undefined;

    const io = threaded_io.io();
    const components = [_]ComponentSpec{
        .{ .name = "network" },
        .{ .name = "storage" },
    };
    const run_identity = identity.makeRunIdentity(.{
        .package_name = "static_testing",
        .run_name = "system_failure_bundle",
        .seed = .init(5),
        .build_mode = .debug,
        .case_index = 1,
        .run_index = 2,
    });
    const violations = [_]checker.Violation{
        .{ .code = "system_failure", .message = "component flow failed" },
    };

    const Context = struct {
        fn run(_: *void, context: *SystemContext(@TypeOf(fixture))) anyerror!checker.CheckResult {
            try std.testing.expect(context.hasComponent("network"));
            try std.testing.expect(context.hasComponent("storage"));
            try std.testing.expectEqualStrings("system_failure_bundle", context.run_identity.run_name);

            try context.traceBufferPtr().?.append(.{
                .timestamp_ns = context.fixture.sim_clock.now().tick,
                .category = .decision,
                .label = "system.start",
                .value = 1,
            });
            try context.traceBufferPtr().?.append(.{
                .timestamp_ns = context.fixture.sim_clock.now().tick,
                .category = .check,
                .label = "system.failed",
                .value = 1,
                .lineage = .{
                    .cause_sequence_no = 0,
                    .surface_label = "system",
                },
            });

            return checker.CheckResult.fail(&violations, null);
        }
    };
    var user_context = {};

    const execution = try runWithFixture(@TypeOf(fixture), void, anyerror, &fixture, run_identity, .{
        .components = &components,
        .failure_persistence = .{
            .bundle_persistence = .{
                .io = io,
                .dir = tmp_dir.dir,
                .entry_name_buffer = &entry_name_buffer,
                .artifact_buffer = &artifact_buffer,
                .manifest_buffer = &manifest_buffer,
                .trace_buffer = &trace_buffer_storage,
                .retained_trace_file_buffer = &retained_trace_file_buffer,
                .retained_trace_frame_buffer = &retained_trace_frame_buffer,
                .violations_buffer = &violations_buffer,
            },
            .artifact_selection = .{ .trace_artifact = .summary_and_retained },
        },
    }, &user_context, Context.run);

    try std.testing.expect(!execution.check_result.passed);
    try std.testing.expect(execution.retained_bundle != null);
    try std.testing.expectEqual(@as(u32, 2), execution.trace_metadata.event_count);

    var read_artifact_buffer: [256]u8 = undefined;
    var read_manifest_source: [failure_bundle.recommended_manifest_source_len]u8 = undefined;
    var read_manifest_parse: [failure_bundle.recommended_manifest_parse_len]u8 = undefined;
    var read_trace_source: [failure_bundle.recommended_trace_source_len]u8 = undefined;
    var read_trace_parse: [failure_bundle.recommended_trace_parse_len]u8 = undefined;
    var read_retained_trace_file: [2048]u8 = undefined;
    var read_retained_events: [8]trace.TraceEvent = undefined;
    var read_retained_labels: [512]u8 = undefined;
    var read_violations_source: [failure_bundle.recommended_violations_source_len]u8 = undefined;
    var read_violations_parse: [failure_bundle.recommended_violations_parse_len]u8 = undefined;

    const bundle = try failure_bundle.readFailureBundle(io, tmp_dir.dir, execution.retained_bundle.?.entry_name, .{
        .selection = .{
            .trace_artifact = .summary_and_retained,
            .text_capture = .none,
        },
        .artifact_buffer = &read_artifact_buffer,
        .manifest_buffer = &read_manifest_source,
        .manifest_parse_buffer = &read_manifest_parse,
        .trace_buffer = &read_trace_source,
        .trace_parse_buffer = &read_trace_parse,
        .retained_trace_file_buffer = &read_retained_trace_file,
        .retained_trace_events_buffer = &read_retained_events,
        .retained_trace_label_buffer = &read_retained_labels,
        .violations_buffer = &read_violations_source,
        .violations_parse_buffer = &read_violations_parse,
    });

    try std.testing.expectEqualStrings("system_failure_bundle", bundle.manifest_document.run_name);
    try std.testing.expect(bundle.trace_document != null);
    try std.testing.expect(bundle.retained_trace != null);
    try std.testing.expectEqual(@as(usize, 2), bundle.retained_trace.?.items.len);
    try std.testing.expectEqualStrings("system_failure", bundle.violations_document.violations[0].code);
}

test "runWithFixture rejects retained traces without trace storage" {
    const sim = @import("sim/root.zig");

    var fixture: sim.fixture.Fixture(4, 4, 4, 0) = undefined;
    try fixture.init(.{
        .allocator = std.testing.allocator,
        .timer_queue_config = .{ .buckets = 4, .timers_max = 4 },
        .scheduler_seed = .init(9),
        .event_loop_config = .{ .step_budget_max = 4 },
    });
    defer fixture.deinit();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    var entry_name_buffer: [128]u8 = undefined;
    var artifact_buffer: [256]u8 = undefined;
    var manifest_buffer: [1024]u8 = undefined;
    var trace_buffer_storage: [256]u8 = undefined;
    var violations_buffer: [256]u8 = undefined;

    const components = [_]ComponentSpec{
        .{ .name = "network" },
    };
    const run_identity = identity.makeRunIdentity(.{
        .package_name = "static_testing",
        .run_name = "system_retained_without_trace",
        .seed = .init(9),
        .build_mode = .debug,
    });

    const Context = struct {
        fn run(_: *void, _: *SystemContext(@TypeOf(fixture))) error{}!checker.CheckResult {
            return checker.CheckResult.pass(null);
        }
    };
    var user_context = {};

    try std.testing.expectError(
        error.InvalidConfig,
        runWithFixture(@TypeOf(fixture), void, error{}, &fixture, run_identity, .{
            .components = &components,
            .failure_persistence = .{
                .bundle_persistence = .{
                    .io = threaded_io.io(),
                    .dir = tmp_dir.dir,
                    .entry_name_buffer = &entry_name_buffer,
                    .artifact_buffer = &artifact_buffer,
                    .manifest_buffer = &manifest_buffer,
                    .trace_buffer = &trace_buffer_storage,
                    .violations_buffer = &violations_buffer,
                },
                .artifact_selection = .{ .trace_artifact = .retained },
            },
        }, &user_context, Context.run),
    );
}

test "runRepairLivenessWithFixture converges after repair transition" {
    const sim = @import("sim/root.zig");

    var fixture: sim.fixture.Fixture(4, 4, 4, 8) = undefined;
    try fixture.init(.{
        .allocator = std.testing.allocator,
        .timer_queue_config = .{ .buckets = 4, .timers_max = 4 },
        .scheduler_seed = .init(13),
        .event_loop_config = .{ .step_budget_max = 4 },
        .trace_config = .{ .max_events = 8 },
    });
    defer fixture.deinit();

    const components = [_]ComponentSpec{
        .{ .name = "runtime" },
        .{ .name = "retry_policy" },
    };
    const run_identity = identity.makeRunIdentity(.{
        .package_name = "static_testing",
        .run_name = "system_repair_liveness",
        .seed = .init(13),
        .build_mode = .debug,
    });

    const Context = struct {
        queue_depth: u32 = 2,
        repaired: bool = false,
        next_sequence_no: u32 = 0,

        fn runFaultPhase(
            self: *@This(),
            context: *SystemContext(@TypeOf(fixture)),
            steps_max: u32,
        ) anyerror!liveness.PhaseExecution {
            std.debug.assert(context.hasComponent("runtime"));
            std.debug.assert(context.traceBufferPtr() != null);

            var steps: u32 = 0;
            if (self.queue_depth != 0 and steps < steps_max) {
                _ = try context.appendTraceEvent(
                    &self.next_sequence_no,
                    "system.fault.pending",
                    .decision,
                    "runtime",
                    null,
                    self.queue_depth,
                );
                steps += 1;
            }
            return .{
                .steps_executed = steps,
                .check_result = checker.CheckResult.pass(null),
            };
        }

        fn transitionToRepair(
            self: *@This(),
            context: *SystemContext(@TypeOf(fixture)),
        ) void {
            std.debug.assert(context.hasComponent("retry_policy"));
            self.repaired = true;
        }

        fn runRepairPhase(
            self: *@This(),
            context: *SystemContext(@TypeOf(fixture)),
            steps_max: u32,
        ) anyerror!liveness.PhaseExecution {
            std.debug.assert(self.repaired);

            var steps: u32 = 0;
            while (self.queue_depth != 0 and steps < steps_max) : (steps += 1) {
                self.queue_depth -= 1;
                _ = try context.appendTraceEvent(
                    &self.next_sequence_no,
                    "system.repair.drain",
                    .check,
                    "runtime",
                    null,
                    self.queue_depth,
                );
            }
            return .{
                .steps_executed = steps,
                .check_result = checker.CheckResult.pass(null),
            };
        }

        fn pendingReason(
            self: *@This(),
            _: *SystemContext(@TypeOf(fixture)),
        ) anyerror!?liveness.PendingReasonDetail {
            if (self.queue_depth == 0) return null;
            return .{
                .reason = .work_queue_not_empty,
                .count = self.queue_depth,
                .label = "queue_depth",
            };
        }
    };

    var user_context = Context{};
    const execution = try runRepairLivenessWithFixture(
        @TypeOf(fixture),
        Context,
        anyerror,
        &fixture,
        run_identity,
        .{
            .components = &components,
            .liveness_config = .{
                .fault_phase_steps_max = 1,
                .repair_phase_steps_max = 2,
            },
        },
        &user_context,
        .{
            .run_fault_phase_fn = Context.runFaultPhase,
            .transition_to_repair_fn = Context.transitionToRepair,
            .run_repair_phase_fn = Context.runRepairPhase,
            .pending_reason_fn = Context.pendingReason,
        },
    );

    try std.testing.expect(execution.summary.converged);
    try std.testing.expect(execution.summary.pending_reason == null);
    try std.testing.expect(execution.retained_bundle == null);
    try std.testing.expect(execution.trace_metadata.event_count >= 2);
}

test "runRepairLivenessWithFixture persists pending reason when repair does not settle" {
    const sim = @import("sim/root.zig");

    var fixture: sim.fixture.Fixture(4, 4, 4, 8) = undefined;
    try fixture.init(.{
        .allocator = std.testing.allocator,
        .timer_queue_config = .{ .buckets = 4, .timers_max = 4 },
        .scheduler_seed = .init(17),
        .event_loop_config = .{ .step_budget_max = 4 },
        .trace_config = .{ .max_events = 8 },
    });
    defer fixture.deinit();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    var entry_name_buffer: [128]u8 = undefined;
    var artifact_buffer: [256]u8 = undefined;
    var manifest_buffer: [2048]u8 = undefined;
    var trace_buffer_storage: [512]u8 = undefined;
    var retained_trace_file_buffer: [2048]u8 = undefined;
    var retained_trace_frame_buffer: [512]u8 = undefined;
    var violations_buffer: [1024]u8 = undefined;

    const components = [_]ComponentSpec{
        .{ .name = "runtime" },
        .{ .name = "retry_policy" },
    };
    const run_identity = identity.makeRunIdentity(.{
        .package_name = "static_testing",
        .run_name = "system_repair_liveness_pending",
        .seed = .init(17),
        .build_mode = .debug,
    });

    const Context = struct {
        queue_depth: u32 = 2,
        repaired: bool = false,
        next_sequence_no: u32 = 0,

        fn runFaultPhase(
            self: *@This(),
            context: *SystemContext(@TypeOf(fixture)),
            steps_max: u32,
        ) anyerror!liveness.PhaseExecution {
            _ = try context.appendTraceEvent(
                &self.next_sequence_no,
                "system.fault.pending",
                .decision,
                "runtime",
                null,
                self.queue_depth,
            );
            return .{
                .steps_executed = @min(steps_max, 1),
                .check_result = checker.CheckResult.pass(null),
            };
        }

        fn transitionToRepair(
            self: *@This(),
            _: *SystemContext(@TypeOf(fixture)),
        ) void {
            self.repaired = true;
        }

        fn runRepairPhase(
            self: *@This(),
            context: *SystemContext(@TypeOf(fixture)),
            steps_max: u32,
        ) anyerror!liveness.PhaseExecution {
            std.debug.assert(self.repaired);
            var steps: u32 = 0;
            while (self.queue_depth != 0 and steps < steps_max) : (steps += 1) {
                self.queue_depth -= 1;
                _ = try context.appendTraceEvent(
                    &self.next_sequence_no,
                    "system.repair.partial",
                    .check,
                    "runtime",
                    null,
                    self.queue_depth,
                );
            }
            return .{
                .steps_executed = steps,
                .check_result = checker.CheckResult.pass(null),
            };
        }

        fn pendingReason(
            self: *@This(),
            _: *SystemContext(@TypeOf(fixture)),
        ) anyerror!?liveness.PendingReasonDetail {
            if (self.queue_depth == 0) return null;
            return .{
                .reason = .work_queue_not_empty,
                .count = self.queue_depth,
                .label = "queue_depth",
            };
        }
    };

    var user_context = Context{};
    const execution = try runRepairLivenessWithFixture(
        @TypeOf(fixture),
        Context,
        anyerror,
        &fixture,
        run_identity,
        .{
            .components = &components,
            .liveness_config = .{
                .fault_phase_steps_max = 1,
                .repair_phase_steps_max = 1,
            },
            .failure_persistence = .{
                .bundle_persistence = .{
                    .io = threaded_io.io(),
                    .dir = tmp_dir.dir,
                    .entry_name_buffer = &entry_name_buffer,
                    .artifact_buffer = &artifact_buffer,
                    .manifest_buffer = &manifest_buffer,
                    .trace_buffer = &trace_buffer_storage,
                    .retained_trace_file_buffer = &retained_trace_file_buffer,
                    .retained_trace_frame_buffer = &retained_trace_frame_buffer,
                    .violations_buffer = &violations_buffer,
                },
                .artifact_selection = .{ .trace_artifact = .summary_and_retained },
            },
        },
        &user_context,
        .{
            .run_fault_phase_fn = Context.runFaultPhase,
            .transition_to_repair_fn = Context.transitionToRepair,
            .run_repair_phase_fn = Context.runRepairPhase,
            .pending_reason_fn = Context.pendingReason,
        },
    );

    try std.testing.expect(!execution.summary.converged);
    try std.testing.expect(execution.summary.pending_reason != null);
    try std.testing.expect(execution.retained_bundle != null);

    var read_artifact_buffer: [256]u8 = undefined;
    var read_manifest_source: [failure_bundle.recommended_manifest_source_len]u8 = undefined;
    var read_manifest_parse: [failure_bundle.recommended_manifest_parse_len]u8 = undefined;
    var read_trace_source: [failure_bundle.recommended_trace_source_len]u8 = undefined;
    var read_trace_parse: [failure_bundle.recommended_trace_parse_len]u8 = undefined;
    var read_retained_trace_file: [2048]u8 = undefined;
    var read_retained_events: [8]trace.TraceEvent = undefined;
    var read_retained_labels: [512]u8 = undefined;
    var read_violations_source: [failure_bundle.recommended_violations_source_len]u8 = undefined;
    var read_violations_parse: [failure_bundle.recommended_violations_parse_len]u8 = undefined;

    const bundle = try failure_bundle.readFailureBundle(
        threaded_io.io(),
        tmp_dir.dir,
        execution.retained_bundle.?.entry_name,
        .{
            .selection = .{
                .trace_artifact = .summary_and_retained,
                .text_capture = .none,
            },
            .artifact_buffer = &read_artifact_buffer,
            .manifest_buffer = &read_manifest_source,
            .manifest_parse_buffer = &read_manifest_parse,
            .trace_buffer = &read_trace_source,
            .trace_parse_buffer = &read_trace_parse,
            .retained_trace_file_buffer = &read_retained_trace_file,
            .retained_trace_events_buffer = &read_retained_events,
            .retained_trace_label_buffer = &read_retained_labels,
            .violations_buffer = &read_violations_source,
            .violations_parse_buffer = &read_violations_parse,
        },
    );

    try std.testing.expectEqualStrings("system_repair_liveness_pending", bundle.manifest_document.run_name);
    try std.testing.expect(bundle.manifest_document.pending_reason != null);
    try std.testing.expectEqual(liveness.PendingReason.work_queue_not_empty, bundle.manifest_document.pending_reason.?.reason);
    try std.testing.expectEqual(@as(u32, 1), bundle.manifest_document.pending_reason.?.count);
    try std.testing.expectEqualStrings("queue_depth", bundle.manifest_document.pending_reason.?.label.?);
    try std.testing.expectEqualStrings("system_repair_liveness.pending_reason", bundle.violations_document.violations[0].code);
}
