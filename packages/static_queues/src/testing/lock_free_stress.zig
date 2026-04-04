const std = @import("std");
const caps = @import("../queues/caps.zig");
const lock_free_mpsc_mod = @import("../queues/lock_free_mpsc.zig");
const chase_lev_mod = @import("../queues/chase_lev_deque.zig");

pub const StressConfig = struct {
    iterations_max: u32 = 500_000,
    time_budget_ms_max: u64 = 2_000,
};

pub fn runLockFreeMpscStress(allocator: std.mem.Allocator, cfg: StressConfig) !void {
    if (caps.shouldSkipThreadedTests()) return error.SkipZigTest;

    const Q = lock_free_mpsc_mod.LockFreeMpscQueue(u32);
    const producer_count: usize = 3;
    const items_per_producer: u32 = 256;
    const send_attempts_max: u32 = 8_192;
    const total_items: u32 = @intCast(producer_count * items_per_producer);

    var queue = try Q.init(allocator, .{
        .capacity = 64,
        .cas_retries_max = 128,
        .backoff_exponent_max = 4,
    });
    defer queue.deinit();

    const seen = try allocator.alloc(std.atomic.Value(u8), total_items);
    defer allocator.free(seen);
    for (seen) |*slot| slot.* = std.atomic.Value(u8).init(0);

    var producer_done = std.atomic.Value(u32).init(0);
    var producer_failed = std.atomic.Value(bool).init(false);
    var received_count = std.atomic.Value(u32).init(0);
    var duplicate_count = std.atomic.Value(u32).init(0);
    var out_of_range_count = std.atomic.Value(u32).init(0);

    const Producer = struct {
        queue: *Q,
        producer_id: u32,
        producer_done: *std.atomic.Value(u32),
        producer_failed: *std.atomic.Value(bool),

        fn run(self: *@This()) void {
            var item_index: u32 = 0;
            while (item_index < items_per_producer) : (item_index += 1) {
                const value = self.producer_id * items_per_producer + item_index;
                var attempts: u32 = 0;
                while (attempts < send_attempts_max) : (attempts += 1) {
                    self.queue.trySend(value) catch |err| switch (err) {
                        error.WouldBlock => {
                            std.Thread.yield() catch {};
                            continue;
                        },
                    };
                    break;
                }
                if (attempts == send_attempts_max) {
                    self.producer_failed.store(true, .release);
                    break;
                }
            }
            _ = self.producer_done.fetchAdd(1, .acq_rel);
        }
    };

    var producer_states: [producer_count]Producer = undefined;
    var producer_threads: [producer_count]std.Thread = undefined;
    for (&producer_states, &producer_threads, 0..) |*state, *thread, producer_index| {
        state.* = .{
            .queue = &queue,
            .producer_id = @intCast(producer_index),
            .producer_done = &producer_done,
            .producer_failed = &producer_failed,
        };
        thread.* = try std.Thread.spawn(.{}, Producer.run, .{state});
    }

    const start_instant = std.time.Instant.now() catch return error.SkipZigTest;
    var consumer_iterations: u32 = 0;
    while (consumer_iterations < cfg.iterations_max) : (consumer_iterations += 1) {
        const value = queue.tryRecv() catch |err| switch (err) {
            error.WouldBlock => {
                if (producer_done.load(.acquire) == producer_count and received_count.load(.acquire) == total_items) break;
                if (timeBudgetExceeded(start_instant, cfg.time_budget_ms_max)) break;
                std.Thread.yield() catch {};
                continue;
            },
        };
        recordConsumedValue(value, seen, &received_count, &duplicate_count, &out_of_range_count);
        if (producer_done.load(.acquire) == producer_count and received_count.load(.acquire) == total_items) break;
        if (timeBudgetExceeded(start_instant, cfg.time_budget_ms_max)) break;
    }

    for (&producer_threads) |*thread| thread.join();

    var drain_iterations: u32 = 0;
    while (drain_iterations < cfg.iterations_max) : (drain_iterations += 1) {
        const value = queue.tryRecv() catch |err| switch (err) {
            error.WouldBlock => break,
        };
        recordConsumedValue(value, seen, &received_count, &duplicate_count, &out_of_range_count);
    }

    try std.testing.expectEqual(@as(u32, @intCast(producer_count)), producer_done.load(.acquire));
    try std.testing.expect(!producer_failed.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), duplicate_count.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), out_of_range_count.load(.acquire));
    try std.testing.expectEqual(total_items, received_count.load(.acquire));
}

