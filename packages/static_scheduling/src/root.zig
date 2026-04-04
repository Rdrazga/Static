//! Deterministic scheduling primitives including task graphs, timers, pollers, and executors.

pub const core = @import("static_core");
pub const sync = @import("static_sync");

pub const topo = @import("scheduling/topo.zig");
pub const task_graph = @import("scheduling/task_graph.zig");
pub const parallel_for = @import("scheduling/parallel_for.zig");
pub const timer_wheel = @import("scheduling/timer_wheel.zig");
pub const poller = @import("scheduling/poller.zig");
pub const thread_pool = @import("scheduling/thread_pool.zig");
pub const executor = @import("scheduling/executor.zig");

test {
    _ = core;
    _ = sync;
    _ = topo;
    _ = task_graph;
    _ = parallel_for;
    _ = timer_wheel;
    _ = poller;
    _ = thread_pool;
    _ = executor;
}
