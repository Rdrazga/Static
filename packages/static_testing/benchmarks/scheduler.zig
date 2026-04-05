//! Benchmarks deterministic scheduler decision recording and replay.
//!
//! The benchmark names intentionally include enqueue/setup cost so the compared
//! cases cover the full public scheduler workflow per ready set.
//!
//! Run with:
//! - `zig build bench -Doptimize=ReleaseFast` (from `packages/static_testing`).

const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const static_testing = @import("static_testing");

const bench = static_testing.bench;
const scheduler_mod = static_testing.testing.sim.scheduler;

const ready_items_count: usize = 64;

const RecordContext = struct {
    base_seed: static_testing.testing.seed.Seed,
    strategy: scheduler_mod.SchedulerStrategy,
    ready_items: [ready_items_count]scheduler_mod.ReadyItem,
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *@This() = @ptrCast(@alignCast(context_ptr));
        var ready_storage: [ready_items_count]scheduler_mod.ReadyItem = undefined;
        var decision_storage: [ready_items_count]scheduler_mod.ScheduleDecision = undefined;
        var scheduler = scheduler_mod.Scheduler.init(
            context.base_seed,
            &ready_storage,
            &decision_storage,
            .{ .strategy = context.strategy },
            null,
        ) catch |err| {
            panic("Scheduler.init failed: {s}", .{@errorName(err)});
        };

        for (context.ready_items) |ready_item| {
            scheduler.enqueueReady(ready_item) catch |err| {
                panic("Scheduler.enqueueReady failed: {s}", .{@errorName(err)});
            };
        }

        var chosen_id_sum: u64 = 0;
        var decisions_total: usize = 0;
        while (scheduler.hasReady()) {
            const decision = scheduler.nextDecision() catch |err| {
                panic("Scheduler.nextDecision failed: {s}", .{@errorName(err)});
            };
            chosen_id_sum +%= decision.chosen_id;
            decisions_total += 1;
        }

        assert(decisions_total == ready_items_count);
        context.sink +%= chosen_id_sum;
        _ = bench.case.blackBox(context.sink);
    }
};

const ReplayContext = struct {
    ready_items: [ready_items_count]scheduler_mod.ReadyItem,
    recorded_decisions: [ready_items_count]scheduler_mod.ScheduleDecision,
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *@This() = @ptrCast(@alignCast(context_ptr));
        var ready_storage: [ready_items_count]scheduler_mod.ReadyItem = undefined;
        var decision_storage: [ready_items_count]scheduler_mod.ScheduleDecision = undefined;
        var scheduler = scheduler_mod.Scheduler.init(
            .init(9999),
            &ready_storage,
            &decision_storage,
            .{ .strategy = .first },
            null,
        ) catch |err| {
            panic("Scheduler.init failed: {s}", .{@errorName(err)});
        };

        for (context.ready_items) |ready_item| {
            scheduler.enqueueReady(ready_item) catch |err| {
                panic("Scheduler.enqueueReady failed: {s}", .{@errorName(err)});
            };
        }

        var chosen_id_sum: u64 = 0;
        for (context.recorded_decisions) |recorded| {
            const replayed = scheduler.applyRecordedDecision(recorded) catch |err| {
                panic("Scheduler.applyRecordedDecision failed: {s}", .{@errorName(err)});
            };
            chosen_id_sum +%= replayed.chosen_id;
        }

        assert(!scheduler.hasReady());
        context.sink +%= chosen_id_sum;
        _ = bench.case.blackBox(context.sink);
    }
};

fn makeReadyItems() [ready_items_count]scheduler_mod.ReadyItem {
    var ready_items: [ready_items_count]scheduler_mod.ReadyItem = undefined;
    for (&ready_items, 0..) |*ready_item, index| {
        const id = @as(u32, @intCast(index + 1));
        ready_item.* = .{
            .id = id,
            .value = @as(u64, id) * 10,
        };
    }
    return ready_items;
}

fn sumReadyIds(ready_items: []const scheduler_mod.ReadyItem) u64 {
    var sum: u64 = 0;
    for (ready_items) |ready_item| sum += ready_item.id;
    return sum;
}

