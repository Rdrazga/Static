const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const static_core = @import("static_core");
const static_testing = @import("static_testing");

pub const bench = static_testing.bench;

const max_environment_tag_count: usize = 4;

pub const fast_path_benchmark_config: bench.config.BenchmarkConfig = .{
    .mode = .full,
    .warmup_iterations = 16,
    .measure_iterations = 8192,
    .sample_count = 8,
};

pub const contention_benchmark_config: bench.config.BenchmarkConfig = .{
    .mode = .full,
    .warmup_iterations = 4,
    .measure_iterations = 64,
    .sample_count = 6,
};

pub const timeout_path_benchmark_config: bench.config.BenchmarkConfig = .{
    .mode = .full,
    .warmup_iterations = 8,
    .measure_iterations = 2048,
    .sample_count = 8,
};

pub const fast_path_compare_config: bench.baseline.BaselineCompareConfig = .{
    .thresholds = .{
        .median_ratio_ppm = 250_000,
        .p95_ratio_ppm = 350_000,
    },
};

pub const contention_compare_config: bench.baseline.BaselineCompareConfig = .{
    .thresholds = .{
        .median_ratio_ppm = 350_000,
        .p95_ratio_ppm = 500_000,
    },
    .case_overrides = &[_]bench.baseline.BaselineCaseOverride{
        .{
            .case_name = "thread_spawn_join_noop",
            .thresholds = .{
                .median_ratio_ppm = 500_000,
                .p95_ratio_ppm = 750_000,
            },
        },
    },
};

pub const default_environment_note =
    std.fmt.comptimePrint("os={s},arch={s}", .{
        @tagName(builtin.os.tag),
        @tagName(builtin.cpu.arch),
    });

pub const fast_path_environment_tags = &[_][]const u8{
    "same_process",
    "uncontended",
};

pub const contention_environment_tags_polling_fallback = &[_][]const u8{
    "host_threads",
    "polling_fallback",
};

pub const contention_environment_tags_parking = &[_][]const u8{
    "host_threads",
    "parking_wait",
};

pub const contention_environment_tags_with_wait_queue = &[_][]const u8{
    "host_threads",
    "parking_wait",
    "wait_queue",
};

pub const contention_wait_slice_ns: u64 = 5 * std.time.ns_per_ms;
pub const contention_watchdog_timeout_ns: u64 = 2 * std.time.ns_per_s;
pub const contention_watchdog_poll_stride: u32 = 32;

pub const ReportMetadata = struct {
    environment_note: []const u8 = default_environment_note,
    environment_tags: []const []const u8 = &.{},
};

/// Bounded stall detector for contention benchmarks.
///
/// Usage contract:
/// - start the watchdog before `bench.runner.runCase(...)`;
/// - call `beginRun(...)` from the case `prepare_fn` so each warmup and sample
///   resets the watchdog outside the timed callback;
/// - inside the timed callback, use `setStage(...)` before blocking waits and
///   `noteProgress(...)` after each successful handoff or phase advance; and
/// - call `assertHealthy()` after cleanup so a stalled run fails the benchmark
///   instead of leaving later samples to continue after a deadlock.
pub const ContentionWatchdog = struct {
    case_name: []const u8,
    stage_names: []const []const u8,
    timeout_ns: u64 = contention_watchdog_timeout_ns,
    stage_index: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    heartbeat: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    timed_out: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    pub fn init(case_name: []const u8, stage_names: []const []const u8) ContentionWatchdog {
        assert(case_name.len > 0);
        assert(stage_names.len > 0);
        return .{
            .case_name = case_name,
            .stage_names = stage_names,
        };
    }

    pub fn start(self: *ContentionWatchdog) !void {
        assert(self.thread == null);
        self.stage_index.store(0, .release);
        self.heartbeat.store(0, .release);
        self.timed_out.store(false, .release);
        self.stop_requested.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn stop(self: *ContentionWatchdog) void {
        if (self.thread) |thread| {
            self.stop_requested.store(true, .release);
            _ = self.heartbeat.fetchAdd(1, .acq_rel);
            thread.join();
            self.thread = null;
        }
    }

    pub fn beginRun(self: *ContentionWatchdog, stage_index: u8) void {
        self.assertHealthy();
        self.noteProgress(stage_index);
    }

    pub fn setStage(self: *ContentionWatchdog, stage_index: u8) void {
        assert(stage_index < self.stage_names.len);
        self.stage_index.store(stage_index, .release);
    }

    pub fn noteProgress(self: *ContentionWatchdog, stage_index: u8) void {
        self.setStage(stage_index);
        _ = self.heartbeat.fetchAdd(1, .acq_rel);
    }

    pub fn didTimeout(self: *const ContentionWatchdog) bool {
        return self.timed_out.load(.acquire);
    }

    pub fn assertHealthy(self: *const ContentionWatchdog) void {
        if (self.didTimeout()) {
            std.debug.panic("static_sync benchmark watchdog fired for {s}", .{self.case_name});
        }
    }

    fn run(self: *ContentionWatchdog) void {
        var last_heartbeat = self.heartbeat.load(.acquire);
        var last_progress = static_core.time_compat.Instant.now() catch {
            self.fireClockFailure();
            return;
        };
        var poll_countdown: u32 = contention_watchdog_poll_stride;

        while (!self.stop_requested.load(.acquire)) {
            const heartbeat_now = self.heartbeat.load(.acquire);
            if (heartbeat_now != last_heartbeat) {
                last_heartbeat = heartbeat_now;
                last_progress = static_core.time_compat.Instant.now() catch {
                    self.fireClockFailure();
                    return;
                };
                poll_countdown = contention_watchdog_poll_stride;
            } else if (poll_countdown > 1) {
                poll_countdown -= 1;
                std.Thread.yield() catch {};
                continue;
            }

            const now = static_core.time_compat.Instant.now() catch {
                self.fireClockFailure();
                return;
            };
            if (now.since(last_progress) >= self.timeout_ns) {
                const stage_index = @min(
                    @as(usize, @intCast(self.stage_index.load(.acquire))),
                    self.stage_names.len - 1,
                );
                std.debug.print(
                    "static_sync benchmark watchdog timeout case={s} stage={s} timeout_ns={d}\n",
                    .{
                        self.case_name,
                        self.stage_names[stage_index],
                        self.timeout_ns,
                    },
                );
                self.timed_out.store(true, .release);
                return;
            }

            poll_countdown = contention_watchdog_poll_stride;
            std.Thread.yield() catch {};
        }
    }

    fn fireClockFailure(self: *ContentionWatchdog) void {
        std.debug.print(
            "static_sync benchmark watchdog clock failure case={s}\n",
            .{self.case_name},
        );
        self.timed_out.store(true, .release);
    }
};

pub fn openOutputDir(io: std.Io, benchmark_name: []const u8) !std.Io.Dir {
    const cwd = std.Io.Dir.cwd();
    var path_buffer: [192]u8 = undefined;
    const output_dir_path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/static_sync/benchmarks/{s}",
        .{benchmark_name},
    );
    return cwd.createDirPathOpen(io, output_dir_path, .{});
}

