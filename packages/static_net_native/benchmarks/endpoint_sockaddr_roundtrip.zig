//! `static_net_native` endpoint/socket-address roundtrip baseline benchmark.

const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const static_net_native = @import("static_net_native");
const static_testing = @import("static_testing");
const support = @import("support.zig");

const bench = static_testing.bench;

const bench_config = bench.config.BenchmarkConfig{
    .mode = .full,
    .warmup_iterations = 32,
    .measure_iterations = 2_097_152,
    .sample_count = 16,
};

const NativeModule = switch (builtin.os.tag) {
    .windows => static_net_native.windows,
    .linux => static_net_native.linux,
    else => static_net_native.posix,
};

const Storage = switch (builtin.os.tag) {
    .windows => std.os.windows.ws2_32.sockaddr.storage,
    .linux => std.os.linux.sockaddr.storage,
    else => std.posix.sockaddr.storage,
};

const CaseContext = struct {
    endpoint: static_net_native.Endpoint,
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *CaseContext = @ptrCast(@alignCast(context_ptr));
        const sockaddr = NativeModule.SockaddrAny.fromEndpoint(context.endpoint);
        const storage: *const Storage = @ptrCast(@alignCast(sockaddr.ptr()));
        const roundtrip = NativeModule.endpointFromStorage(storage) orelse unreachable;
        if (!std.meta.eql(context.endpoint, roundtrip)) unreachable;

        context.sink = bench.case.blackBox(
            support.foldDigest(
                support.digestEndpoint(context.endpoint),
                @as(u64, @intCast(sockaddr.len())),
            ),
        );
        assert(context.sink != 0);
    }
};

pub fn main() !void {
    validateSemanticPreflight();

    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    var output_dir = try support.openOutputDir(io, "endpoint_sockaddr_roundtrip");
    defer output_dir.close(io);

    var ipv4_context = CaseContext{
        .endpoint = support.buildIpv4Endpoint(0x6e47_6e61_7469_0101),
    };
    var ipv6_context = CaseContext{
        .endpoint = support.buildIpv6Endpoint(0x6e47_6e61_7469_0102),
    };
    var case_storage: [2]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_net_native_endpoint_sockaddr_roundtrip",
        .config = bench_config,
    });
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "ipv4_endpoint_roundtrip",
        .tags = &[_][]const u8{ "static_net_native", "ipv4", "sockaddr" },
        .context = &ipv4_context,
        .run_fn = CaseContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "ipv6_endpoint_roundtrip",
        .tags = &[_][]const u8{ "static_net_native", "ipv6", "sockaddr" },
        .context = &ipv6_context,
        .run_fn = CaseContext.run,
    }));

    var sample_storage: [bench_config.sample_count * 2]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [2]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(
        &group,
        &sample_storage,
        &case_result_storage,
    );

    std.debug.print("== static_net_native endpoint/socketaddr roundtrip ==\n", .{});
    try support.writeGroupReport(
        run_result,
        io,
        output_dir,
        support.default_environment_note,
    );
}

fn validateSemanticPreflight() void {
    var ipv4_context = CaseContext{
        .endpoint = support.buildIpv4Endpoint(0x6e47_6e61_7469_0201),
    };
    CaseContext.run(&ipv4_context);

    var ipv6_context = CaseContext{
        .endpoint = support.buildIpv6Endpoint(0x6e47_6e61_7469_0202),
    };
    CaseContext.run(&ipv6_context);
}
