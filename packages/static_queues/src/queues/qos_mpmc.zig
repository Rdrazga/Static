//! QosMpmcQueue: multi-lane bounded MPMC composition with receive scheduling.
//!
//! Capacity: fixed at init time; each lane uses a bounded `MpmcQueue`.
//! Thread safety: multiple concurrent producers and consumers.
//! - Producers operate directly on per-lane lock-free queues.
//! - Receive scheduling state is serialized by an internal mutex.
//! Blocking behavior: non-blocking; returns `error.WouldBlock` when no lane can make progress.
const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const memory = @import("static_memory");
const sync = @import("static_sync");
const mpmc = @import("mpmc.zig");
const contracts = @import("../contracts.zig");

pub fn QosMpmcQueue(comptime T: type, comptime lane_count_max: usize) type {
    comptime {
        assert(@sizeOf(T) > 0);
        assert(@alignOf(T) > 0);
        assert(lane_count_max > 0);
    }

    return struct {
        const Self = @This();
        const LaneQueue = mpmc.MpmcQueue(T);

        pub const Element = T;
        pub const Error = LaneQueue.Error;
        pub const concurrency: contracts.Concurrency = .mpmc;
        pub const is_lock_free = false;
        pub const supports_close = false;
        pub const supports_blocking_wait = false;
        pub const len_semantics: contracts.LenSemantics = .approximate;
        pub const TrySendError = error{ WouldBlock, InvalidLane };
        pub const TryRecvError = error{WouldBlock};
        pub const SchedulingPolicy = enum {
            weighted_round_robin,
            strict_priority,
        };
        pub const Config = struct {
            lane_capacity: usize,
            lane_weights_recv: [lane_count_max]u16 = [_]u16{1} ** lane_count_max,
            scheduling_policy: SchedulingPolicy = .weighted_round_robin,
            cas_retries_max: u32 = 1024,
            backoff_exponent_max: u8 = 0,
            budget: ?*memory.budget.Budget = null,
        };

        lanes: [lane_count_max]LaneQueue,
        lane_weights_recv: [lane_count_max]u16,
        scheduling_policy: SchedulingPolicy,
        next_lane_index: usize = 0,
        lane_budget_remaining: u16 = 0,
        recv_scheduler_mutex: std.Thread.Mutex = .{},

        pub fn init(allocator: std.mem.Allocator, cfg: Config) Error!Self {
            var lane_index: usize = 0;
            while (lane_index < lane_count_max) : (lane_index += 1) {
                if (cfg.lane_weights_recv[lane_index] == 0) return error.InvalidConfig;
            }

            var lanes: [lane_count_max]LaneQueue = undefined;
            var initialized_count: usize = 0;
            errdefer {
                var deinit_index: usize = 0;
                while (deinit_index < initialized_count) : (deinit_index += 1) {
                    lanes[deinit_index].deinit();
                }
            }

            lane_index = 0;
            while (lane_index < lane_count_max) : (lane_index += 1) {
                lanes[lane_index] = try LaneQueue.init(allocator, .{
                    .capacity = cfg.lane_capacity,
                    .cas_retries_max = cfg.cas_retries_max,
                    .backoff_exponent_max = cfg.backoff_exponent_max,
                    .budget = cfg.budget,
                });
                initialized_count += 1;
            }

            const self: Self = .{
                .lanes = lanes,
                .lane_weights_recv = cfg.lane_weights_recv,
                .scheduling_policy = cfg.scheduling_policy,
            };
            assert(self.laneCount() == lane_count_max);
            assert(self.capacity() >= self.laneCapacity());
            return self;
        }

        pub fn deinit(self: *Self) void {
            var lane_index: usize = 0;
            while (lane_index < lane_count_max) : (lane_index += 1) {
                self.lanes[lane_index].deinit();
            }
            self.* = undefined;
        }

        pub fn laneCount(self: *const Self) usize {
            _ = self;
            return lane_count_max;
        }

        pub fn laneCapacity(self: *const Self) usize {
            return self.lanes[0].capacity();
        }

        pub fn capacity(self: *const Self) usize {
            return lane_count_max * self.laneCapacity();
        }

        pub fn len(self: *const Self) usize {
            var total_len: usize = 0;
            var lane_index: usize = 0;
            while (lane_index < lane_count_max) : (lane_index += 1) {
                total_len += self.lanes[lane_index].len();
            }
            assert(total_len <= self.capacity());
            return total_len;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.len() == 0;
        }

        pub fn trySend(self: *Self, lane_index: usize, value: T) TrySendError!void {
            if (lane_index >= lane_count_max) return error.InvalidLane;
            self.lanes[lane_index].trySend(value) catch return error.WouldBlock;
        }

        pub fn tryRecv(self: *Self) TryRecvError!T {
            self.recv_scheduler_mutex.lock();
            defer self.recv_scheduler_mutex.unlock();
            return switch (self.scheduling_policy) {
                .strict_priority => self.tryRecvStrictPriority(),
                .weighted_round_robin => self.tryRecvWeightedRoundRobin(),
            };
        }

        pub fn tryRecvFromLane(self: *Self, lane_index: usize) error{ WouldBlock, InvalidLane }!T {
            if (lane_index >= lane_count_max) return error.InvalidLane;
            return self.lanes[lane_index].tryRecv() catch return error.WouldBlock;
        }

        fn tryRecvStrictPriority(self: *Self) TryRecvError!T {
            var lane_index: usize = 0;
            while (lane_index < lane_count_max) : (lane_index += 1) {
                return self.lanes[lane_index].tryRecv() catch |err| switch (err) {
                    error.WouldBlock => continue,
                };
            }
            return error.WouldBlock;
        }

        fn tryRecvWeightedRoundRobin(self: *Self) TryRecvError!T {
            const attempt_limit = lane_count_max * 2;
            var attempts: usize = 0;
            while (attempts < attempt_limit) : (attempts += 1) {
                const lane_index = self.next_lane_index;
                if (self.lane_budget_remaining == 0) {
                    self.lane_budget_remaining = self.lane_weights_recv[lane_index];
                }
                assert(self.lane_budget_remaining > 0);

                const value = self.lanes[lane_index].tryRecv() catch |err| switch (err) {
                    error.WouldBlock => {
                        self.lane_budget_remaining = 0;
                        self.advanceLane();
                        continue;
                    },
                };
                self.lane_budget_remaining -= 1;
                if (self.lane_budget_remaining == 0) {
                    self.advanceLane();
                }
                return value;
            }
            return error.WouldBlock;
        }

        fn advanceLane(self: *Self) void {
            const next_lane_index = self.next_lane_index + 1;
            self.next_lane_index = if (next_lane_index == lane_count_max) 0 else next_lane_index;
        }
    };
}

