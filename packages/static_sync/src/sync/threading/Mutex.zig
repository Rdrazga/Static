const std = @import("std");
const builtin = @import("builtin");
const Futex = @import("Futex.zig");
const Mutex = @This();

const assert = std.debug.assert;
const Thread = std.Thread;

impl: Impl = .{},

pub fn tryLock(self: *Mutex) bool {
    return self.impl.tryLock();
}

pub fn lock(self: *Mutex) void {
    self.impl.lock();
}

pub fn unlock(self: *Mutex) void {
    self.impl.unlock();
}

const Impl = if (builtin.mode == .Debug and !builtin.single_threaded)
    DebugImpl
else
    ReleaseImpl;

const ReleaseImpl = Impl: {
    if (builtin.single_threaded) break :Impl SingleThreadedImpl;
    if (builtin.os.tag == .windows) break :Impl WindowsImpl;
    if (builtin.os.tag.isDarwin()) break :Impl DarwinImpl;
    if (builtin.target.os.tag == .linux or
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

const DebugImpl = struct {
    locking_thread: std.atomic.Value(Thread.Id) = std.atomic.Value(Thread.Id).init(0),
    impl: ReleaseImpl = .{},

    fn tryLock(self: *@This()) bool {
        const locking = self.impl.tryLock();
        if (locking) self.locking_thread.store(Thread.getCurrentId(), .unordered);
        return locking;
    }

    fn lock(self: *@This()) void {
        const current_id = Thread.getCurrentId();
        if (self.locking_thread.load(.unordered) == current_id and current_id != 0) @panic("Deadlock detected");
        self.impl.lock();
        self.locking_thread.store(current_id, .unordered);
    }

    fn unlock(self: *@This()) void {
        assert(self.locking_thread.load(.unordered) == Thread.getCurrentId());
        self.locking_thread.store(0, .unordered);
        self.impl.unlock();
    }
};

const SingleThreadedImpl = struct {
    is_locked: bool = false,

    fn tryLock(self: *@This()) bool {
        if (self.is_locked) return false;
        self.is_locked = true;
        return true;
    }

    fn lock(self: *@This()) void {
        if (!self.tryLock()) unreachable;
    }

    fn unlock(self: *@This()) void {
        assert(self.is_locked);
        self.is_locked = false;
    }
};

const WindowsImpl = struct {
    srwlock: windows.SRWLOCK = .{},

    fn tryLock(self: *@This()) bool {
        return windows.ntdll.RtlTryAcquireSRWLockExclusive(&self.srwlock) != .FALSE;
    }

    fn lock(self: *@This()) void {
        windows.ntdll.RtlAcquireSRWLockExclusive(&self.srwlock);
    }

    fn unlock(self: *@This()) void {
        windows.ntdll.RtlReleaseSRWLockExclusive(&self.srwlock);
    }

    const windows = std.os.windows;
};

const DarwinImpl = struct {
    oul: c.os_unfair_lock = .{},

    fn tryLock(self: *@This()) bool {
        return c.os_unfair_lock_trylock(&self.oul);
    }

    fn lock(self: *@This()) void {
        c.os_unfair_lock_lock(&self.oul);
    }

    fn unlock(self: *@This()) void {
        c.os_unfair_lock_unlock(&self.oul);
    }

    const c = std.c;
};

const FutexImpl = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(unlocked),

    const unlocked: u32 = 0b00;
    const locked: u32 = 0b01;
    const contended: u32 = 0b11;

    fn lock(self: *@This()) void {
        if (!self.tryLock()) self.lockSlow();
    }

    fn tryLock(self: *@This()) bool {
        if (builtin.target.cpu.arch.isX86()) {
            const locked_bit = @ctz(locked);
            return self.state.bitSet(locked_bit, .acquire) == 0;
        }
        return self.state.cmpxchgWeak(unlocked, locked, .acquire, .monotonic) == null;
    }

    fn lockSlow(self: *@This()) void {
        if (self.state.load(.monotonic) == contended) Futex.wait(&self.state, contended);
        while (self.state.swap(contended, .acquire) != unlocked) {
            Futex.wait(&self.state, contended);
        }
    }

    fn unlock(self: *@This()) void {
        const state = self.state.swap(unlocked, .release);
        assert(state != unlocked);
        if (state == contended) Futex.wake(&self.state, 1);
    }
};

const PosixImpl = struct {
    mutex: std.c.pthread_mutex_t = .{},

    fn tryLock(impl: *PosixImpl) bool {
        return switch (std.c.pthread_mutex_trylock(&impl.mutex)) {
            .SUCCESS => true,
            .BUSY => false,
            .INVAL => unreachable,
            else => unreachable,
        };
    }

    fn lock(impl: *PosixImpl) void {
        switch (std.c.pthread_mutex_lock(&impl.mutex)) {
            .SUCCESS => return,
            .INVAL, .DEADLK => unreachable,
            else => unreachable,
        }
    }

    fn unlock(impl: *PosixImpl) void {
        switch (std.c.pthread_mutex_unlock(&impl.mutex)) {
            .SUCCESS => return,
            .INVAL, .PERM => unreachable,
            else => unreachable,
        }
    }
};
