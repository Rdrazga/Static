// This package is built as part of the static workspace.
// Standalone `zig build` from this directory is not supported.
// Use `zig build` from the workspace root instead.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const single_threaded = b.option(
        bool,
        "single_threaded",
        "Disable thread-based behavior",
    ) orelse false;
    const enable_os_backends = b.option(
        bool,
        "enable_os_backends",
        "Enable OS-specific backends",
    ) orelse false;
    const enable_tracing = b.option(
        bool,
        "enable_tracing",
        "Enable tracing/instrumentation hooks",
    ) orelse false;

    const options = b.addOptions();
    options.addOption(bool, "single_threaded", single_threaded);
    options.addOption(bool, "enable_os_backends", enable_os_backends);
    options.addOption(bool, "enable_tracing", enable_tracing);
    options.addOption([]const u8, "static_package", "static_queues");
    const options_mod = options.createModule();

    const core_dep = b.dependency("static_core", .{
        .target = target,
        .optimize = optimize,
        .single_threaded = single_threaded,
        .enable_os_backends = enable_os_backends,
        .enable_tracing = enable_tracing,
    });
    const memory_dep = b.dependency("static_memory", .{
        .target = target,
        .optimize = optimize,
        .single_threaded = single_threaded,
        .enable_os_backends = enable_os_backends,
        .enable_tracing = enable_tracing,
    });
    const collections_dep = b.dependency("static_collections", .{
        .target = target,
        .optimize = optimize,
        .single_threaded = single_threaded,
        .enable_os_backends = enable_os_backends,
        .enable_tracing = enable_tracing,
    });
    const sync_dep = b.dependency("static_sync", .{
        .target = target,
        .optimize = optimize,
        .single_threaded = single_threaded,
        .enable_os_backends = enable_os_backends,
        .enable_tracing = enable_tracing,
    });

    const core_mod = core_dep.module("static_core");
    const memory_mod = memory_dep.module("static_memory");
    const collections_mod = collections_dep.module("static_collections");
    const sync_mod = sync_dep.module("static_sync");

    const static_queues_mod = b.addModule("static_queues", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "static_build_options", .module = options_mod },
            .{ .name = "static_core", .module = core_mod },
            .{ .name = "static_memory", .module = memory_mod },
            .{ .name = "static_collections", .module = collections_mod },
            .{ .name = "static_sync", .module = sync_mod },
        },
    });

    const tests = b.addTest(.{ .root_module = static_queues_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const examples_step = b.step("examples", "Build examples");
    const examples = [_]struct { name: []const u8, path: []const u8 }{
        .{
            .name = "static_queues_ring_buffer_basic",
            .path = "examples/ring_buffer_basic.zig",
        },
        .{
            .name = "static_queues_spsc_basic",
            .path = "examples/spsc_basic.zig",
        },
        .{
            .name = "static_queues_channel_close",
            .path = "examples/channel_close.zig",
        },
        .{
            .name = "static_queues_spsc_isr_handoff",
            .path = "examples/spsc_isr_handoff.zig",
        },
        .{
            .name = "static_queues_mpsc_job_handoff",
            .path = "examples/mpsc_job_handoff.zig",
        },
        .{
            .name = "static_queues_broadcast_basic",
            .path = "examples/broadcast_basic.zig",
        },
        .{
            .name = "static_queues_inbox_outbox_basic",
            .path = "examples/inbox_outbox_basic.zig",
        },
        .{
            .name = "static_queues_work_stealing_basic",
            .path = "examples/work_stealing_basic.zig",
        },
        .{
            .name = "static_queues_mpmc_basic",
            .path = "examples/mpmc_basic.zig",
        },
        .{
            .name = "static_queues_priority_queue_basic",
            .path = "examples/priority_queue_basic.zig",
        },
        .{
            .name = "static_queues_intrusive_basic",
            .path = "examples/intrusive_basic.zig",
        },
        .{
            .name = "static_queues_disruptor_basic",
            .path = "examples/disruptor_basic.zig",
        },
    };
    for (examples) |ex| {
        const exe = b.addExecutable(.{
            .name = ex.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(ex.path),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "static_queues", .module = static_queues_mod },
                },
            }),
        });
        examples_step.dependOn(&exe.step);
    }
}