pub fn runChaseLevStress(allocator: std.mem.Allocator, cfg: StressConfig) !void {
    if (caps.shouldSkipThreadedTests()) return error.SkipZigTest;

    const D = chase_lev_mod.ChaseLevDeque(u32);
    const thief_count: usize = 2;
    const total_items: u32 = 512;
    const push_attempts_max: u32 = 8_192;

    var deque = try D.init(allocator, .{
        .capacity = 128,
        .cas_retries_max = 128,
        .backoff_exponent_max = 4,
    });
    defer deque.deinit();

    const seen = try allocator.alloc(std.atomic.Value(u8), total_items);
    defer allocator.free(seen);
    for (seen) |*slot| slot.* = std.atomic.Value(u8).init(0);

    var produced_count = std.atomic.Value(u32).init(0);
    var consumed_count = std.atomic.Value(u32).init(0);
    var duplicate_count = std.atomic.Value(u32).init(0);
    var out_of_range_count = std.atomic.Value(u32).init(0);
    var push_failed = std.atomic.Value(bool).init(false);
    var pushing_done = std.atomic.Value(bool).init(false);
    var stop_thieves = std.atomic.Value(bool).init(false);

    const Thief = struct {
        deque: *D,
        produced_count: *std.atomic.Value(u32),
        consumed_count: *std.atomic.Value(u32),
        duplicate_count: *std.atomic.Value(u32),
        out_of_range_count: *std.atomic.Value(u32),
        pushing_done: *std.atomic.Value(bool),
        stop_thieves: *std.atomic.Value(bool),
        seen: []std.atomic.Value(u8),
        iterations_max: u32,

        fn run(self: *@This()) void {
            var iterations: u32 = 0;
            while (iterations < self.iterations_max) : (iterations += 1) {
                if (self.stop_thieves.load(.acquire)) break;
                const produced = self.produced_count.load(.acquire);
                if (self.pushing_done.load(.acquire) and self.consumed_count.load(.acquire) >= produced) break;

                const value = self.deque.stealTop() catch |err| switch (err) {
                    error.WouldBlock => {
                        std.Thread.yield() catch {};
                        continue;
                    },
                };
                recordConsumedValue(value, self.seen, self.consumed_count, self.duplicate_count, self.out_of_range_count);
            }
        }
    };

    var thief_states: [thief_count]Thief = undefined;
    var thief_threads: [thief_count]std.Thread = undefined;
    for (&thief_states, &thief_threads) |*state, *thread| {
        state.* = .{
            .deque = &deque,
            .produced_count = &produced_count,
            .consumed_count = &consumed_count,
            .duplicate_count = &duplicate_count,
            .out_of_range_count = &out_of_range_count,
            .pushing_done = &pushing_done,
            .stop_thieves = &stop_thieves,
            .seen = seen,
            .iterations_max = cfg.iterations_max,
        };
        thread.* = try std.Thread.spawn(.{}, Thief.run, .{state});
    }

    const start_instant = std.time.Instant.now() catch return error.SkipZigTest;
    var next_value: u32 = 0;
    while (next_value < total_items) : (next_value += 1) {
        var attempts: u32 = 0;
        while (attempts < push_attempts_max) : (attempts += 1) {
            deque.pushBottom(next_value) catch |err| switch (err) {
                error.WouldBlock => {
                    const popped = deque.popBottom() catch |pop_err| switch (pop_err) {
                        error.WouldBlock => {
                            std.Thread.yield() catch {};
                            if (timeBudgetExceeded(start_instant, cfg.time_budget_ms_max)) break;
                            continue;
                        },
                    };
                    recordConsumedValue(popped, seen, &consumed_count, &duplicate_count, &out_of_range_count);
                    if (timeBudgetExceeded(start_instant, cfg.time_budget_ms_max)) break;
                    continue;
                },
            };
            _ = produced_count.fetchAdd(1, .acq_rel);
            break;
        }
        if (attempts == push_attempts_max) {
            push_failed.store(true, .release);
            break;
        }
        if (timeBudgetExceeded(start_instant, cfg.time_budget_ms_max)) {
            push_failed.store(true, .release);
            break;
        }
    }
    pushing_done.store(true, .release);

    var owner_drain_iterations: u32 = 0;
    while (owner_drain_iterations < cfg.iterations_max) : (owner_drain_iterations += 1) {
        const produced = produced_count.load(.acquire);
        if (consumed_count.load(.acquire) >= produced and produced > 0) break;
        const value = deque.popBottom() catch |err| switch (err) {
            error.WouldBlock => {
                if (timeBudgetExceeded(start_instant, cfg.time_budget_ms_max)) break;
                std.Thread.yield() catch {};
                continue;
            },
        };
        recordConsumedValue(value, seen, &consumed_count, &duplicate_count, &out_of_range_count);
        if (timeBudgetExceeded(start_instant, cfg.time_budget_ms_max)) break;
    }

    stop_thieves.store(true, .release);
    for (&thief_threads) |*thread| thread.join();

    var final_drain_iterations: u32 = 0;
    while (final_drain_iterations < cfg.iterations_max) : (final_drain_iterations += 1) {
        const value = deque.popBottom() catch |err| switch (err) {
            error.WouldBlock => break,
        };
        recordConsumedValue(value, seen, &consumed_count, &duplicate_count, &out_of_range_count);
    }

    try std.testing.expect(!push_failed.load(.acquire));
    try std.testing.expectEqual(total_items, produced_count.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), duplicate_count.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), out_of_range_count.load(.acquire));
    try std.testing.expectEqual(produced_count.load(.acquire), consumed_count.load(.acquire));
}

fn recordConsumedValue(
    value: u32,
    seen: []std.atomic.Value(u8),
    consumed_count: *std.atomic.Value(u32),
    duplicate_count: *std.atomic.Value(u32),
    out_of_range_count: *std.atomic.Value(u32),
) void {
    const seen_len_u32: u32 = @intCast(seen.len);
    if (value >= seen_len_u32) {
        _ = out_of_range_count.fetchAdd(1, .acq_rel);
        return;
    }

    const index: usize = @intCast(value);
    if (seen[index].cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) {
        _ = consumed_count.fetchAdd(1, .acq_rel);
        return;
    }
    _ = duplicate_count.fetchAdd(1, .acq_rel);
}

fn timeBudgetExceeded(start: std.time.Instant, time_budget_ms_max: u64) bool {
    const now = std.time.Instant.now() catch return true;
    const elapsed_ns = now.since(start);
    const budget_ns = std.math.mul(u64, time_budget_ms_max, std.time.ns_per_ms) catch return true;
    return elapsed_ns >= budget_ns;
}