pub fn writeGroupReport(
    comptime case_capacity: usize,
    benchmark_name: []const u8,
    run_result: bench.runner.BenchmarkRunResult,
    io: std.Io,
    output_dir: std.Io.Dir,
    compare_config: bench.baseline.BaselineCompareConfig,
    metadata: ReportMetadata,
) !void {
    comptime assert(case_capacity > 0);
    assert(benchmark_name.len > 0);
    assert(run_result.case_results.len <= case_capacity);
    assert(metadata.environment_note.len > 0);
    assert(metadata.environment_tags.len <= max_environment_tag_count);

    const baseline_document_len = @max(16 * 1024, case_capacity * 2048);
    const read_source_len = @max(16 * 1024, case_capacity * 2048);
    const read_parse_len = @max(32 * 1024, case_capacity * 4096);
    const comparison_capacity = case_capacity * 2;
    const history_existing_len = @max(64 * 1024, case_capacity * 16 * 1024);
    const history_record_len = @max(16 * 1024, case_capacity * 4096);
    const history_frame_len = @max(16 * 1024, case_capacity * 4096);
    const history_output_len = @max(64 * 1024, case_capacity * 16 * 1024);
    const history_file_len = @max(64 * 1024, case_capacity * 16 * 1024);
    const history_names_len = @max(4096, case_capacity * 1024);

    var stats_storage: [case_capacity]bench.stats.BenchmarkStats = undefined;
    var baseline_document_buffer: [baseline_document_len]u8 = undefined;
    var read_source_buffer: [read_source_len]u8 = undefined;
    var read_parse_buffer: [read_parse_len]u8 = undefined;
    var comparisons: [comparison_capacity]bench.baseline.BaselineCaseComparison = undefined;
    var history_existing_buffer: [history_existing_len]u8 = undefined;
    var history_record_buffer: [history_record_len]u8 = undefined;
    var history_frame_buffer: [history_frame_len]u8 = undefined;
    var history_output_buffer: [history_output_len]u8 = undefined;
    var history_file_buffer: [history_file_len]u8 = undefined;
    var history_cases: [case_capacity]bench.stats.BenchmarkStats = undefined;
    var history_names: [history_names_len]u8 = undefined;
    var history_tags: [max_environment_tag_count][]const u8 = undefined;
    var history_comparisons: [comparison_capacity]bench.baseline.BaselineCaseComparison = undefined;
    var aw: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    _ = try bench.workflow.writeTextAndOptionalBaselineReport(&aw.writer, run_result, .{
        .io = io,
        .dir = output_dir,
        .sub_path = "baseline.zon",
        .mode = .record_if_missing_then_compare,
        .compare_config = compare_config,
        .enforce_gate = false,
        .stats_storage = &stats_storage,
        .baseline_document_buffer = &baseline_document_buffer,
        .read_buffers = .{
            .source_buffer = &read_source_buffer,
            .parse_buffer = &read_parse_buffer,
        },
        .comparison_storage = &comparisons,
        .history = .{
            .sub_path = "history.binlog",
            .package_name = "static_sync",
            .environment_note = metadata.environment_note,
            .environment_tags = metadata.environment_tags,
            .append_buffers = .{
                .existing_file_buffer = &history_existing_buffer,
                .record_buffer = &history_record_buffer,
                .frame_buffer = &history_frame_buffer,
                .output_file_buffer = &history_output_buffer,
            },
            .read_buffers = .{
                .file_buffer = &history_file_buffer,
                .case_storage = &history_cases,
                .string_buffer = &history_names,
                .tag_storage = &history_tags,
            },
            .comparison_storage = &history_comparisons,
        },
    });
    var out = aw.toArrayList();
    defer out.deinit(std.heap.page_allocator);
    std.debug.print("== static_sync {s} ==\n", .{benchmark_name});
    std.debug.print("{s}", .{out.items});
}
