comptime {
    _ = @import("bench_baseline_roundtrip.zig");
    _ = @import("model_sim_fixture_roundtrip.zig");
    _ = @import("sim_explore_portfolio.zig");
    _ = @import("sim_explore_pct_bias.zig");
    _ = @import("model_roundtrip.zig");
    _ = @import("replay_roundtrip.zig");
    _ = @import("fuzz_persistence.zig");
    _ = @import("process_bench_smoke.zig");
    _ = @import("process_driver_roundtrip.zig");
    _ = @import("sim_clock_drift_profiles.zig");
    _ = @import("sim_network_link_fault_rules.zig");
    _ = @import("sim_network_link_record_replay.zig");
    _ = @import("sim_schedule_replay.zig");
    _ = @import("sim_storage_durability_faults.zig");
    _ = @import("sim_storage_durability_record_replay.zig");
    _ = @import("sim_storage_retry_flow.zig");
    _ = @import("system_ordered_effect_reassembly.zig");
    _ = @import("system_failure_bundle.zig");
    _ = @import("system_process_driver_flow.zig");
    _ = @import("swarm_sim_runner.zig");
    _ = @import("temporal_failure_bundle.zig");
}
