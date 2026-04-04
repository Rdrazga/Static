//! Delayed deterministic event queue over `static_scheduling.timer_wheel`.
//!
//! Timer payloads are stored and drained by value. Prefer small ids, handles,
//! or pointer-like wrappers for large payloads so delayed delivery does not
//! hide large copies.

const std = @import("std");
const scheduling = @import("static_scheduling");
const clock = @import("clock.zig");

/// Public timer queue operating errors.
pub const TimerQueueError = error{
    InvalidConfig,
    InvalidInput,
    OutOfMemory,
    NoSpaceLeft,
    NotFound,
    Overflow,
};

/// Timer queue setup options.
pub const TimerQueueConfig = struct {
    buckets: u32,
    timers_max: u32,
};

/// Delayed event queue wrapper that converts absolute logical time into timer-wheel ticks.
pub fn TimerQueue(comptime T: type) type {
    return struct {
        const Self = @This();
        const Wheel = scheduling.timer_wheel.TimerWheel(T);

        const TimerMeta = struct {
            active: bool = false,
            generation: u32 = 0,
            due_time: clock.LogicalTime = .init(0),
        };

        sim_clock: *clock.SimClock,
        time_origin: clock.LogicalTime,
        wheel: Wheel,
        meta: []TimerMeta,
        drain_storage: []T,

        pub const TimerId = scheduling.timer_wheel.TimerId;

        /// Allocate one timer queue with fixed wheel and metadata capacity.
        pub fn init(
            allocator: std.mem.Allocator,
            sim_clock: *clock.SimClock,
            config: TimerQueueConfig,
        ) TimerQueueError!Self {
            if (config.timers_max == 0) return error.InvalidConfig;
            const wheel = Wheel.init(allocator, .{
                .buckets = config.buckets,
                .entries_max = config.timers_max,
            }) catch |err| return mapWheelError(err);
            errdefer {
                var owned_wheel = wheel;
                owned_wheel.deinit();
            }

            const meta = allocator.alloc(TimerMeta, config.timers_max) catch return error.OutOfMemory;
            errdefer allocator.free(meta);
            @memset(meta, .{});

            const drain_storage = allocator.alloc(T, config.timers_max) catch return error.OutOfMemory;
            errdefer allocator.free(drain_storage);

            return .{
                .sim_clock = sim_clock,
                .time_origin = sim_clock.now(),
                .wheel = wheel,
                .meta = meta,
                .drain_storage = drain_storage,
            };
        }

        /// Release queue storage and invalidate the instance.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.wheel.deinit();
            allocator.free(self.drain_storage);
            allocator.free(self.meta);
            self.* = undefined;
        }

        /// Schedule one value to fire at one explicit future logical time.
        pub fn scheduleAt(self: *Self, value: T, due_time: clock.LogicalTime) TimerQueueError!TimerId {
            const now_time = self.sim_clock.now();
            if (due_time.tick <= now_time.tick) return error.InvalidInput;

            const distance_ticks = due_time.tick - now_time.tick;
            std.debug.assert(distance_ticks > 0);
            const wheel_delay_ticks = distance_ticks - 1;
            const timer_id = self.wheel.schedule(value, wheel_delay_ticks) catch |err| {
                return mapWheelError(err);
            };
            self.setMeta(timer_id, due_time);
            return timer_id;
        }

        /// Schedule one value after one positive logical delay.
        pub fn scheduleAfter(self: *Self, value: T, delay: clock.LogicalDuration) TimerQueueError!TimerId {
            if (delay.ticks == 0) return error.InvalidInput;
            const due_time = try self.sim_clock.now().add(delay);
            return self.scheduleAt(value, due_time);
        }

        /// Cancel one active timer and return its stored payload by value.
        pub fn cancel(self: *Self, timer_id: TimerId) TimerQueueError!T {
            const entry = self.wheel.cancel(timer_id) catch |err| return mapWheelError(err);
            self.clearMetaById(timer_id);
            return entry;
        }

        /// Report the earliest due time among all active timers.
        pub fn nextDueTime(self: *const Self) ?clock.LogicalTime {
            var found_due_time: ?clock.LogicalTime = null;
            for (self.meta) |meta| {
                if (!meta.active) continue;
                if (found_due_time == null or meta.due_time.tick < found_due_time.?.tick) {
                    found_due_time = meta.due_time;
                }
            }
            return found_due_time;
        }

        /// Count timers due at or before `now_time` without mutating wheel state.
        pub fn dueCountUpTo(self: *const Self, now_time: clock.LogicalTime) usize {
            return self.countDueUpTo(now_time);
        }

        /// Drain all timers due at the current logical time into caller storage.
        pub fn drainDue(self: *Self, out: []T) TimerQueueError!u32 {
            const target_relative_tick = try self.relativeNowTick();
            const due_total = self.countDueUpTo(self.sim_clock.now());
            if (due_total > out.len) return error.NoSpaceLeft;

            var out_len: usize = 0;
            while (self.wheel.nowTick() < target_relative_tick) {
                const drained_count = self.wheel.tick(self.drain_storage) catch |err| {
                    return mapWheelError(err);
                };
                if (drained_count == 0) continue;

                std.mem.copyForwards(T, out[out_len .. out_len + drained_count], self.drain_storage[0..drained_count]);
                out_len += drained_count;
                self.clearDueMeta(try self.absoluteWheelTime(), drained_count);
            }

            std.debug.assert(out_len == due_total);
            return @as(u32, @intCast(out_len));
        }

        fn setMeta(self: *Self, timer_id: TimerId, due_time: clock.LogicalTime) void {
            std.debug.assert(timer_id.index < self.meta.len);
            self.meta[timer_id.index] = .{
                .active = true,
                .generation = timer_id.generation,
                .due_time = due_time,
            };
        }

        fn clearMetaById(self: *Self, timer_id: TimerId) void {
            std.debug.assert(timer_id.index < self.meta.len);
            if (self.meta[timer_id.index].active and self.meta[timer_id.index].generation == timer_id.generation) {
                self.meta[timer_id.index].active = false;
            }
        }

        fn clearDueMeta(self: *Self, due_time: clock.LogicalTime, count: u32) void {
            var cleared_count: u32 = 0;
            for (self.meta) |*meta| {
                if (!meta.active) continue;
                if (meta.due_time.tick != due_time.tick) continue;
                meta.active = false;
                cleared_count += 1;
                if (cleared_count == count) break;
            }
            std.debug.assert(cleared_count == count);
        }

        fn countDueUpTo(self: *const Self, now_time: clock.LogicalTime) usize {
            var count: usize = 0;
            for (self.meta) |meta| {
                if (meta.active and meta.due_time.tick <= now_time.tick) count += 1;
            }
            return count;
        }

        fn relativeNowTick(self: *const Self) TimerQueueError!u64 {
            if (self.sim_clock.now().tick < self.time_origin.tick) return error.InvalidInput;
            return self.sim_clock.now().tick - self.time_origin.tick;
        }

        fn absoluteWheelTime(self: *const Self) TimerQueueError!clock.LogicalTime {
            const tick = std.math.add(u64, self.time_origin.tick, self.wheel.nowTick()) catch {
                return error.Overflow;
            };
            return .init(tick);
        }
    };
}

