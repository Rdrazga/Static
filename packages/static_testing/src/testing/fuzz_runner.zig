//! Deterministic fuzz/property runner over split seeds, bounded persistence,
//! and optional seed reduction.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const core = @import("static_core");
const checker = @import("checker.zig");
const corpus = @import("corpus.zig");
const identity = @import("identity.zig");
const reducer = @import("reducer.zig");
const seed_mod = @import("seed.zig");
const trace = @import("trace.zig");

/// Operating errors surfaced by fuzz execution setup and orchestration.
pub const FuzzRunError = error{
    InvalidInput,
};

/// Runner configuration for one deterministic fuzz session.
pub const FuzzConfig = struct {
    package_name: []const u8,
    run_name: []const u8,
    base_seed: seed_mod.Seed,
    build_mode: identity.BuildMode,
    case_count_max: u32,
    reduction_budget: reducer.ReductionBudget = .{
        .max_attempts = 64,
        .max_successes = 64,
    },
};

/// One deterministic case execution result.
pub const FuzzExecution = struct {
    trace_metadata: trace.TraceMetadata,
    check_result: checker.CheckResult,
};

/// One failed fuzz case, optionally reduced and persisted.
///
/// `persisted_entry_name` borrows `FuzzPersistence.entry_name_buffer`.
pub const FuzzCaseResult = struct {
    run_identity: identity.RunIdentity,
    trace_metadata: trace.TraceMetadata,
    check_result: checker.CheckResult,
    reduced_seed: ?seed_mod.Seed = null,
    persisted_entry_name: ?[]const u8 = null,
};

/// Aggregate result for a fuzz session.
pub const FuzzRunSummary = struct {
    executed_case_count: u32,
    failed_case: ?FuzzCaseResult,
};

/// Persistence hooks for failing cases.
pub const FuzzPersistence = struct {
    io: std.Io,
    dir: std.Io.Dir,
    naming: corpus.CorpusNaming = .{},
    artifact_buffer: []u8,
    entry_name_buffer: []u8,
};

/// Deterministic fuzz target callback contract.
pub fn FuzzTarget(comptime TargetError: type) type {
    return struct {
        context: *const anyopaque,
        run_fn: *const fn (
            context: *const anyopaque,
            run_identity: identity.RunIdentity,
        ) TargetError!FuzzExecution,

        pub fn run(
            self: @This(),
            run_identity: identity.RunIdentity,
        ) TargetError!FuzzExecution {
            return self.run_fn(self.context, run_identity);
        }
    };
}

/// Deterministic fuzz runner configuration bundle.
pub fn FuzzRunner(comptime TargetError: type, comptime ReduceError: type) type {
    return struct {
        config: FuzzConfig,
        target: FuzzTarget(TargetError),
        persistence: ?FuzzPersistence = null,
        seed_reducer: ?reducer.Reducer(seed_mod.Seed, ReduceError) = null,

        pub fn run(self: @This()) (FuzzRunError || corpus.CorpusWriteError || TargetError || ReduceError)!FuzzRunSummary {
            return runFuzzCases(TargetError, ReduceError, self);
        }
    };
}

comptime {
    core.errors.assertVocabularySubset(FuzzRunError);
}

/// Execute deterministic fuzz cases until the first failure or the case budget.
pub fn runFuzzCases(
    comptime TargetError: type,
    comptime ReduceError: type,
    runner: FuzzRunner(TargetError, ReduceError),
) (FuzzRunError || corpus.CorpusWriteError || TargetError || ReduceError)!FuzzRunSummary {
    try validateRunnerConfig(runner.config, runner.seed_reducer != null);

    var executed_case_count: u32 = 0;
    var case_index: u32 = 0;
    while (case_index < runner.config.case_count_max) : (case_index += 1) {
        const case_seed = seed_mod.splitSeed(runner.config.base_seed, case_index);
        const run_identity = makeCaseIdentity(runner.config, case_index, case_seed);
        const execution = try runner.target.run(run_identity);
        assertCheckResult(execution.check_result);
        executed_case_count += 1;

        if (!execution.check_result.passed) {
            const failed_case = try finalizeFailure(
                TargetError,
                ReduceError,
                runner,
                run_identity,
                execution,
            );
            return .{
                .executed_case_count = executed_case_count,
                .failed_case = failed_case,
            };
        }
    }

    return .{
        .executed_case_count = executed_case_count,
        .failed_case = null,
    };
}

