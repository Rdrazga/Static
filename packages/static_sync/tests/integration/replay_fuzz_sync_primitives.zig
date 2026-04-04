const std = @import("std");
const sync = @import("static_sync");
const testing = @import("static_testing");

const checker = testing.testing.checker;
const fuzz_runner = testing.testing.fuzz_runner;
const identity = testing.testing.identity;
const trace = testing.testing.trace;

const event_violation = [_]checker.Violation{
    .{
        .code = "event_state_machine",
        .message = "event operation sequence diverged from the expected model",
    },
};

const semaphore_violation = [_]checker.Violation{
    .{
        .code = "semaphore_state_machine",
        .message = "semaphore operation sequence diverged from the expected model",
    },
};

const cancel_violation = [_]checker.Violation{
    .{
        .code = "cancel_state_machine",
        .message = "cancel operation sequence diverged from the expected model",
    },
};

test "deterministic replay-backed event campaign preserves state-machine invariants" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const Runner = fuzz_runner.FuzzRunner(error{}, error{});
    var artifact_buffer: [512]u8 = undefined;
    var entry_name_buffer: [128]u8 = undefined;
    const runner = Runner{
        .config = .{
            .package_name = "static_sync",
            .run_name = "event_state_machine",
            .base_seed = .{ .value = 0x17b4_2026_0100_0001 },
            .build_mode = .debug,
            .case_count_max = 64,
        },
        .target = .{
            .context = undefined,
            .run_fn = EventTarget.run,
        },
        .persistence = .{
            .io = threaded_io.io(),
            .dir = tmp_dir.dir,
            .naming = .{ .prefix = "static_sync_event" },
            .artifact_buffer = &artifact_buffer,
            .entry_name_buffer = &entry_name_buffer,
        },
    };

    const summary = try runner.run();
    try std.testing.expect(summary.failed_case == null);
    try std.testing.expectEqual(@as(u32, 64), summary.executed_case_count);
}

test "deterministic replay-backed semaphore campaign preserves permit invariants" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const Runner = fuzz_runner.FuzzRunner(error{}, error{});
    var artifact_buffer: [512]u8 = undefined;
    var entry_name_buffer: [128]u8 = undefined;
    const runner = Runner{
        .config = .{
            .package_name = "static_sync",
            .run_name = "semaphore_state_machine",
            .base_seed = .{ .value = 0x17b4_2026_0100_0002 },
            .build_mode = .debug,
            .case_count_max = 64,
        },
        .target = .{
            .context = undefined,
            .run_fn = SemaphoreTarget.run,
        },
        .persistence = .{
            .io = threaded_io.io(),
            .dir = tmp_dir.dir,
            .naming = .{ .prefix = "static_sync_semaphore" },
            .artifact_buffer = &artifact_buffer,
            .entry_name_buffer = &entry_name_buffer,
        },
    };

    const summary = try runner.run();
    try std.testing.expect(summary.failed_case == null);
    try std.testing.expectEqual(@as(u32, 64), summary.executed_case_count);
}

test "deterministic replay-backed cancel campaign preserves registration invariants" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(std.testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const Runner = fuzz_runner.FuzzRunner(error{}, error{});
    var artifact_buffer: [512]u8 = undefined;
    var entry_name_buffer: [128]u8 = undefined;
    const runner = Runner{
        .config = .{
            .package_name = "static_sync",
            .run_name = "cancel_state_machine",
            .base_seed = .{ .value = 0x17b4_2026_0100_0003 },
            .build_mode = .debug,
            .case_count_max = 64,
        },
        .target = .{
            .context = undefined,
            .run_fn = CancelTarget.run,
        },
        .persistence = .{
            .io = threaded_io.io(),
            .dir = tmp_dir.dir,
            .naming = .{ .prefix = "static_sync_cancel" },
            .artifact_buffer = &artifact_buffer,
            .entry_name_buffer = &entry_name_buffer,
        },
    };

    const summary = try runner.run();
    try std.testing.expect(summary.failed_case == null);
    try std.testing.expectEqual(@as(u32, 64), summary.executed_case_count);
}

const EventTarget = struct {
    fn run(_: *const anyopaque, run_identity: identity.RunIdentity) error{}!fuzz_runner.FuzzExecution {
        const result = evaluateEventCase(run_identity.seed.value);
        return .{
            .trace_metadata = makeTraceMetadata(run_identity, result.event_count),
            .check_result = result.check_result,
        };
    }
};

