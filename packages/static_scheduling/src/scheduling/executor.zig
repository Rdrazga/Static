//! Bounded job executor with optional worker pool.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const collections = @import("static_collections");
const core = @import("static_core");
const sync = @import("static_sync");
const thread_pool = @import("thread_pool.zig");

pub const JobId = collections.handle.Handle;
const supports_completion_wait = sync.condvar.supports_blocking_wait;

pub const ExecutorError = error{
    InvalidConfig,
    OutOfMemory,
    NoSpaceLeft,
    WouldBlock,
    Closed,
    Cancelled,
    Timeout,
    NotFound,
    Unsupported,
};

pub const Job = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque) void,
};

pub const Executor = struct {
    pub const Config = struct {
        jobs_max: u32,
        worker_count: u16 = 0,
        queue_capacity: u32,
    };

    const SlotState = enum {
        free,
        running,
        completed,
    };

    const Slot = struct {
        state: SlotState = .free,
    };

    const TaskContext = struct {
        executor: *Executor,
        slot_index: u32,
        generation: u32,
        job: Job,
    };

    allocator: std.mem.Allocator,
    cfg: Config,

    mutex: sync.threading.Mutex = .{},
    completion_cond: if (supports_completion_wait) sync.condvar.Condvar else void = if (supports_completion_wait) .{} else {},

    slots: []Slot,
    contexts: []TaskContext,
    job_pool: collections.index_pool.IndexPool,
    closed: bool = false,
    pool: ?thread_pool.ThreadPool = null,

    pub fn init(allocator: std.mem.Allocator, cfg: Config) ExecutorError!Executor {
        if (cfg.jobs_max == 0) return error.InvalidConfig;
        if (cfg.worker_count > 0 and cfg.queue_capacity == 0) return error.InvalidConfig;

        const slots = allocator.alloc(Slot, cfg.jobs_max) catch return error.OutOfMemory;
        errdefer allocator.free(slots);
        @memset(slots, .{});

        const contexts = allocator.alloc(TaskContext, cfg.jobs_max) catch return error.OutOfMemory;
        errdefer allocator.free(contexts);

        const job_pool = collections.index_pool.IndexPool.init(allocator, .{ .slots_max = cfg.jobs_max, .budget = null }) catch |err| switch (err) {
            error.InvalidConfig => return error.InvalidConfig,
            error.OutOfMemory => return error.OutOfMemory,
            error.NoSpaceLeft => unreachable,
            error.NotFound => unreachable,
            error.Overflow => unreachable,
        };
        errdefer {
            var owned_pool = job_pool;
            owned_pool.deinit();
        }

        var self: Executor = .{
            .allocator = allocator,
            .cfg = cfg,
            .slots = slots,
            .contexts = contexts,
            .job_pool = job_pool,
        };

        if (cfg.worker_count > 0) {
            self.pool = thread_pool.ThreadPool.init(allocator, .{
                .worker_count = cfg.worker_count,
                .global_queue_capacity = cfg.queue_capacity,
                .local_queue_capacity = cfg.queue_capacity,
            }) catch |err| switch (err) {
                error.InvalidConfig => return error.InvalidConfig,
                error.OutOfMemory => return error.OutOfMemory,
                error.NoSpaceLeft => return error.NoSpaceLeft,
                error.WouldBlock => return error.WouldBlock,
                error.Closed => return error.Closed,
                error.Unsupported => return error.Unsupported,
            };
        }

        return self;
    }

    pub fn deinit(self: *Executor) void {
        self.close();
        if (self.pool) |*pool| {
            _ = pool.join() catch {};
            pool.deinit();
        }
        self.job_pool.deinit();
        self.allocator.free(self.contexts);
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    pub fn trySpawn(self: *Executor, job: Job) ExecutorError!JobId {
        self.mutex.lock();
        if (self.closed) {
            self.mutex.unlock();
            return error.Closed;
        }

        const id = self.job_pool.allocate() catch |err| switch (err) {
            error.NoSpaceLeft => {
                self.mutex.unlock();
                return error.NoSpaceLeft;
            },
            error.InvalidConfig, error.OutOfMemory, error.NotFound, error.Overflow => unreachable,
        };
        const slot_index = id.index;
        assert(slot_index < self.slots.len);
        var slot = &self.slots[slot_index];
        assert(slot.state == .free);
        slot.state = .running;

        if (self.pool) |*pool| {
            self.contexts[slot_index] = .{
                .executor = self,
                .slot_index = slot_index,
                .generation = id.generation,
                .job = job,
            };
            self.mutex.unlock();

            pool.trySubmit(.{
                .ctx = &self.contexts[slot_index],
                .run = runJobTask,
            }) catch |err| {
                self.mutex.lock();
                self.releaseSlotLocked(id);
                self.mutex.unlock();
                return mapPoolError(err);
            };
            return id;
        }

        self.mutex.unlock();
        job.run(job.ctx);
        self.markCompleted(slot_index, id.generation);
        return id;
    }

    pub fn tryJoin(self: *Executor, id: JobId) ExecutorError!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const slot_index = self.validateJobLocked(id) catch return error.NotFound;
        const slot = self.slots[slot_index];
        if (slot.state == .running) return error.WouldBlock;
        if (slot.state != .completed) return error.NotFound;
        self.releaseSlotLocked(id);
    }

    pub fn join(
        self: *Executor,
        id: JobId,
        cancel: ?sync.cancel.CancelToken,
        timeout_ns: ?u64,
    ) ExecutorError!void {
        var timeout_budget = if (timeout_ns) |timeout|
            core.time_budget.TimeoutBudget.init(timeout) catch |err| switch (err) {
                error.Timeout => return error.Timeout,
                error.Unsupported => return error.Unsupported,
            }
        else
            null;

        self.mutex.lock();
        defer self.mutex.unlock();

        while (true) {
            const slot_index = self.validateJobLocked(id) catch return error.NotFound;
            const state = self.slots[slot_index].state;
            if (state == .completed) {
                self.releaseSlotLocked(id);
                return;
            }
            if (state != .running) return error.NotFound;

            if (cancel) |token| token.throwIfCancelled() catch return error.Cancelled;

            var remaining_ns: ?u64 = null;
            if (timeout_budget) |*budget| {
                remaining_ns = budget.remainingOrTimeout() catch |err| switch (err) {
                    error.Timeout => return error.Timeout,
                    error.Unsupported => return error.Unsupported,
                };
                assert(remaining_ns.? > 0);
            }

            if (supports_completion_wait) {
                if (remaining_ns) |remaining| {
                    self.completion_cond.timedWait(&self.mutex, remaining) catch |err| switch (err) {
                        error.Timeout => return error.Timeout,
                    };
                } else {
                    self.completion_cond.wait(&self.mutex);
                }
            } else {
                self.mutex.unlock();
                std.Thread.yield() catch {};
                self.mutex.lock();
            }
        }
    }

    pub fn close(self: *Executor) void {
        self.mutex.lock();
        if (self.closed) {
            self.mutex.unlock();
            return;
        }
        self.closed = true;
        self.mutex.unlock();

        if (self.pool) |*pool| pool.close();
    }

    fn releaseSlotLocked(self: *Executor, id: JobId) void {
        const slot_index = self.job_pool.validate(id) catch unreachable;
        var slot = &self.slots[slot_index];
        slot.state = .free;
        self.job_pool.release(id) catch unreachable;
    }

    fn validateJobLocked(self: *Executor, id: JobId) error{NotFound}!u32 {
        const slot_index = self.job_pool.validate(id) catch return error.NotFound;
        if (slot_index >= self.slots.len) return error.NotFound;
        if (self.slots[slot_index].state == .free) return error.NotFound;
        return slot_index;
    }

    fn markCompleted(self: *Executor, slot_index: u32, generation: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const id: JobId = .{ .index = slot_index, .generation = generation };
        if (!self.job_pool.contains(id)) return;
        if (slot_index >= self.slots.len) return;
        var slot = &self.slots[slot_index];
        if (slot.state != .running) return;

        slot.state = .completed;
        if (supports_completion_wait) self.completion_cond.broadcast();
    }

    fn runJobTask(ctx: *anyopaque) void {
        const task_ctx: *TaskContext = @ptrCast(@alignCast(ctx));
        task_ctx.job.run(task_ctx.job.ctx);
        task_ctx.executor.markCompleted(task_ctx.slot_index, task_ctx.generation);
    }
};

