//! Demonstrates stale-token retry detection for a sequence lock.
const std = @import("std");
const sync = @import("static_sync");

pub fn main() !void {
    var seqlock = sync.seqlock.SeqLock{};

    const before = seqlock.readBegin();
    seqlock.writeLock();
    seqlock.writeUnlock();

    std.debug.assert(seqlock.readRetry(before));

    const after = seqlock.readBegin();
    std.debug.assert(!seqlock.readRetry(after));
}