const SemaphoreTarget = struct {
    fn run(_: *const anyopaque, run_identity: identity.RunIdentity) error{}!fuzz_runner.FuzzExecution {
        const result = evaluateSemaphoreCase(run_identity.seed.value);
        return .{
            .trace_metadata = makeTraceMetadata(run_identity, result.event_count),
            .check_result = result.check_result,
        };
    }
};

const CancelTarget = struct {
    fn run(_: *const anyopaque, run_identity: identity.RunIdentity) error{}!fuzz_runner.FuzzExecution {
        const result = evaluateCancelCase(run_identity.seed.value);
        return .{
            .trace_metadata = makeTraceMetadata(run_identity, result.event_count),
            .check_result = result.check_result,
        };
    }
};

const Evaluation = struct {
    event_count: u32,
    check_result: checker.CheckResult,
};

fn evaluateEventCase(seed_value: u64) Evaluation {
    var prng = std.Random.DefaultPrng.init(seed_value ^ 0xe7e1_0001_4a5b_9321);
    const random = prng.random();
    const action_count: u32 = 12 + @as(u32, @intCast(seed_value % 13));

    var event = sync.event.Event{};
    var model_signaled = false;

    var index: u32 = 0;
    while (index < action_count) : (index += 1) {
        switch (random.intRangeLessThan(u8, 0, 4)) {
            0 => {
                event.set();
                model_signaled = true;
            },
            1 => {
                event.reset();
                model_signaled = false;
            },
            2 => {
                const actual_would_block = blk: {
                    event.tryWait() catch |err| switch (err) {
                        error.WouldBlock => break :blk true,
                    };
                    break :blk false;
                };
                const expected_would_block = !model_signaled;
                if (actual_would_block != expected_would_block) {
                    return failEvaluation(action_count, &event_violation, modelDigest(model_signaled, 0, index));
                }
            },
            3 => {
                if (@hasDecl(sync.event.Event, "timedWait")) {
                    const actual_timed_out = blk: {
                        event.timedWait(0) catch |err| switch (err) {
                            error.Timeout => break :blk true,
                            error.Unsupported => break :blk true,
                        };
                        break :blk false;
                    };
                    const expected_timed_out = !model_signaled;
                    if (actual_timed_out != expected_timed_out) {
                        return failEvaluation(action_count, &event_violation, modelDigest(model_signaled, 0, index));
                    }
                }
            },
            else => unreachable,
        }
    }

    return passEvaluation(action_count, modelDigest(model_signaled, 0, action_count));
}

fn evaluateSemaphoreCase(seed_value: u64) Evaluation {
    var prng = std.Random.DefaultPrng.init(seed_value ^ 0x53a2_2002_9c41_0b17);
    const random = prng.random();
    const action_count: u32 = 12 + @as(u32, @intCast(seed_value % 13));

    var semaphore = sync.semaphore.Semaphore{};
    var model_permits: usize = 0;

    var index: u32 = 0;
    while (index < action_count) : (index += 1) {
        switch (random.intRangeLessThan(u8, 0, 6)) {
            0 => {
                semaphore.post(0);
            },
            1 => {
                semaphore.post(1);
                model_permits +|= 1;
            },
            2 => {
                semaphore.post(2);
                model_permits +|= 2;
            },
            3 => {
                const large_count = std.math.maxInt(usize) - @as(usize, @intCast(seed_value & 0x7));
                semaphore.post(large_count);
                model_permits +|= large_count;
            },
            4 => {
                const actual_would_block = blk: {
                    semaphore.tryWait() catch |err| switch (err) {
                        error.WouldBlock => break :blk true,
                    };
                    break :blk false;
                };
                const expected_would_block = model_permits == 0;
                if (actual_would_block != expected_would_block) {
                    return failEvaluation(action_count, &semaphore_violation, modelDigest(true, model_permits, index));
                }
                if (!expected_would_block) model_permits -= 1;
            },
            5 => {
                if (@hasDecl(sync.semaphore.Semaphore, "timedWait")) {
                    const actual_timed_out = blk: {
                        semaphore.timedWait(0) catch |err| switch (err) {
                            error.Timeout => break :blk true,
                            error.Unsupported => break :blk true,
                        };
                        break :blk false;
                    };
                    const expected_timed_out = model_permits == 0;
                    if (actual_timed_out != expected_timed_out) {
                        return failEvaluation(action_count, &semaphore_violation, modelDigest(true, model_permits, index));
                    }
                    if (!expected_timed_out) model_permits -= 1;
                }
            },
            else => unreachable,
        }
    }

    return passEvaluation(action_count, modelDigest(true, model_permits, action_count));
}

