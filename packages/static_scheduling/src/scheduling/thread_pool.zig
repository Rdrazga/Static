//! Bounded worker thread pool.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const sync = @import("static_sync");

pub const ThreadPoolError = error{
    InvalidConfig,
    OutOfMemory,
    NoSpaceLeft,
    WouldBlock,
    Closed,
    Unsupported,
};

pub const Task = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque) void,
};

const supports_thread_pool = sync.condvar.supports_blocking_wait;

pub const ThreadPool = if (supports_thread_pool) struct {
    const Self = @This();

    pub const Config = struct {
        worker_count: u16,
        global_queue_capacity: u32,
        local_queue_capacity: u32 = 0,
    };

    pub const supports_thread_pool = true;

    const State = struct {
        mutex: std.Thread.Mutex = .{},
        not_empty: sync.condvar.Condvar = .{},
        queue: []Task,
        head: usize = 0,
        len: usize = 0,
        waiting_workers: usize = 0,
        closed: bool = false,
    };

    allocator: std.mem.Allocator,
    cfg: Config,
    state: *State,
    joined: bool = false,
    workers: []std.Thread,

    pub fn init(allocator: std.mem.Allocator, cfg: Config) ThreadPoolError!Self {
        if (cfg.worker_count == 0) return error.InvalidConfig;
        if (cfg.global_queue_capacity == 0) return error.InvalidConfig;
        _ = cfg.local_queue_capacity;

        const state = allocator.create(State) catch return error.OutOfMemory;
        errdefer allocator.destroy(state);

        state.* = .{
            .queue = allocator.alloc(Task, cfg.global_queue_capacity) catch return error.OutOfMemory,
        };
        errdefer allocator.free(state.queue);

        const workers = allocator.alloc(std.Thread, cfg.worker_count) catch return error.OutOfMemory;
        errdefer allocator.free(workers);

        const self: Self = .{
            .allocator = allocator,
            .cfg = cfg,
            .state = state,
            .workers = workers,
        };

        var started: usize = 0;
        errdefer {
            state.mutex.lock();
            state.closed = true;
            state.mutex.unlock();
            state.not_empty.broadcast();

            var join_index: usize = 0;
            while (join_index < started) : (join_index += 1) {
                workers[join_index].join();
            }
        }

        while (started < workers.len) : (started += 1) {
            self.workers[started] = std.Thread.spawn(.{}, workerMain, .{state}) catch return error.OutOfMemory;
        }
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.close();
        _ = self.join() catch {};
        self.allocator.free(self.workers);
        self.allocator.free(self.state.queue);
        self.allocator.destroy(self.state);
        self.* = undefined;
    }

    pub fn trySubmit(self: *Self, task: Task) ThreadPoolError!void {
        self.state.mutex.lock();
        defer self.state.mutex.unlock();

        if (self.state.closed) return error.Closed;
        if (self.state.len == self.state.queue.len) return error.WouldBlock;

        const tail = (self.state.head + self.state.len) % self.state.queue.len;
        self.state.queue[tail] = task;
        self.state.len += 1;
        self.state.not_empty.signal();
    }

    pub fn close(self: *Self) void {
        self.state.mutex.lock();
        if (self.state.closed) {
            self.state.mutex.unlock();
            return;
        }
        self.state.closed = true;
        self.state.mutex.unlock();
        self.state.not_empty.broadcast();
    }

    pub fn join(self: *Self) ThreadPoolError!void {
        if (self.joined) return;
        self.close();

        var index: usize = 0;
        while (index < self.workers.len) : (index += 1) {
            self.workers[index].join();
        }
        self.joined = true;
    }

    fn popTaskLocked(state: *State) Task {
        assert(state.len > 0);
        const task = state.queue[state.head];
        state.head = (state.head + 1) % state.queue.len;
        state.len -= 1;
        return task;
    }

    fn workerMain(state: *State) void {
        while (true) {
            state.mutex.lock();
            while (state.len == 0 and !state.closed) {
                state.waiting_workers += 1;
                state.not_empty.wait(&state.mutex);
                assert(state.waiting_workers > 0);
                state.waiting_workers -= 1;
            }

            if (state.len == 0 and state.closed) {
                state.mutex.unlock();
                return;
            }

            const task = popTaskLocked(state);
            state.mutex.unlock();
            task.run(task.ctx);
        }
    }
} else struct {
    const Self = @This();

    pub const Config = struct {
        worker_count: u16,
        global_queue_capacity: u32,
        local_queue_capacity: u32 = 0,
    };

    pub const supports_thread_pool = false;

    pub fn init(allocator: std.mem.Allocator, cfg: Config) ThreadPoolError!Self {
        _ = allocator;
        _ = cfg;
        return error.Unsupported;
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn trySubmit(self: *Self, task: Task) ThreadPoolError!void {
        _ = self;
        _ = task;
        return error.Unsupported;
    }

    pub fn close(self: *Self) void {
        _ = self;
    }

    pub fn join(self: *Self) ThreadPoolError!void {
        _ = self;
        return error.Unsupported;
    }
};

test "thread pool rejects invalid config" {
    if (!ThreadPool.supports_thread_pool) return error.SkipZigTest;

    try testing.expectError(error.InvalidConfig, ThreadPool.init(testing.allocator, .{
        .worker_count = 0,
        .global_queue_capacity = 1,
    }));
    try testing.expectError(error.InvalidConfig, ThreadPool.init(testing.allocator, .{
        .worker_count = 1,
        .global_queue_capacity = 0,
    }));
}

test "thread pool apply backpressure when saturated" {
    if (!ThreadPool.supports_thread_pool) return error.SkipZigTest;

    const Blocker = struct {
        started: *std.atomic.Value(bool),
        release: *std.atomic.Value(bool),

        fn run(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.started.store(true, .release);
            while (!self.release.load(.acquire)) {
                std.Thread.yield() catch {};
            }
        }
    };

    const Noop = struct {
        fn run(_: *anyopaque) void {}
    };

    var started = std.atomic.Value(bool).init(false);
    var release = std.atomic.Value(bool).init(false);
    var noop_ctx: u8 = 0;
    var blocker = Blocker{
        .started = &started,
        .release = &release,
    };

    var pool = try ThreadPool.init(testing.allocator, .{
        .worker_count = 1,
        .global_queue_capacity = 1,
    });
    defer pool.deinit();

    try pool.trySubmit(.{
        .ctx = &blocker,
        .run = Blocker.run,
    });

    while (!started.load(.acquire)) {
        std.Thread.yield() catch {};
    }

    try pool.trySubmit(.{
        .ctx = &noop_ctx,
        .run = Noop.run,
    });

    try testing.expectError(error.WouldBlock, pool.trySubmit(.{
        .ctx = &noop_ctx,
        .run = Noop.run,
    }));

    release.store(true, .release);
    pool.close();
    try pool.join();
}

test "thread pool close is idempotent" {
    if (!ThreadPool.supports_thread_pool) return error.SkipZigTest;

    var pool = try ThreadPool.init(testing.allocator, .{
        .worker_count = 1,
        .global_queue_capacity = 2,
    });
    defer pool.deinit();

    pool.close();
    pool.close();
    try pool.join();
}

test "thread pool trySubmit returns Closed after close" {
    if (!ThreadPool.supports_thread_pool) return error.SkipZigTest;

    const Noop = struct {
        fn run(_: *anyopaque) void {}
    };

    var ctx: u8 = 0;
    var pool = try ThreadPool.init(testing.allocator, .{
        .worker_count = 1,
        .global_queue_capacity = 1,
    });
    defer pool.deinit();

    pool.close();
    try testing.expectError(error.Closed, pool.trySubmit(.{
        .ctx = &ctx,
        .run = Noop.run,
    }));
}

test "thread pool close wakes idle workers so join completes after work drains" {
    if (!ThreadPool.supports_thread_pool) return error.SkipZigTest;

    const Marker = struct {
        finished: *std.atomic.Value(bool),

        fn run(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.finished.store(true, .release);
        }
    };

    var finished = std.atomic.Value(bool).init(false);
    var marker = Marker{ .finished = &finished };
    var pool = try ThreadPool.init(testing.allocator, .{
        .worker_count = 1,
        .global_queue_capacity = 1,
    });
    defer pool.deinit();

    try pool.trySubmit(.{
        .ctx = &marker,
        .run = Marker.run,
    });

    while (!finished.load(.acquire)) {
        std.Thread.yield() catch {};
    }

    try waitForIdleWorker(&pool, 100 * std.time.ns_per_ms);
    pool.close();
    try pool.join();

    const Noop = struct {
        fn run(_: *anyopaque) void {}
    };
    var noop_ctx: u8 = 0;
    try testing.expectError(error.Closed, pool.trySubmit(.{
        .ctx = &noop_ctx,
        .run = Noop.run,
    }));
}

test "thread pool trySubmit wakes an idle blocked worker without close" {
    if (!ThreadPool.supports_thread_pool) return error.SkipZigTest;

    const Marker = struct {
        finished: *std.atomic.Value(bool),

        fn run(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.finished.store(true, .release);
        }
    };

    var finished = std.atomic.Value(bool).init(false);
    var marker = Marker{ .finished = &finished };
    var pool = try ThreadPool.init(testing.allocator, .{
        .worker_count = 1,
        .global_queue_capacity = 1,
    });
    defer pool.deinit();

    try waitForIdleWorker(&pool, 100 * std.time.ns_per_ms);

    pool.state.mutex.lock();
    const idle_waiting = pool.state.len == 0 and pool.state.waiting_workers > 0 and !pool.state.closed;
    pool.state.mutex.unlock();
    try testing.expect(idle_waiting);

    try pool.trySubmit(.{
        .ctx = &marker,
        .run = Marker.run,
    });

    while (!finished.load(.acquire)) {
        std.Thread.yield() catch {};
    }

    pool.state.mutex.lock();
    const queue_drained = pool.state.len == 0 and !pool.state.closed;
    pool.state.mutex.unlock();
    try testing.expect(queue_drained);
    try testing.expect(finished.load(.acquire));
}

test "thread pool close wakes all idle workers in multi-worker pool" {
    if (!ThreadPool.supports_thread_pool) return error.SkipZigTest;

    var pool = try ThreadPool.init(testing.allocator, .{
        .worker_count = 3,
        .global_queue_capacity = 1,
    });
    defer pool.deinit();

    try waitForIdleWorkers(&pool, 3, 100 * std.time.ns_per_ms);
    pool.close();
    try pool.join();

    try testing.expect(pool.joined);
}

test "thread pool trySubmit wakes multiple idle workers for a burst" {
    if (!ThreadPool.supports_thread_pool) return error.SkipZigTest;

    const Blocker = struct {
        started_count: *std.atomic.Value(u32),
        release: *std.atomic.Value(bool),

        fn run(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = self.started_count.fetchAdd(1, .acq_rel);
            while (!self.release.load(.acquire)) {
                std.Thread.yield() catch {};
            }
        }
    };

    var started_count = std.atomic.Value(u32).init(0);
    var release = std.atomic.Value(bool).init(false);
    var blocker = Blocker{
        .started_count = &started_count,
        .release = &release,
    };
    var pool = try ThreadPool.init(testing.allocator, .{
        .worker_count = 3,
        .global_queue_capacity = 3,
    });
    defer pool.deinit();
    defer release.store(true, .release);

    try waitForIdleWorkers(&pool, 3, 100 * std.time.ns_per_ms);

    try pool.trySubmit(.{
        .ctx = &blocker,
        .run = Blocker.run,
    });
    try pool.trySubmit(.{
        .ctx = &blocker,
        .run = Blocker.run,
    });
    try pool.trySubmit(.{
        .ctx = &blocker,
        .run = Blocker.run,
    });

    try waitForCounterAtLeast(&started_count, 2, 100 * std.time.ns_per_ms);

    pool.state.mutex.lock();
    const woke_multiple_workers = pool.state.waiting_workers <= 1 and !pool.state.closed;
    pool.state.mutex.unlock();
    try testing.expect(woke_multiple_workers);
    try testing.expect(started_count.load(.acquire) >= 2);
}

test "thread pool close drains queued work submitted before shutdown" {
    if (!ThreadPool.supports_thread_pool) return error.SkipZigTest;

    const Blocker = struct {
        started_count: *std.atomic.Value(u32),
        completed_count: *std.atomic.Value(u32),
        release: *std.atomic.Value(bool),

        fn run(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = self.started_count.fetchAdd(1, .acq_rel);
            while (!self.release.load(.acquire)) {
                std.Thread.yield() catch {};
            }
            _ = self.completed_count.fetchAdd(1, .acq_rel);
        }
    };

    var started_count = std.atomic.Value(u32).init(0);
    var completed_count = std.atomic.Value(u32).init(0);
    var release = std.atomic.Value(bool).init(false);
    var blocker = Blocker{
        .started_count = &started_count,
        .completed_count = &completed_count,
        .release = &release,
    };
    var pool = try ThreadPool.init(testing.allocator, .{
        .worker_count = 2,
        .global_queue_capacity = 3,
    });
    defer pool.deinit();

    try waitForIdleWorkers(&pool, 2, 100 * std.time.ns_per_ms);

    try pool.trySubmit(.{
        .ctx = &blocker,
        .run = Blocker.run,
    });
    try pool.trySubmit(.{
        .ctx = &blocker,
        .run = Blocker.run,
    });
    try pool.trySubmit(.{
        .ctx = &blocker,
        .run = Blocker.run,
    });

    try waitForCounterAtLeast(&started_count, 2, 100 * std.time.ns_per_ms);

    pool.state.mutex.lock();
    const has_queued_work = pool.state.len == 1 and !pool.state.closed;
    pool.state.mutex.unlock();
    try testing.expect(has_queued_work);

    pool.close();
    release.store(true, .release);
    try pool.join();

    try testing.expect(pool.joined);
    try testing.expectEqual(@as(u32, 3), started_count.load(.acquire));
    try testing.expectEqual(@as(u32, 3), completed_count.load(.acquire));
}

test "thread pool backpressure clears after worker progress" {
    if (!ThreadPool.supports_thread_pool) return error.SkipZigTest;

    const Blocker = struct {
        started: *std.atomic.Value(bool),
        release: *std.atomic.Value(bool),
        completed: *std.atomic.Value(bool),

        fn run(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.started.store(true, .release);
            while (!self.release.load(.acquire)) {
                std.Thread.yield() catch {};
            }
            self.completed.store(true, .release);
        }
    };

    const Marker = struct {
        finished: *std.atomic.Value(bool),

        fn run(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.finished.store(true, .release);
        }
    };

    var blocker_started = std.atomic.Value(bool).init(false);
    var blocker_release = std.atomic.Value(bool).init(false);
    var blocker_completed = std.atomic.Value(bool).init(false);
    var marker_finished = std.atomic.Value(bool).init(false);
    var blocker = Blocker{
        .started = &blocker_started,
        .release = &blocker_release,
        .completed = &blocker_completed,
    };
    var marker = Marker{ .finished = &marker_finished };
    var pool = try ThreadPool.init(testing.allocator, .{
        .worker_count = 1,
        .global_queue_capacity = 1,
    });
    defer pool.deinit();

    try pool.trySubmit(.{
        .ctx = &blocker,
        .run = Blocker.run,
    });

    while (!blocker_started.load(.acquire)) {
        std.Thread.yield() catch {};
    }

    try pool.trySubmit(.{
        .ctx = &marker,
        .run = Marker.run,
    });
    try testing.expectError(error.WouldBlock, pool.trySubmit(.{
        .ctx = &marker,
        .run = Marker.run,
    }));

    blocker_release.store(true, .release);
    while (!blocker_completed.load(.acquire)) {
        std.Thread.yield() catch {};
    }
    while (!marker_finished.load(.acquire)) {
        std.Thread.yield() catch {};
    }

    try waitForIdleWorker(&pool, 100 * std.time.ns_per_ms);
    marker_finished.store(false, .release);
    try pool.trySubmit(.{
        .ctx = &marker,
        .run = Marker.run,
    });
    while (!marker_finished.load(.acquire)) {
        std.Thread.yield() catch {};
    }
    try testing.expect(marker_finished.load(.acquire));
}

test "thread pool multi-worker backpressure clears after worker progress" {
    if (!ThreadPool.supports_thread_pool) return error.SkipZigTest;

    const Blocker = struct {
        started_count: *std.atomic.Value(u32),
        completed_count: *std.atomic.Value(u32),
        release: *std.atomic.Value(bool),

        fn run(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = self.started_count.fetchAdd(1, .acq_rel);
            while (!self.release.load(.acquire)) {
                std.Thread.yield() catch {};
            }
            _ = self.completed_count.fetchAdd(1, .acq_rel);
        }
    };

    const Marker = struct {
        finished_count: *std.atomic.Value(u32),

        fn run(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = self.finished_count.fetchAdd(1, .acq_rel);
        }
    };

    var blocker_started = std.atomic.Value(u32).init(0);
    var blocker_completed = std.atomic.Value(u32).init(0);
    var blocker_release = std.atomic.Value(bool).init(false);
    var marker_finished = std.atomic.Value(u32).init(0);
    var blocker = Blocker{
        .started_count = &blocker_started,
        .completed_count = &blocker_completed,
        .release = &blocker_release,
    };
    var marker = Marker{ .finished_count = &marker_finished };
    var pool = try ThreadPool.init(testing.allocator, .{
        .worker_count = 2,
        .global_queue_capacity = 2,
    });
    defer pool.deinit();

    try pool.trySubmit(.{
        .ctx = &blocker,
        .run = Blocker.run,
    });
    try pool.trySubmit(.{
        .ctx = &blocker,
        .run = Blocker.run,
    });
    try pool.trySubmit(.{
        .ctx = &marker,
        .run = Marker.run,
    });
    try pool.trySubmit(.{
        .ctx = &marker,
        .run = Marker.run,
    });

    try waitForCounterAtLeast(&blocker_started, 2, 100 * std.time.ns_per_ms);
    try testing.expectError(error.WouldBlock, pool.trySubmit(.{
        .ctx = &marker,
        .run = Marker.run,
    }));

    blocker_release.store(true, .release);
    try waitForCounterAtLeast(&blocker_completed, 2, 100 * std.time.ns_per_ms);
    try waitForCounterAtLeast(&marker_finished, 2, 100 * std.time.ns_per_ms);
    try waitForIdleWorkers(&pool, 2, 100 * std.time.ns_per_ms);

    try pool.trySubmit(.{
        .ctx = &marker,
        .run = Marker.run,
    });
    try waitForCounterAtLeast(&marker_finished, 3, 100 * std.time.ns_per_ms);
}

test "thread pool wakes multiple workers for queued follow-up work after prior progress" {
    if (!ThreadPool.supports_thread_pool) return error.SkipZigTest;

    const Blocker = struct {
        started_count: *std.atomic.Value(u32),
        completed_count: *std.atomic.Value(u32),
        release: *std.atomic.Value(bool),

        fn run(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = self.started_count.fetchAdd(1, .acq_rel);
            while (!self.release.load(.acquire)) {
                std.Thread.yield() catch {};
            }
            _ = self.completed_count.fetchAdd(1, .acq_rel);
        }
    };

    const Marker = struct {
        finished_count: *std.atomic.Value(u32),

        fn run(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = self.finished_count.fetchAdd(1, .acq_rel);
        }
    };

    var blocker_started = std.atomic.Value(u32).init(0);
    var blocker_completed = std.atomic.Value(u32).init(0);
    var blocker_release = std.atomic.Value(bool).init(false);
    var marker_finished = std.atomic.Value(u32).init(0);
    var blocker = Blocker{
        .started_count = &blocker_started,
        .completed_count = &blocker_completed,
        .release = &blocker_release,
    };
    var marker = Marker{ .finished_count = &marker_finished };
    var pool = try ThreadPool.init(testing.allocator, .{
        .worker_count = 2,
        .global_queue_capacity = 3,
    });
    defer pool.deinit();

    try waitForIdleWorkers(&pool, 2, 100 * std.time.ns_per_ms);

    try pool.trySubmit(.{
        .ctx = &blocker,
        .run = Blocker.run,
    });
    try pool.trySubmit(.{
        .ctx = &blocker,
        .run = Blocker.run,
    });
    try waitForCounterAtLeast(&blocker_started, 2, 100 * std.time.ns_per_ms);

    blocker_release.store(true, .release);
    try waitForCounterAtLeast(&blocker_completed, 2, 100 * std.time.ns_per_ms);
    try waitForIdleWorkers(&pool, 2, 100 * std.time.ns_per_ms);

    blocker_release.store(false, .release);
    try pool.trySubmit(.{
        .ctx = &blocker,
        .run = Blocker.run,
    });
    try pool.trySubmit(.{
        .ctx = &blocker,
        .run = Blocker.run,
    });
    try pool.trySubmit(.{
        .ctx = &marker,
        .run = Marker.run,
    });

    try waitForCounterAtLeast(&blocker_started, 4, 100 * std.time.ns_per_ms);

    pool.state.mutex.lock();
    const queued_follow_up_woke_multiple_workers = pool.state.waiting_workers == 0 and pool.state.len == 1 and !pool.state.closed;
    pool.state.mutex.unlock();
    try testing.expect(queued_follow_up_woke_multiple_workers);

    blocker_release.store(true, .release);
    try waitForCounterAtLeast(&blocker_completed, 4, 100 * std.time.ns_per_ms);
    try waitForCounterAtLeast(&marker_finished, 1, 100 * std.time.ns_per_ms);
}

fn waitForIdleWorker(pool: *ThreadPool, timeout_ns: u64) !void {
    return waitForIdleWorkers(pool, 1, timeout_ns);
}

fn waitForIdleWorkers(pool: *ThreadPool, waiting_count_min: usize, timeout_ns: u64) !void {
    const start = std.time.Instant.now() catch return error.SkipZigTest;
    while (true) {
        pool.state.mutex.lock();
        const is_idle_waiting = pool.state.len == 0 and pool.state.waiting_workers >= waiting_count_min and !pool.state.closed;
        pool.state.mutex.unlock();
        if (is_idle_waiting) return;

        const elapsed = (std.time.Instant.now() catch return error.SkipZigTest).since(start);
        if (elapsed >= timeout_ns) return error.Timeout;
        std.Thread.yield() catch {};
    }
}

fn waitForCounterAtLeast(counter: *const std.atomic.Value(u32), target: u32, timeout_ns: u64) !void {
    const start = std.time.Instant.now() catch return error.SkipZigTest;
    while (true) {
        if (counter.load(.acquire) >= target) return;

        const elapsed = (std.time.Instant.now() catch return error.SkipZigTest).since(start);
        if (elapsed >= timeout_ns) return error.Timeout;
        std.Thread.yield() catch {};
    }
}