fn mapPoolError(err: thread_pool.ThreadPoolError) ExecutorError {
    return switch (err) {
        error.InvalidConfig => error.InvalidConfig,
        error.OutOfMemory => error.OutOfMemory,
        error.NoSpaceLeft => error.NoSpaceLeft,
        error.WouldBlock => error.WouldBlock,
        error.Closed => error.Closed,
        error.Unsupported => error.Unsupported,
    };
}

test "executor sequential mode is deterministic and stale ids are rejected" {
    const State = struct {
        order: [3]u8 = [_]u8{0} ** 3,
        len: u8 = 0,
    };

    const JobCtx = struct {
        state: *State,
        value: u8,

        fn run(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.state.order[self.state.len] = self.value;
            self.state.len += 1;
        }
    };

    var state = State{};
    var a = JobCtx{ .state = &state, .value = 1 };
    var b = JobCtx{ .state = &state, .value = 2 };
    var c = JobCtx{ .state = &state, .value = 3 };

    var executor = try Executor.init(testing.allocator, .{
        .jobs_max = 3,
        .worker_count = 0,
        .queue_capacity = 0,
    });
    defer executor.deinit();

    const id_a = try executor.trySpawn(.{ .ctx = &a, .run = JobCtx.run });
    const id_b = try executor.trySpawn(.{ .ctx = &b, .run = JobCtx.run });
    const id_c = try executor.trySpawn(.{ .ctx = &c, .run = JobCtx.run });

    try executor.tryJoin(id_a);
    try executor.tryJoin(id_b);
    try executor.tryJoin(id_c);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, state.order[0..3]);
    try testing.expectError(error.NotFound, executor.tryJoin(id_a));
}