fn buildRecordedDecisions(
    base_seed: static_testing.testing.seed.Seed,
    ready_items: [ready_items_count]scheduler_mod.ReadyItem,
) ![ready_items_count]scheduler_mod.ScheduleDecision {
    var ready_storage: [ready_items_count]scheduler_mod.ReadyItem = undefined;
    var decision_storage: [ready_items_count]scheduler_mod.ScheduleDecision = undefined;
    var scheduler = try scheduler_mod.Scheduler.init(
        base_seed,
        &ready_storage,
        &decision_storage,
        .{ .strategy = .seeded },
        null,
    );

    for (ready_items) |ready_item| try scheduler.enqueueReady(ready_item);
    while (scheduler.hasReady()) _ = try scheduler.nextDecision();
    assert(scheduler.recordedDecisions().len == ready_items_count);

    var recorded: [ready_items_count]scheduler_mod.ScheduleDecision = undefined;
    std.mem.copyForwards(
        scheduler_mod.ScheduleDecision,
        &recorded,
        scheduler.recordedDecisions(),
    );
    return recorded;
}

fn verifySchedulerBenchmarkInputs(
    ready_items: [ready_items_count]scheduler_mod.ReadyItem,
    recorded_decisions: [ready_items_count]scheduler_mod.ScheduleDecision,
) !void {
    const expected_sum = sumReadyIds(&ready_items);

    var record_context = RecordContext{
        .base_seed = .init(1234),
        .strategy = .seeded,
        .ready_items = ready_items,
    };
    RecordContext.run(&record_context);
    assert(record_context.sink == expected_sum);

    var replay_context = ReplayContext{
        .ready_items = ready_items,
        .recorded_decisions = recorded_decisions,
    };
    ReplayContext.run(&replay_context);
    assert(replay_context.sink == expected_sum);
}

fn runBenchmarkGroup(
    group: *const bench.group.BenchmarkGroup,
    sample_storage: []bench.runner.BenchmarkSample,
    case_result_storage: []bench.runner.BenchmarkCaseResult,
) !void {
    const run_result = try bench.runner.runGroup(group, sample_storage, case_result_storage);

    std.debug.print("mode: {s}\n", .{@tagName(run_result.mode)});
    for (run_result.case_results) |case_result| {
        const derived = try bench.stats.computeStats(case_result);
        std.debug.print(
            "case {s} samples={d} median_elapsed_ns={d} mean_elapsed_ns={d}\n",
            .{
                derived.case_name,
                derived.sample_count,
                derived.median_elapsed_ns,
                derived.mean_elapsed_ns,
            },
        );
    }
}

pub fn main() !void {
    const ready_items = makeReadyItems();
    const recorded_decisions = try buildRecordedDecisions(.init(1234), ready_items);
    try verifySchedulerBenchmarkInputs(ready_items, recorded_decisions);

    var first_context = RecordContext{
        .base_seed = .init(1234),
        .strategy = .first,
        .ready_items = ready_items,
    };
    var seeded_context = RecordContext{
        .base_seed = .init(1234),
        .strategy = .seeded,
        .ready_items = ready_items,
    };
    var replay_context = ReplayContext{
        .ready_items = ready_items,
        .recorded_decisions = recorded_decisions,
    };

    var case_storage: [3]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "bench_scheduler",
        .config = .{
            .mode = .full,
            .warmup_iterations = 1,
            .measure_iterations = 32,
            .sample_count = 5,
        },
    });
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "scheduler.first.enqueue+record.n64",
        .context = &first_context,
        .run_fn = RecordContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "scheduler.seeded.enqueue+record.n64",
        .context = &seeded_context,
        .run_fn = RecordContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "scheduler.replay.enqueue+apply.n64",
        .context = &replay_context,
        .run_fn = ReplayContext.run,
    }));

    var bench_samples: [15]bench.runner.BenchmarkSample = undefined;
    var case_results: [3]bench.runner.BenchmarkCaseResult = undefined;
    try runBenchmarkGroup(&group, &bench_samples, &case_results);

    _ = bench.case.blackBox(first_context.sink);
    _ = bench.case.blackBox(seeded_context.sink);
    _ = bench.case.blackBox(replay_context.sink);
}
