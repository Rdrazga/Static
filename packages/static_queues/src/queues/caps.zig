//! Build-time capability helpers for `static_queues`.

const std = @import("std");
const testing = std.testing;
const static_core = @import("static_core");
const sync = @import("static_sync");

const core_build_options = static_core.options.current();

pub const threads_enabled = !core_build_options.single_threaded;
pub const os_backends_enabled = core_build_options.enable_os_backends;
pub const blocking_wait_enabled = sync.condvar.supports_blocking_wait;
pub const wait_queue_enabled = sync.wait_queue.supports_wait_queue;

pub fn shouldSkipThreadedTests() bool {
    return !threads_enabled;
}

test "blocking wait is never true when threads are disabled" {
    if (!threads_enabled) try testing.expect(!blocking_wait_enabled);
}

test "wait queue support implies blocking wait support" {
    if (wait_queue_enabled) try testing.expect(blocking_wait_enabled);
}
