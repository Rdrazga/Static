comptime {
    _ = @import("cancel_reset_fault_runtime.zig");
    _ = @import("fuzz_persistence_sync.zig");
    _ = @import("host_wait_smoke.zig");
    _ = @import("model_barrier_phase_sequences.zig");
    _ = @import("model_cancel_lifecycle_sequences.zig");
    _ = @import("model_event_or_semaphore_sequences.zig");
    _ = @import("model_seqlock_token_sequences.zig");
    _ = @import("model_wait_queue_sequences.zig");
    _ = @import("misuse_paths.zig");
    _ = @import("replay_fuzz_sync_primitives.zig");
    _ = @import("sim_event_protocols.zig");
    _ = @import("sim_semaphore_or_cancel_protocols.zig");
    _ = @import("sim_wait_protocols.zig");
    _ = @import("timeout_fault_runtime.zig");
}
