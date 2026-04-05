const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const static_scheduling = @import("static_scheduling");

test "executor join reports timeout while a worker is blocked, then completes after release" {
    const Executor = static_scheduling.executor.Executor;

    const JobState = struct {
        started: *std.atomic.Value(bool),
        release: *std.atomic.Value(bool),
        finished: *std.atomic.Value(u32),

        fn run(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.started.store(true, .release);
            while (!self.release.load(.acquire)) {
                std.Thread.yield() catch {};
            }
            _ = self.finished.fetchAdd(1, .acq_rel);
        }
    };

    var started = std.atomic.Value(bool).init(false);
    var release = std.atomic.Value(bool).init(false);
    var finished = std.atomic.Value(u32).init(0);
    var job_state = JobState{
        .started = &started,
        .release = &release,
        .finished = &finished,
    };

    var executor = Executor.init(testing.allocator, .{
        .jobs_max = 1,
        .worker_count = 1,
        .queue_capacity = 1,
    }) catch |err| switch (err) {
        error.Unsupported => return error.SkipZigTest,
        else => return err,
    };
    defer executor.deinit();

    const job_id = try executor.trySpawn(.{
        .ctx = &job_state,
        .run = JobState.run,
    });

    assert(waitForBool(&started, true, 20_000));

    try testing.expectError(error.Timeout, executor.join(job_id, null, 0));
    try testing.expectError(error.WouldBlock, executor.tryJoin(job_id));

    release.store(true, .release);
    try executor.join(job_id, null, 50 * std.time.ns_per_ms);

    try testing.expectEqual(@as(u32, 1), finished.load(.acquire));
    try testing.expectError(error.NotFound, executor.tryJoin(job_id));
}

fn waitForBool(counter: *const std.atomic.Value(bool), expected: bool, iterations_max: u32) bool {
    var iterations: u32 = 0;
    while (iterations < iterations_max) : (iterations += 1) {
        if (counter.load(.acquire) == expected) return true;
        std.Thread.yield() catch {};
    }
    return false;
}