fn validateRunnerConfig(config: FuzzConfig, has_seed_reducer: bool) FuzzRunError!void {
    if (config.package_name.len == 0) return error.InvalidInput;
    if (config.run_name.len == 0) return error.InvalidInput;
    if (config.case_count_max == 0) return error.InvalidInput;
    if (has_seed_reducer) {
        if (config.reduction_budget.max_attempts == 0) return error.InvalidInput;
        if (config.reduction_budget.max_successes == 0) return error.InvalidInput;
    }
}

fn makeCaseIdentity(
    config: FuzzConfig,
    case_index: u32,
    case_seed: seed_mod.Seed,
) identity.RunIdentity {
    return identity.makeRunIdentity(.{
        .package_name = config.package_name,
        .run_name = config.run_name,
        .seed = case_seed,
        .artifact_version = .v1,
        .build_mode = config.build_mode,
        .case_index = case_index,
        .run_index = 0,
    });
}

fn finalizeFailure(
    comptime TargetError: type,
    comptime ReduceError: type,
    runner: FuzzRunner(TargetError, ReduceError),
    failed_identity: identity.RunIdentity,
    failed_execution: FuzzExecution,
) (FuzzRunError || corpus.CorpusWriteError || TargetError || ReduceError)!FuzzCaseResult {
    var final_identity = failed_identity;
    var final_execution = failed_execution;
    var reduced_seed: ?seed_mod.Seed = null;

    if (runner.seed_reducer) |seed_reducer| {
        const reduction = try reducer.reduceUntilFixedPoint(
            seed_mod.Seed,
            ReduceError,
            seed_reducer,
            failed_identity.seed,
            runner.config.reduction_budget,
        );

        if (reduction.candidate.value != failed_identity.seed.value) {
            reduced_seed = reduction.candidate;
            final_identity = makeCaseIdentity(
                runner.config,
                failed_identity.case_index,
                reduction.candidate,
            );
            final_execution = try runner.target.run(final_identity);
            assertCheckResult(final_execution.check_result);
            assert(!final_execution.check_result.passed);
        }
    }

    const persisted_entry_name = try persistFailure(
        runner.persistence,
        final_identity,
        final_execution.trace_metadata,
    );

    return .{
        .run_identity = final_identity,
        .trace_metadata = final_execution.trace_metadata,
        .check_result = final_execution.check_result,
        .reduced_seed = reduced_seed,
        .persisted_entry_name = persisted_entry_name,
    };
}

fn persistFailure(
    persistence: ?FuzzPersistence,
    run_identity: identity.RunIdentity,
    trace_metadata: trace.TraceMetadata,
) corpus.CorpusWriteError!?[]const u8 {
    if (persistence) |persistence_config| {
        const written = try corpus.writeCorpusEntry(
            persistence_config.io,
            persistence_config.dir,
            persistence_config.naming,
            persistence_config.entry_name_buffer,
            persistence_config.artifact_buffer,
            run_identity,
            trace_metadata,
        );
        return written.entry_name;
    }
    return null;
}

fn assertCheckResult(result: checker.CheckResult) void {
    if (result.passed) {
        assert(result.violations.len == 0);
    } else {
        assert(result.violations.len > 0);
    }
}

