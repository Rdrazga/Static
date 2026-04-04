//! `static_memory` package root: bounded allocators and related helpers.

pub const core = @import("static_core");

pub const capacity_report = @import("memory/capacity_report.zig");
pub const growth = @import("memory/growth.zig");
pub const budget = @import("memory/budget.zig");
pub const arena = @import("memory/arena.zig");
pub const stack = @import("memory/stack.zig");
pub const scratch = @import("memory/scratch.zig");
pub const frame_scope = @import("memory/frame_scope.zig");
pub const pool = @import("memory/pool.zig");
pub const slab = @import("memory/slab.zig");
pub const slab_policy = @import("memory/slab_policy.zig");
pub const epoch = @import("memory/epoch.zig");
pub const profile_hooks = @import("memory/profile_hooks.zig");
pub const debug_allocator = @import("memory/debug_allocator.zig");
pub const soft_limit_allocator = @import("memory/soft_limit_allocator.zig");
pub const tls_pool = @import("memory/tls_pool.zig");

test {
    // Ensures the package root and public exports compile.
    _ = core;
    _ = capacity_report;
    _ = growth;
    _ = budget;
    _ = arena;
    _ = stack;
    _ = scratch;
    _ = frame_scope;
    _ = pool;
    _ = slab;
    _ = slab_policy;
    _ = epoch;
    _ = profile_hooks;
    _ = debug_allocator;
    _ = soft_limit_allocator;
    _ = tls_pool;
}
