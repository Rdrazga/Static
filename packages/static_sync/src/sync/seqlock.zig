//! SeqLock: sequence lock for single-writer, multi-reader low-latency reads.
//!
//! Thread safety: one writer at a time (guarded by an internal mutex); concurrent readers detect torn reads via the sequence counter and retry.
//! Single-threaded mode: safe to use; the mutex degrades to a no-op.
const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const mutex = std.Thread;
const padded_atomic = @import("padded_atomic.zig");

pub const SeqLock = struct {
    pub const max_read_spins_default: u32 = 64;

    comptime {
        assert(max_read_spins_default > 0);
    }

    // On its own cache line: read by every reader on every read attempt.
    seq: padded_atomic.PaddedAtomic(u64) = .{ .value = std.atomic.Value(u64).init(0) },
    writer_mutex: mutex.Mutex = .{},
    max_read_spins: u32 = max_read_spins_default,

    pub fn writeLock(self: *SeqLock) void {
        self.writer_mutex.lock();
        const previous_seq = self.seq.fetchAdd(1, .acq_rel);
        assert((previous_seq & 1) == 0);
        assert((self.seq.load(.acquire) & 1) == 1);
    }

    pub fn writeUnlock(self: *SeqLock) void {
        const previous_seq = self.seq.fetchAdd(1, .release);
        assert((previous_seq & 1) == 1);
        assert((self.seq.load(.acquire) & 1) == 0);
        self.writer_mutex.unlock();
    }

    pub fn readBegin(self: *SeqLock) u64 {
        var spin_attempt: u32 = 0;
        while (spin_attempt < self.max_read_spins) : (spin_attempt += 1) {
            const token = self.seq.load(.acquire);
            if ((token & 1) == 0) {
                assert((token & 1) == 0);
                return token;
            }
            std.atomic.spinLoopHint();
        }

        self.writer_mutex.lock();
        defer self.writer_mutex.unlock();
        const token = self.seq.load(.acquire);
        assert((token & 1) == 0);
        return token;
    }

    /// Returns true if the read should be retried. This happens when a write
    /// occurred (or is in progress) since `readBegin` returned `token`.
    pub fn readRetry(self: *SeqLock, token: u64) bool {
        const now = self.seq.load(.acquire);
        const should_retry = (now & 1) == 1 or (token & 1) == 1 or now != token;
        // Assertion 1: a token with odd parity was captured during a write;
        // retrying is mandatory.
        if ((token & 1) == 1) assert(should_retry);
        // Assertion 2: if no retry is needed, the sequence must equal the token
        // and have even parity -- confirming the read window was stable.
        if (!should_retry) assert(now == token and (now & 1) == 0);
        return should_retry;
    }
};

test "seqlock token changes across writes" {
    // Goal: verify readers detect writes between begin and retry.
    // Method: capture token, complete one write cycle, then retry check.
    var l = SeqLock{};
    const before = l.readBegin();
    l.writeLock();
    l.writeUnlock();
    try testing.expect(l.readRetry(before));
}

test "seqlock no retry when no write has occurred" {
    // Goal: verify stable state does not force retries.
    // Method: call `readBegin` and immediately evaluate `readRetry`.
    var l = SeqLock{};
    const token = l.readBegin();
    try testing.expect(!l.readRetry(token));
}

test "seqlock multiple write cycles bump token" {
    // Goal: verify each completed write cycle advances sequence.
    // Method: compare token before and after a write cycle.
    var l = SeqLock{};
    const t0 = l.readBegin();
    l.writeLock();
    l.writeUnlock();
    const t1 = l.readBegin();
    try testing.expect(!l.readRetry(t1));
    try testing.expect(l.readRetry(t0));
}

test "seqlock write lock toggles odd/even parity" {
    // Goal: verify lock/unlock parity invariants on sequence counter.
    // Method: inspect sequence value around write lock boundaries.
    var l = SeqLock{};
    const seq0 = l.seq.load(.acquire);
    try testing.expect((seq0 & 1) == 0);

    l.writeLock();
    const seq1 = l.seq.load(.acquire);
    try testing.expect((seq1 & 1) == 1);

    l.writeUnlock();
    const seq2 = l.seq.load(.acquire);
    try testing.expect((seq2 & 1) == 0);
}

test "seqlock readRetry requires retry for odd token" {
    // Goal: verify defensive handling of malformed odd tokens.
    // Method: pass an odd token directly to `readRetry`.
    var l = SeqLock{};
    try testing.expect(l.readRetry(1));
}

test "seqlock readBegin returns a stable token after writer contention" {
    // Goal: prove the reader fallback path survives a real writer-held critical section.
    // Method: hold the writer lock, start a reader thread, then release and verify the
    // reader observed the stable post-write token.
    var l = SeqLock{};
    l.max_read_spins = 1;
    l.writeLock();
    var wait_timer = try std.time.Timer.start();
    const reader_start_timeout_ns = std.time.ns_per_s;
    const reader_finish_timeout_ns = std.time.ns_per_s;

    const Reader = struct {
        lock: *SeqLock,
        started: *std.atomic.Value(bool),
        finished: *std.atomic.Value(bool),
        token: *std.atomic.Value(u64),

        fn run(self: *@This()) void {
            self.started.store(true, .release);
            const token = self.lock.readBegin();
            self.token.store(token, .release);
            self.finished.store(true, .release);
        }
    };

    var started = std.atomic.Value(bool).init(false);
    var finished = std.atomic.Value(bool).init(false);
    var token = std.atomic.Value(u64).init(0);
    var reader = Reader{
        .lock = &l,
        .started = &started,
        .finished = &finished,
        .token = &token,
    };

    var thread = try std.Thread.spawn(.{}, Reader.run, .{&reader});
    defer thread.join();

    while (!started.load(.acquire)) {
        if (wait_timer.read() > reader_start_timeout_ns) return error.ReaderStartTimeout;
        std.Thread.yield() catch unreachable;
    }

    assert((l.seq.load(.acquire) & 1) == 1);
    l.writeUnlock();
    wait_timer.reset();

    while (!finished.load(.acquire)) {
        if (wait_timer.read() > reader_finish_timeout_ns) return error.ReaderFinishTimeout;
        std.Thread.yield() catch unreachable;
    }

    const observed = token.load(.acquire);
    try testing.expectEqual(@as(u64, 2), observed);
    try testing.expect(!l.readRetry(observed));
}
