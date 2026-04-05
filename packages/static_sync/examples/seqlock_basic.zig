//! Demonstrates stale-token retry detection for a sequence lock.
const std = @import("std");
const assert = std.debug.assert;
const sync = @import("static_sync");

pub fn main() !void {
    var seqlock = sync.seqlock.SeqLock{};

    const before = seqlock.readBegin();
    seqlock.writeLock();
    seqlock.writeUnlock();

    assert(seqlock.readRetry(before));

    const after = seqlock.readBegin();
    assert(!seqlock.readRetry(after));
}