test "runFuzzCases rejects invalid fuzz configs" {
    const Context = struct {
        fn run(_: *const anyopaque, _: identity.RunIdentity) error{}!FuzzExecution {
            return .{
                .trace_metadata = .{
                    .event_count = 0,
                    .truncated = false,
                    .has_range = false,
                    .first_sequence_no = 0,
                    .last_sequence_no = 0,
                    .first_timestamp_ns = 0,
                    .last_timestamp_ns = 0,
                },
                .check_result = checker.CheckResult.pass(null),
            };
        }
    };
    const Runner = FuzzRunner(error{}, error{});

    try testing.expectError(error.InvalidInput, runFuzzCases(error{}, error{}, Runner{
        .config = .{
            .package_name = "",
            .run_name = "invalid",
            .base_seed = .{ .value = 1 },
            .build_mode = .debug,
            .case_count_max = 1,
        },
        .target = .{
            .context = undefined,
            .run_fn = Context.run,
        },
    }));

    try testing.expectError(error.InvalidInput, runFuzzCases(error{}, error{}, Runner{
        .config = .{
            .package_name = "static_testing",
            .run_name = "invalid_budget",
            .base_seed = .{ .value = 1 },
            .build_mode = .debug,
            .case_count_max = 1,
            .reduction_budget = .{
                .max_attempts = 0,
                .max_successes = 1,
            },
        },
        .target = .{
            .context = undefined,
            .run_fn = Context.run,
        },
        .seed_reducer = .{
            .context = undefined,
            .measure_fn = struct {
                fn measure(_: *const anyopaque, candidate: seed_mod.Seed) u64 {
                    return candidate.value;
                }
            }.measure,
            .next_fn = struct {
                fn next(_: *const anyopaque, current: seed_mod.Seed, _: u32) error{}!?seed_mod.Seed {
                    return current;
                }
            }.next,
            .is_interesting_fn = struct {
                fn isInteresting(_: *const anyopaque, _: seed_mod.Seed) error{}!bool {
                    return true;
                }
            }.isInteresting,
        },
    }));

    try testing.expectError(error.InvalidInput, runFuzzCases(error{}, error{}, Runner{
        .config = .{
            .package_name = "static_testing",
            .run_name = "invalid_success_budget",
            .base_seed = .{ .value = 1 },
            .build_mode = .debug,
            .case_count_max = 1,
            .reduction_budget = .{
                .max_attempts = 1,
                .max_successes = 0,
            },
        },
        .target = .{
            .context = undefined,
            .run_fn = Context.run,
        },
        .seed_reducer = .{
            .context = undefined,
            .measure_fn = struct {
                fn measure(_: *const anyopaque, candidate: seed_mod.Seed) u64 {
                    return candidate.value;
                }
            }.measure,
            .next_fn = struct {
                fn next(_: *const anyopaque, current: seed_mod.Seed, _: u32) error{}!?seed_mod.Seed {
                    return current;
                }
            }.next,
            .is_interesting_fn = struct {
                fn isInteresting(_: *const anyopaque, _: seed_mod.Seed) error{}!bool {
                    return true;
                }
            }.isInteresting,
        },
    }));
}

test "runFuzzCases reproduces the same first failing seed across runs" {
    const violations = [_]checker.Violation{
        .{ .code = "high_seed", .message = "seed reached failure threshold" },
    };
    const threshold: u64 = 1 << 63;

    const Context = struct {
        threshold: u64,

        fn run(context_ptr: *const anyopaque, run_identity: identity.RunIdentity) error{}!FuzzExecution {
            const context: *const @This() = @ptrCast(@alignCast(context_ptr));
            const failing = run_identity.seed.value >= context.threshold;
            const timestamp_ns = run_identity.seed.value & 0xffff;
            return .{
                .trace_metadata = .{
                    .event_count = 1,
                    .truncated = false,
                    .has_range = true,
                    .first_sequence_no = run_identity.case_index,
                    .last_sequence_no = run_identity.case_index,
                    .first_timestamp_ns = timestamp_ns,
                    .last_timestamp_ns = timestamp_ns,
                },
                .check_result = if (failing)
                    checker.CheckResult.fail(&violations, null)
                else
                    checker.CheckResult.pass(null),
            };
        }
    };
    const Runner = FuzzRunner(error{}, error{});
    var context = Context{ .threshold = threshold };
    const config: FuzzConfig = .{
        .package_name = "static_testing",
        .run_name = "deterministic_failure",
        .base_seed = .{ .value = 1234 },
        .build_mode = .debug,
        .case_count_max = 32,
    };

    const first = try runFuzzCases(error{}, error{}, Runner{
        .config = config,
        .target = .{
            .context = &context,
            .run_fn = Context.run,
        },
    });
    const second = try runFuzzCases(error{}, error{}, Runner{
        .config = config,
        .target = .{
            .context = &context,
            .run_fn = Context.run,
        },
    });

    try testing.expect(first.failed_case != null);
    try testing.expect(second.failed_case != null);
    try testing.expectEqual(
        first.failed_case.?.run_identity.case_index,
        second.failed_case.?.run_identity.case_index,
    );
    try testing.expectEqual(
        first.failed_case.?.run_identity.seed.value,
        second.failed_case.?.run_identity.seed.value,
    );
}

