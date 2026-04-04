//! Demonstrates semaphore permit handoff without relying on blocking waits.
const std = @import("std");
const sync = @import("static_sync");

pub fn main() !void {
    var semaphore = sync.semaphore.Semaphore{};
    semaphore.post(1);

    try semaphore.tryWait();
    semaphore.tryWait() catch |err| switch (err) {
        error.WouldBlock => std.debug.print("No permits available.\n", .{}),
    };
}
