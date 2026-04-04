//! Runtime configuration and validation.

const std = @import("std");
const core = @import("static_core");
const operation_ids = @import("operation_ids.zig");

/// Backend selection for runtime initialization.
pub const BackendKind = enum {
    fake,
    threaded,
    windows_iocp,
    linux_io_uring,
    bsd_kqueue,
    platform,
};

/// Shared runtime configuration for all backends.
pub const Config = struct {
    /// Maximum number of concurrent in-flight operations.
    max_in_flight: u32,
    /// Capacity of backend submission queue.
    submission_queue_capacity: u32,
    /// Capacity of backend completion queue.
    completion_queue_capacity: u32,
    /// Maximum number of runtime handles.
    handles_max: u32,
    /// Worker count for the threaded backend.
    threaded_worker_count: u16 = 1,
    /// AcceptEx address-buffer size (Windows).
    iocp_accept_buffer_bytes: u32 = 512,
    /// io_uring SQ entry count (Linux).
    uring_sq_entries: u32 = 256,
    /// Max SQEs submitted per io_uring submit batch.
    uring_submit_batch_max: u32 = 64,
    /// Max CQEs drained per io_uring pump step.
    uring_cq_drain_max: u32 = 64,
    /// Requested backend kind.
    backend_kind: BackendKind = .fake,

    /// Returns a bounded test configuration tuned for deterministic tests.
    pub fn initForTest(max_in_flight: u32) Config {
        const needed_sq: u32 = std.math.add(u32, max_in_flight, 1) catch max_in_flight;
        const seed_sq: u32 = if (needed_sq == 0) 1 else needed_sq;
        const uring_sq_entries = std.math.ceilPowerOfTwo(u32, seed_sq) catch seed_sq;
        std.debug.assert(seed_sq != 0);
        return .{
            .max_in_flight = max_in_flight,
            .submission_queue_capacity = max_in_flight,
            .completion_queue_capacity = max_in_flight,
            .handles_max = max_in_flight,
            .threaded_worker_count = 1,
            .iocp_accept_buffer_bytes = 512,
            .uring_sq_entries = uring_sq_entries,
            .uring_submit_batch_max = if (max_in_flight == 0) 1 else max_in_flight,
            .uring_cq_drain_max = if (max_in_flight == 0) 1 else max_in_flight,
            .backend_kind = .fake,
        };
    }
};

/// Validation failures for runtime configuration.
pub const Error = error{
    InvalidConfig,
    Overflow,
};

comptime {
    core.errors.assertVocabularySubset(Error);
}

/// Validates global configuration invariants before runtime/backend init.
pub fn validate(cfg: Config) Error!void {
    if (cfg.max_in_flight == 0) return error.InvalidConfig;
    if (cfg.max_in_flight > operation_ids.max_external_slots) return error.InvalidConfig;
    if (cfg.submission_queue_capacity == 0) return error.InvalidConfig;
    if (cfg.completion_queue_capacity == 0) return error.InvalidConfig;
    if (cfg.handles_max == 0) return error.InvalidConfig;
    if (cfg.threaded_worker_count == 0 and cfg.backend_kind == .threaded) return error.InvalidConfig;
    if (cfg.iocp_accept_buffer_bytes == 0) return error.InvalidConfig;
    if (cfg.submission_queue_capacity < cfg.max_in_flight) return error.InvalidConfig;
    if (cfg.completion_queue_capacity < cfg.max_in_flight) return error.InvalidConfig;

    if (cfg.backend_kind == .linux_io_uring) {
        if (cfg.uring_sq_entries == 0) return error.InvalidConfig;
        if (!std.math.isPowerOfTwo(cfg.uring_sq_entries)) return error.InvalidConfig;
        if (cfg.uring_sq_entries > std.math.maxInt(u16)) return error.InvalidConfig;
        const needed_sq: u32 = std.math.add(u32, cfg.max_in_flight, 1) catch return error.Overflow;
        if (cfg.uring_sq_entries < needed_sq) return error.InvalidConfig;
        if (cfg.max_in_flight > cfg.uring_sq_entries) return error.InvalidConfig;
        if (cfg.uring_submit_batch_max == 0) return error.InvalidConfig;
        if (cfg.uring_submit_batch_max > cfg.uring_sq_entries) return error.InvalidConfig;
        if (cfg.uring_cq_drain_max == 0) return error.InvalidConfig;
        if (cfg.uring_cq_drain_max > cfg.completion_queue_capacity) return error.InvalidConfig;
    }

    _ = std.math.add(u32, cfg.max_in_flight, cfg.submission_queue_capacity) catch return error.Overflow;
    _ = std.math.add(u32, cfg.max_in_flight, cfg.completion_queue_capacity) catch return error.Overflow;
    _ = std.math.add(u32, cfg.handles_max, cfg.max_in_flight) catch return error.Overflow;
    std.debug.assert(cfg.submission_queue_capacity >= cfg.max_in_flight);
    std.debug.assert(cfg.completion_queue_capacity >= cfg.max_in_flight);
}

test "config validation catches invalid bounds" {
    try validate(.{
        .max_in_flight = 4,
        .submission_queue_capacity = 4,
        .completion_queue_capacity = 4,
        .handles_max = 4,
        .threaded_worker_count = 1,
    });
    try std.testing.expectError(error.InvalidConfig, validate(.{
        .max_in_flight = 0,
        .submission_queue_capacity = 4,
        .completion_queue_capacity = 4,
        .handles_max = 4,
        .threaded_worker_count = 1,
    }));
    try std.testing.expectError(error.InvalidConfig, validate(.{
        .max_in_flight = 4,
        .submission_queue_capacity = 2,
        .completion_queue_capacity = 4,
        .handles_max = 4,
        .threaded_worker_count = 1,
    }));
    try std.testing.expectError(error.InvalidConfig, validate(.{
        .max_in_flight = 4,
        .submission_queue_capacity = 4,
        .completion_queue_capacity = 4,
        .handles_max = 4,
        .threaded_worker_count = 0,
        .backend_kind = .threaded,
    }));
}