test "runFuzzCases applies a seed reducer only after a failing case" {
    const violations = [_]checker.Violation{
        .{ .code = "large_seed", .message = "seed is still above the threshold" },
    };
    const threshold: u64 = 1 << 62;

    const TargetContext = struct {
        threshold: u64,

        fn run(context_ptr: *const anyopaque, run_identity: identity.RunIdentity) error{}!FuzzExecution {
            const context: *const @This() = @ptrCast(@alignCast(context_ptr));
            const failing = run_identity.seed.value >= context.threshold;
            return .{
                .trace_metadata = .{
                    .event_count = 1,
                    .truncated = false,
                    .has_range = true,
                    .first_sequence_no = run_identity.case_index,
                    .last_sequence_no = run_identity.case_index,
                    .first_timestamp_ns = run_identity.seed.value & 0xffff,
                    .last_timestamp_ns = run_identity.seed.value & 0xffff,
                },
                .check_result = if (failing)
                    checker.CheckResult.fail(&violations, null)
                else
                    checker.CheckResult.pass(null),
            };
        }
    };
    const ReducerContext = struct {
        threshold: u64,
        calls_total: u32 = 0,

        fn measure(_: *const anyopaque, candidate: seed_mod.Seed) u64 {
            return candidate.value;
        }

        fn next(_: *const anyopaque, current: seed_mod.Seed, _: u32) error{}!?seed_mod.Seed {
            if (current.value <= 1) return null;
            return seed_mod.Seed.init(@divFloor(current.value, 2));
        }

        fn isInteresting(context_ptr: *const anyopaque, candidate: seed_mod.Seed) error{}!bool {
            const context: *@This() = @ptrCast(@alignCast(@constCast(context_ptr)));
            context.calls_total += 1;
            return candidate.value >= context.threshold;
        }
    };
    const Runner = FuzzRunner(error{}, error{});
    var target_context = TargetContext{ .threshold = threshold };
    var reducer_context = ReducerContext{ .threshold = threshold };

    const result = try runFuzzCases(error{}, error{}, Runner{
        .config = .{
            .package_name = "static_testing",
            .run_name = "seed_reduction",
            .base_seed = .{ .value = 55 },
            .build_mode = .debug,
            .case_count_max = 32,
            .reduction_budget = .{
                .max_attempts = 16,
                .max_successes = 16,
            },
        },
        .target = .{
            .context = &target_context,
            .run_fn = TargetContext.run,
        },
        .seed_reducer = .{
            .context = &reducer_context,
            .measure_fn = ReducerContext.measure,
            .next_fn = ReducerContext.next,
            .is_interesting_fn = ReducerContext.isInteresting,
        },
    });

    try testing.expect(result.failed_case != null);
    try testing.expect(result.failed_case.?.reduced_seed != null);
    try testing.expect(reducer_context.calls_total > 0);
}

