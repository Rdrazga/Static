const std = @import("std");
const builtin = @import("builtin");
const Mutex = @import("Mutex.zig");
const Futex = @import("Futex.zig");
const Condition = @This();

const os = std.os;
const assert = std.debug.assert;

impl: Impl = .{},

pub fn wait(self: *Condition, mutex: *Mutex) void {
    self.impl.wait(mutex, null) catch |err| switch (err) {
        error.Timeout => unreachable,
    };
}

pub fn timedWait(self: *Condition, mutex: *Mutex, timeout_ns: u64) error{Timeout}!void {
    return self.impl.wait(mutex, timeout_ns);
}

pub fn signal(self: *Condition) void {
    self.impl.wake(.one);
}

pub fn broadcast(self: *Condition) void {
    self.impl.wake(.all);
}

const Impl = Impl: {
    if (builtin.single_threaded) break :Impl SingleThreadedImpl;
    if (builtin.os.tag == .windows) break :Impl WindowsImpl;
    if (builtin.os.tag.isDarwin() or
        builtin.target.os.tag == .linux or
        builtin.target.os.tag == .freebsd or
        builtin.target.os.tag == .openbsd or
        builtin.target.os.tag == .dragonfly or
        builtin.target.cpu.arch.isWasm())
    {
        break :Impl FutexImpl;
    }
    if (std.Thread.use_pthreads) break :Impl PosixImpl;
    break :Impl FutexImpl;
};

const Notify = enum { one, all };

const SingleThreadedImpl = struct {
    fn wait(self: *Impl, mutex: *Mutex, timeout: ?u64) error{Timeout}!void {
        _ = self;
        _ = mutex;
        assert(timeout != null);
        return error.Timeout;
    }

    fn wake(self: *Impl, comptime notify: Notify) void {
        _ = self;
        _ = notify;
    }
};

const WindowsImpl = struct {
    condition: os.windows.CONDITION_VARIABLE = .{},

    fn wait(self: *Impl, mutex: *Mutex, timeout: ?u64) error{Timeout}!void {
        var timeout_overflowed = false;
        var timeout_ms: os.windows.DWORD = std.math.maxInt(os.windows.DWORD);
        if (timeout) |timeout_ns| {
            const ms = (timeout_ns +| (std.time.ns_per_ms / 2)) / std.time.ns_per_ms;
            timeout_ms = std.math.cast(os.windows.DWORD, ms) orelse std.math.maxInt(os.windows.DWORD);
            if (timeout_ms == std.math.maxInt(os.windows.DWORD)) {
                timeout_overflowed = true;
                timeout_ms -= 1;
            }
        }

        if (builtin.mode == .Debug) mutex.impl.locking_thread.store(0, .unordered);
        const rc = SleepConditionVariableSRW(
            &self.condition,
            if (builtin.mode == .Debug) &mutex.impl.impl.srwlock else &mutex.impl.srwlock,
            timeout_ms,
            0,
        );
        if (builtin.mode == .Debug) mutex.impl.locking_thread.store(std.Thread.getCurrentId(), .unordered);
        if (rc == .FALSE and !timeout_overflowed) {
            assert(os.windows.GetLastError() == .TIMEOUT);
            return error.Timeout;
        }
    }

    fn wake(self: *Impl, comptime notify: Notify) void {
        switch (notify) {
            .one => os.windows.ntdll.RtlWakeConditionVariable(&self.condition),
            .all => os.windows.ntdll.RtlWakeAllConditionVariable(&self.condition),
        }
    }
};

extern "kernel32" fn SleepConditionVariableSRW(
    condition: *os.windows.CONDITION_VARIABLE,
    lock: *os.windows.SRWLOCK,
    milliseconds: os.windows.DWORD,
    flags: os.windows.ULONG,
) callconv(.winapi) os.windows.BOOL;

const FutexImpl = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    epoch: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    const one_waiter = 1;
    const waiter_mask = 0xffff;
    const one_signal = 1 << 16;
    const signal_mask = 0xffff << 16;

    fn wait(self: *Impl, mutex: *Mutex, timeout: ?u64) error{Timeout}!void {
        var epoch = self.epoch.load(.acquire);
        var state = self.state.fetchAdd(one_waiter, .monotonic);
        assert(state & waiter_mask != waiter_mask);
        state += one_waiter;

        mutex.unlock();
        defer mutex.lock();

        var futex_deadline = Futex.Deadline.init(timeout);
        while (true) {
            futex_deadline.wait(&self.epoch, epoch) catch |err| switch (err) {
                error.Timeout => {
                    while (true) {
                        while (state & signal_mask != 0) {
                            const new_state = state - one_waiter - one_signal;
                            state = self.state.cmpxchgWeak(state, new_state, .acquire, .monotonic) orelse return;
                        }
                        const new_state = state - one_waiter;
                        state = self.state.cmpxchgWeak(state, new_state, .monotonic, .monotonic) orelse return err;
                    }
                },
            };

            epoch = self.epoch.load(.acquire);
            state = self.state.load(.monotonic);
            while (state & signal_mask != 0) {
                const new_state = state - one_waiter - one_signal;
                state = self.state.cmpxchgWeak(state, new_state, .acquire, .monotonic) orelse return;
            }
        }
    }

    fn wake(self: *Impl, comptime notify: Notify) void {
        var state = self.state.load(.monotonic);
        while (true) {
            const waiters = (state & waiter_mask) / one_waiter;
            const signals = (state & signal_mask) / one_signal;
            const wakeable = waiters - signals;
            if (wakeable == 0) return;

            const to_wake = switch (notify) {
                .one => 1,
                .all => wakeable,
            };
            const new_state = state + (one_signal * to_wake);
            state = self.state.cmpxchgWeak(state, new_state, .release, .monotonic) orelse {
                _ = self.epoch.fetchAdd(1, .release);
                Futex.wake(&self.epoch, to_wake);
                return;
            };
        }
    }
};

const PosixImpl = struct {
    cond: std.c.pthread_cond_t = .{},

    fn wait(self: *Impl, mutex: *Mutex, timeout: ?u64) error{Timeout}!void {
        if (builtin.mode == .Debug) mutex.impl.locking_thread.store(0, .unordered);
        defer if (builtin.mode == .Debug) mutex.impl.locking_thread.store(std.Thread.getCurrentId(), .unordered);

        const mtx = if (builtin.mode == .Debug) &mutex.impl.impl.mutex else &mutex.impl.mutex;
        if (timeout) |t| {
            switch (std.c.pthread_cond_timedwait(&self.cond, mtx, &.{
                .sec = @intCast(@divFloor(t, std.time.ns_per_s)),
                .nsec = @intCast(@mod(t, std.time.ns_per_s)),
            })) {
                .SUCCESS => return,
                .TIMEDOUT => return error.Timeout,
                else => unreachable,
            }
        }
        assert(std.c.pthread_cond_wait(&self.cond, mtx) == .SUCCESS);
    }

    fn wake(self: *Impl, comptime notify: Notify) void {
        assert(switch (notify) {
            .one => std.c.pthread_cond_signal(&self.cond),
            .all => std.c.pthread_cond_broadcast(&self.cond),
        } == .SUCCESS);
    }
};