fn mapWheelError(err: scheduling.timer_wheel.TimerError) TimerQueueError {
    return switch (err) {
        error.InvalidConfig => error.InvalidConfig,
        error.OutOfMemory => error.OutOfMemory,
        error.NoSpaceLeft => error.NoSpaceLeft,
        error.NotFound => error.NotFound,
        error.Overflow => error.Overflow,
    };
}

test "timer queue drains due timers in FIFO due order" {
    var sim_clock = clock.SimClock.init(.init(0));
    var queue = try TimerQueue(u32).init(std.testing.allocator, &sim_clock, .{
        .buckets = 8,
        .timers_max = 8,
    });
    defer queue.deinit(std.testing.allocator);

    _ = try queue.scheduleAfter(10, .init(2));
    _ = try queue.scheduleAfter(20, .init(2));
    _ = try sim_clock.advance(.init(2));

    var out: [4]u32 = [_]u32{0} ** 4;
    const count = try queue.drainDue(&out);
    try std.testing.expectEqual(@as(u32, 2), count);
    try std.testing.expectEqualSlices(u32, &.{ 10, 20 }, out[0..2]);
}

test "timer queue supports long delays across wheel rounds" {
    var sim_clock = clock.SimClock.init(.init(0));
    var queue = try TimerQueue(u32).init(std.testing.allocator, &sim_clock, .{
        .buckets = 4,
        .timers_max = 4,
    });
    defer queue.deinit(std.testing.allocator);

    _ = try queue.scheduleAfter(55, .init(9));
    _ = try sim_clock.advance(.init(8));

    var out: [1]u32 = [_]u32{0};
    try std.testing.expectEqual(@as(u32, 0), try queue.drainDue(&out));

    _ = try sim_clock.advance(.init(1));
    try std.testing.expectEqual(@as(u32, 1), try queue.drainDue(&out));
    try std.testing.expectEqual(@as(u32, 55), out[0]);
}

test "timer queue cancel invalidates stale id and drain no-space does not advance wheel time" {
    var sim_clock = clock.SimClock.init(.init(0));
    var queue = try TimerQueue(u32).init(std.testing.allocator, &sim_clock, .{
        .buckets = 8,
        .timers_max = 8,
    });
    defer queue.deinit(std.testing.allocator);

    const keep_id = try queue.scheduleAfter(1, .init(1));
    const cancel_id = try queue.scheduleAfter(2, .init(1));
    try std.testing.expectEqual(@as(u32, 2), try queue.cancel(cancel_id));
    try std.testing.expectError(error.NotFound, queue.cancel(cancel_id));

    _ = try sim_clock.advance(.init(1));
    var tiny_out: [0]u32 = .{};
    try std.testing.expectError(error.NoSpaceLeft, queue.drainDue(&tiny_out));
    try std.testing.expectEqual(@as(u64, 0), queue.wheel.nowTick());

    var out: [1]u32 = [_]u32{0};
    try std.testing.expectEqual(@as(u32, 1), try queue.drainDue(&out));
    try std.testing.expectEqual(@as(u32, 1), out[0]);
    _ = keep_id;
}