test "runFuzzCases does not call the reducer when all cases pass" {
    const TargetContext = struct {
        fn run(_: *const anyopaque, run_identity: identity.RunIdentity) error{}!FuzzExecution {
            return .{
                .trace_metadata = .{
                    .event_count = 1,
                    .truncated = false,
                    .has_range = true,
                    .first_sequence_no = run_identity.case_index,
                    .last_sequence_no = run_identity.case_index,
                    .first_timestamp_ns = 1,
                    .last_timestamp_ns = 1,
                },
                .check_result = checker.CheckResult.pass(null),
            };
        }
    };
    const ReducerContext = struct {
        calls_total: u32 = 0,

        fn measure(_: *const anyopaque, candidate: seed_mod.Seed) u64 {
            return candidate.value;
        }

        fn next(_: *const anyopaque, current: seed_mod.Seed, _: u32) error{}!?seed_mod.Seed {
            return current;
        }

        fn isInteresting(context_ptr: *const anyopaque, _: seed_mod.Seed) error{}!bool {
            const context: *@This() = @ptrCast(@alignCast(@constCast(context_ptr)));
            context.calls_total += 1;
            return true;
        }
    };
    const Runner = FuzzRunner(error{}, error{});
    var reducer_context = ReducerContext{};

    const result = try runFuzzCases(error{}, error{}, Runner{
        .config = .{
            .package_name = "static_testing",
            .run_name = "all_pass",
            .base_seed = .{ .value = 7 },
            .build_mode = .debug,
            .case_count_max = 4,
        },
        .target = .{
            .context = undefined,
            .run_fn = TargetContext.run,
        },
        .seed_reducer = .{
            .context = &reducer_context,
            .measure_fn = ReducerContext.measure,
            .next_fn = ReducerContext.next,
            .is_interesting_fn = ReducerContext.isInteresting,
        },
    });

    try testing.expectEqual(@as(u32, 4), result.executed_case_count);
    try testing.expect(result.failed_case == null);
    try testing.expectEqual(@as(u32, 0), reducer_context.calls_total);
}

test "runFuzzCases keeps failed cases in-memory when persistence is disabled" {
    const violations = [_]checker.Violation{
        .{ .code = "always_fail", .message = "deterministic failure" },
    };
    const Context = struct {
        fn run(_: *const anyopaque, run_identity: identity.RunIdentity) error{}!FuzzExecution {
            return .{
                .trace_metadata = .{
                    .event_count = 1,
                    .truncated = false,
                    .has_range = true,
                    .first_sequence_no = run_identity.case_index,
                    .last_sequence_no = run_identity.case_index,
                    .first_timestamp_ns = 1,
                    .last_timestamp_ns = 1,
                },
                .check_result = checker.CheckResult.fail(&violations, null),
            };
        }
    };
    const Runner = FuzzRunner(error{}, error{});

    const result = try runFuzzCases(error{}, error{}, Runner{
        .config = .{
            .package_name = "static_testing",
            .run_name = "no_persistence",
            .base_seed = .{ .value = 1 },
            .build_mode = .debug,
            .case_count_max = 2,
        },
        .target = .{
            .context = undefined,
            .run_fn = Context.run,
        },
    });

    try testing.expectEqual(@as(u32, 1), result.executed_case_count);
    try testing.expect(result.failed_case != null);
    try testing.expect(result.failed_case.?.persisted_entry_name == null);
}

test "runFuzzCases propagates persistence buffer limits" {
    const violations = [_]checker.Violation{
        .{ .code = "always_fail", .message = "deterministic failure" },
    };
    const Context = struct {
        fn run(_: *const anyopaque, run_identity: identity.RunIdentity) error{}!FuzzExecution {
            return .{
                .trace_metadata = .{
                    .event_count = 1,
                    .truncated = false,
                    .has_range = true,
                    .first_sequence_no = run_identity.case_index,
                    .last_sequence_no = run_identity.case_index,
                    .first_timestamp_ns = 1,
                    .last_timestamp_ns = 1,
                },
                .check_result = checker.CheckResult.fail(&violations, null),
            };
        }
    };
    const Runner = FuzzRunner(error{}, error{});
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var threaded_io = std.Io.Threaded.init(testing.allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    var artifact_buffer: [8]u8 = undefined;
    var entry_name_buffer: [128]u8 = undefined;

    try testing.expectError(error.NoSpaceLeft, runFuzzCases(error{}, error{}, Runner{
        .config = .{
            .package_name = "static_testing",
            .run_name = "persistence_buffer_limit",
            .base_seed = .{ .value = 2 },
            .build_mode = .debug,
            .case_count_max = 1,
        },
        .target = .{
            .context = undefined,
            .run_fn = Context.run,
        },
        .persistence = .{
            .io = threaded_io.io(),
            .dir = tmp_dir.dir,
            .artifact_buffer = &artifact_buffer,
            .entry_name_buffer = &entry_name_buffer,
        },
    }));
}