test "executor join cancellation and timeout are explicit" {
    if (!thread_pool.ThreadPool.supports_thread_pool) return error.SkipZigTest;

    const Blocker = struct {
        release: *std.atomic.Value(bool),

        fn run(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            while (!self.release.load(.acquire)) {
                std.Thread.yield() catch {};
            }
        }
    };

    var release = std.atomic.Value(bool).init(false);
    var blocker = Blocker{ .release = &release };

    var executor = try Executor.init(testing.allocator, .{
        .jobs_max = 2,
        .worker_count = 1,
        .queue_capacity = 1,
    });
    defer executor.deinit();

    const id = try executor.trySpawn(.{ .ctx = &blocker, .run = Blocker.run });

    var source = sync.cancel.CancelSource{};
    source.cancel();
    try testing.expectError(error.Cancelled, executor.join(id, source.token(), std.time.ns_per_ms));
    try testing.expectError(error.Timeout, executor.join(id, null, 0));

    release.store(true, .release);
    try executor.join(id, null, 50 * std.time.ns_per_ms);
}

test "executor close prevents new spawns" {
    var executor = try Executor.init(testing.allocator, .{
        .jobs_max = 1,
        .worker_count = 0,
        .queue_capacity = 0,
    });
    defer executor.deinit();

    var dummy: u8 = 0;
    executor.close();
    try testing.expectError(error.Closed, executor.trySpawn(.{
        .ctx = &dummy,
        .run = struct {
            fn run(_: *anyopaque) void {}
        }.run,
    }));
}