test "qos mpmc strict-priority mode drains higher priority lane first" {
    const Q = QosMpmcQueue(u8, 2);
    var q = try Q.init(testing.allocator, .{
        .lane_capacity = 4,
        .scheduling_policy = .strict_priority,
    });
    defer q.deinit();

    try q.trySend(1, 20);
    try q.trySend(0, 10);

    try testing.expectEqual(@as(u8, 10), try q.tryRecv());
    try testing.expectEqual(@as(u8, 20), try q.tryRecv());
}

test "qos mpmc weighted round-robin mode consumes by configured receive weights" {
    const Q = QosMpmcQueue(u8, 2);
    var q = try Q.init(testing.allocator, .{
        .lane_capacity = 4,
        .lane_weights_recv = .{ 2, 1 },
        .scheduling_policy = .weighted_round_robin,
    });
    defer q.deinit();

    try q.trySend(0, 10);
    try q.trySend(0, 11);
    try q.trySend(1, 20);

    try testing.expectEqual(@as(u8, 10), try q.tryRecv());
    try testing.expectEqual(@as(u8, 11), try q.tryRecv());
    try testing.expectEqual(@as(u8, 20), try q.tryRecv());
}

test "qos mpmc validates lane index and lane weight configuration" {
    const Q = QosMpmcQueue(u8, 2);
    try testing.expectError(error.InvalidConfig, Q.init(testing.allocator, .{
        .lane_capacity = 4,
        .lane_weights_recv = .{ 1, 0 },
    }));

    var q = try Q.init(testing.allocator, .{ .lane_capacity = 2 });
    defer q.deinit();
    try testing.expectError(error.InvalidLane, q.trySend(2, 1));
    try testing.expectError(error.InvalidLane, q.tryRecvFromLane(2));
}
