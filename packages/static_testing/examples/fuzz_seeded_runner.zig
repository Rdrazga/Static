//! Demonstrates deterministic fuzz execution with failure persistence and
//! seed reduction.

const std = @import("std");
const assert = std.debug.assert;
const testing = @import("static_testing");

const failure_threshold: u64 = 1024;
const violations = [_]testing.testing.checker.Violation{
    .{ .code = "threshold", .message = "seed reached the failure threshold" },
};

pub fn main() !void {
    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    const cwd = std.Io.Dir.cwd();
    const output_dir_path = ".zig-cache/static_testing/examples/fuzz_seeded_runner";
    try deleteTreeIfPresent(cwd, io, output_dir_path);

    var output_dir = try cwd.createDirPathOpen(io, output_dir_path, .{});
    defer cleanupOutputDir(cwd, io, output_dir_path);
    defer output_dir.close(io);

    const config = testing.testing.fuzz_runner.FuzzConfig{
        .package_name = "static_testing",
        .run_name = "fuzz_seeded_runner",
        .base_seed = .{ .value = 2026 },
        .build_mode = .debug,
        .case_count_max = 16,
        .reduction_budget = .{
            .max_attempts = 64,
            .max_successes = 64,
        },
    };

    const first_failing = blk: {
        const candidate = findFirstFailingSeed(config);
        assert(candidate != null);
        break :blk candidate.?;
    };
    assert(first_failing.case_index < config.case_count_max);

    const Runner = testing.testing.fuzz_runner.FuzzRunner(error{}, error{});
    var target_context = TargetContext{ .threshold = failure_threshold };
    var reducer_context = ReducerContext{ .threshold = failure_threshold };
    var artifact_buffer: [256]u8 = undefined;
    var entry_name_buffer: [128]u8 = undefined;

    const runner = Runner{
        .config = config,
        .target = .{
            .context = &target_context,
            .run_fn = TargetContext.run,
        },
        .persistence = .{
            .io = io,
            .dir = output_dir,
            .naming = .{ .prefix = "phase2_fuzz_example" },
            .artifact_buffer = &artifact_buffer,
            .entry_name_buffer = &entry_name_buffer,
        },
        .seed_reducer = .{
            .context = &reducer_context,
            .measure_fn = ReducerContext.measure,
            .next_fn = ReducerContext.next,
            .is_interesting_fn = ReducerContext.isInteresting,
        },
    };

    const summary = try runner.run();
    assert(summary.failed_case != null);

    const failed_case = summary.failed_case.?;
    assert(failed_case.persisted_entry_name != null);
    assert(failed_case.reduced_seed != null);
    assert(failed_case.run_identity.seed.value < first_failing.seed.value);
    assert(failed_case.run_identity.seed.value >= failure_threshold);
    assert(failed_case.run_identity.seed.value < failure_threshold * 2);
}

fn deleteTreeIfPresent(
    dir: std.Io.Dir,
    io: std.Io,
    sub_path: []const u8,
) !void {
    try dir.deleteTree(io, sub_path);
}

fn cleanupOutputDir(
    dir: std.Io.Dir,
    io: std.Io,
    sub_path: []const u8,
) void {
    dir.deleteTree(io, sub_path) catch |err| {
        std.log.warn("Best-effort cleanupOutputDir failed for {s}: {s}.", .{
            sub_path,
            @errorName(err),
        });
    };
}

const TargetContext = struct {
    threshold: u64,

    fn run(
        context_ptr: *const anyopaque,
        run_identity: testing.testing.identity.RunIdentity,
    ) error{}!testing.testing.fuzz_runner.FuzzExecution {
        const context: *const TargetContext = @ptrCast(@alignCast(context_ptr));
        const failing = run_identity.seed.value >= context.threshold;

        return .{
            .trace_metadata = makeTraceMetadata(run_identity),
            .check_result = if (failing)
                testing.testing.checker.CheckResult.fail(&violations, null)
            else
                testing.testing.checker.CheckResult.pass(null),
        };
    }
};

const ReducerContext = struct {
    threshold: u64,

    fn measure(_: *const anyopaque, candidate: testing.testing.seed.Seed) u64 {
        return candidate.value;
    }

    fn next(
        _: *const anyopaque,
        current: testing.testing.seed.Seed,
        _: u32,
    ) error{}!?testing.testing.seed.Seed {
        if (current.value <= 1) return null;
        return testing.testing.seed.Seed.init(@divFloor(current.value, 2));
    }

    fn isInteresting(
        context_ptr: *const anyopaque,
        candidate: testing.testing.seed.Seed,
    ) error{}!bool {
        const context: *const ReducerContext = @ptrCast(@alignCast(context_ptr));
        return candidate.value >= context.threshold;
    }
};

const FirstFailingSeed = struct {
    case_index: u32,
    seed: testing.testing.seed.Seed,
};

fn findFirstFailingSeed(
    config: testing.testing.fuzz_runner.FuzzConfig,
) ?FirstFailingSeed {
    var case_index: u32 = 0;
    while (case_index < config.case_count_max) : (case_index += 1) {
        const case_seed = testing.testing.seed.splitSeed(config.base_seed, case_index);
        if (case_seed.value >= failure_threshold) {
            return .{
                .case_index = case_index,
                .seed = case_seed,
            };
        }
    }
    return null;
}

fn makeTraceMetadata(
    run_identity: testing.testing.identity.RunIdentity,
) testing.testing.trace.TraceMetadata {
    const timestamp_ns = run_identity.seed.value & 0xffff;
    return .{
        .event_count = 1,
        .truncated = false,
        .has_range = true,
        .first_sequence_no = run_identity.case_index,
        .last_sequence_no = run_identity.case_index,
        .first_timestamp_ns = timestamp_ns,
        .last_timestamp_ns = timestamp_ns,
    };
}