fn evaluateCancelCase(seed_value: u64) Evaluation {
    var prng = std.Random.DefaultPrng.init(seed_value ^ 0xa8c4_3003_55d0_1e29);
    const random = prng.random();
    const action_count: u32 = 12 + @as(u32, @intCast(seed_value % 13));

    var source = sync.cancel.CancelSource{};
    const token = source.token();
    var callback_count = std.atomic.Value(u32).init(0);
    var registration = sync.cancel.CancelRegistration.init(cancelWakeCounter, &callback_count);

    var model_cancelled = false;
    var model_registered = false;
    var model_callback_count: u32 = 0;

    var index: u32 = 0;
    while (index < action_count) : (index += 1) {
        switch (random.intRangeLessThan(u8, 0, 5)) {
            0 => {
                if (!model_registered) {
                    const actual_cancelled = blk: {
                        registration.register(token) catch |err| switch (err) {
                            error.Cancelled => break :blk true,
                            error.WouldBlock => break :blk true,
                        };
                        break :blk false;
                    };
                    const expected_cancelled = model_cancelled;
                    if (actual_cancelled != expected_cancelled) {
                        return failEvaluation(action_count, &cancel_violation, modelDigest(model_cancelled, model_callback_count, index));
                    }
                    if (!expected_cancelled) model_registered = true;
                }
            },
            1 => {
                if (model_registered) {
                    registration.unregister();
                    model_registered = false;
                }
            },
            2 => {
                source.cancel();
                if (!model_cancelled and model_registered) model_callback_count += 1;
                model_cancelled = true;
            },
            3 => {
                const actual_cancelled = blk: {
                    token.throwIfCancelled() catch |err| switch (err) {
                        error.Cancelled => break :blk true,
                    };
                    break :blk false;
                };
                if (actual_cancelled != model_cancelled) {
                    return failEvaluation(action_count, &cancel_violation, modelDigest(model_cancelled, model_callback_count, index));
                }
            },
            4 => {
                if (!model_registered) {
                    source.reset();
                    model_cancelled = false;
                }
            },
            else => unreachable,
        }

        if (callback_count.load(.acquire) != model_callback_count) {
            return failEvaluation(action_count, &cancel_violation, modelDigest(model_cancelled, model_callback_count, index));
        }
        if (token.isCancelled() != model_cancelled) {
            return failEvaluation(action_count, &cancel_violation, modelDigest(model_cancelled, model_callback_count, index));
        }
    }

    if (model_registered) registration.unregister();
    return passEvaluation(action_count, modelDigest(model_cancelled, model_callback_count, action_count));
}

fn passEvaluation(event_count: u32, digest_value: u128) Evaluation {
    return .{
        .event_count = event_count,
        .check_result = checker.CheckResult.pass(checker.CheckpointDigest.init(digest_value)),
    };
}

fn failEvaluation(event_count: u32, violations: []const checker.Violation, digest_value: u128) Evaluation {
    return .{
        .event_count = event_count,
        .check_result = checker.CheckResult.fail(violations, checker.CheckpointDigest.init(digest_value)),
    };
}

fn makeTraceMetadata(run_identity: identity.RunIdentity, event_count: u32) trace.TraceMetadata {
    const low = run_identity.seed.value & 0xffff;
    return .{
        .event_count = event_count,
        .truncated = false,
        .has_range = true,
        .first_sequence_no = run_identity.case_index,
        .last_sequence_no = run_identity.case_index + event_count -| 1,
        .first_timestamp_ns = low,
        .last_timestamp_ns = low + event_count,
    };
}

fn modelDigest(flag: bool, count: usize, step: u32) u128 {
    const a: u128 = if (flag) 1 else 0;
    const b: u128 = @as(u128, count) << 32;
    const c: u128 = @as(u128, step) << 96;
    return a | b | c;
}

fn cancelWakeCounter(ctx: ?*anyopaque) void {
    const counter: *std.atomic.Value(u32) = @ptrCast(@alignCast(ctx.?));
    _ = counter.fetchAdd(1, .acq_rel);
}
