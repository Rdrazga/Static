const std = @import("std");
const testing = @import("static_testing");

pub fn main() !void {
    var retries = try testing.testing.sim.mailbox.Mailbox(
        testing.testing.sim.retry_queue.RetryEnvelope(u32),
    ).init(std.heap.page_allocator, .{ .capacity = 4 });
    defer retries.deinit();

    var storage: [4]testing.testing.sim.retry_queue.PendingRetry(u32) = undefined;
    var queue = try testing.testing.sim.retry_queue.RetryQueue(u32).init(&storage, .{
        .backoff = .init(2),
        .max_attempts = 3,
    });

    const decision = try queue.scheduleNext(.init(0), 0, 9, 77);
    std.debug.assert(decision == .queued);
    std.debug.assert(try queue.emitDueToMailbox(.init(1), &retries, null) == 0);
    std.debug.assert(try queue.emitDueToMailbox(.init(2), &retries, null) == 1);
    const retry = try retries.recv();
    std.debug.assert(retry.attempt == 1);
    std.debug.print("retry queue emitted request=9 attempt=1\n", .{});
}
