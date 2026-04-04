//! Benchmark exports for configuration, cases, grouping, execution, derived
//! statistics, comparison, process benchmarking, and result export.

/// Benchmark configuration defaults and validation.
pub const config = @import("config.zig");
/// Monotonic timer helpers for in-process benchmarking.
pub const timer = @import("timer.zig");
/// In-process benchmark case definitions and anti-elision helpers.
pub const case = @import("case.zig");
/// Fixed-capacity benchmark case grouping.
pub const group = @import("group.zig");
/// Raw benchmark execution and sample collection.
pub const runner = @import("runner.zig");
/// Derived benchmark statistics.
pub const stats = @import("stats.zig");
/// Persisted benchmark baselines and regression-gating helpers.
pub const baseline = @import("baseline.zig");
/// Bounded benchmark history records and environment metadata sidecars.
pub const history = @import("history_binary.zig");
/// Thin review workflow helpers over text export and optional baseline compare.
pub const workflow = @import("workflow.zig");
/// A/B comparison helpers over derived statistics.
pub const compare = @import("compare.zig");
/// Child-process benchmark execution.
pub const process = @import("process.zig");
/// Text, JSON, CSV, and Markdown export helpers.
pub const exports = @import("export.zig");

test {
    _ = config;
    _ = timer;
    _ = case;
    _ = group;
    _ = runner;
    _ = stats;
    _ = baseline;
    _ = history;
    _ = workflow;
    _ = compare;
    _ = process;
    _ = exports;
}
