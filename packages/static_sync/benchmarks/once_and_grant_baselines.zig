//! `static_sync` once and grant benchmarks.
//!
//! Scope:
//! - isolated `Once.call` first-call versus done-fast-path attribution;
//! - end-to-end `Once` cycle cost for continuity with the earlier baseline; and
//! - isolated plus combined grant token, validation, and write-record costs.

const std = @import("std");
const assert = std.debug.assert;
const static_sync = @import("static_sync");
const support = @import("support.zig");

const bench = support.bench;
const bench_config = support.fast_path_benchmark_config;
const benchmark_name = "once_and_grant_baselines";

const once_first_only_tags = &[_][]const u8{
    "static_sync",
    "once",
    "first_call",
    "isolated",
    "baseline",
};
const once_done_fastpath_tags = &[_][]const u8{
    "static_sync",
    "once",
    "done_fastpath",
    "isolated",
    "baseline",
};
const once_cycle_tags = &[_][]const u8{
    "static_sync",
    "once",
    "first_call",
    "cycle",
    "baseline",
};
const grant_issue_only_tags = &[_][]const u8{
    "static_sync",
    "grant",
    "issue_token",
    "isolated",
    "baseline",
};
const grant_validate_tags = &[_][]const u8{
    "static_sync",
    "grant",
    "validate_token",
    "isolated",
    "baseline",
};
const grant_issue_validate_tags = &[_][]const u8{
    "static_sync",
    "grant",
    "issue_validate",
    "baseline",
};
const grant_record_first_tags = &[_][]const u8{
    "static_sync",
    "grant",
    "record_write",
    "first_write",
    "baseline",
};
const grant_record_duplicate_tags = &[_][]const u8{
    "static_sync",
    "grant",
    "record_write",
    "duplicate_write",
    "baseline",
};
const grant_written_hit_tags = &[_][]const u8{
    "static_sync",
    "grant",
    "written_lookup",
    "hit",
    "baseline",
};
const grant_write_tags = &[_][]const u8{
    "static_sync",
    "grant",
    "record_write",
    "baseline",
};

const grant_id: u64 = 7;
const grant_resource_id: u64 = 55;
const grant_write_resource_id: u64 = 81;
const grant_write_instance_id: u64 = 1001;

const GrantType = static_sync.grant.Grant(4, 4);

const OnceFirstCallContext = struct {
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *OnceFirstCallContext = @ptrCast(@alignCast(context_ptr));
        var once = static_sync.once.Once{};
        once.call(noop);
        assert(once.done.load(.acquire));
        context.sink +%= bench.case.blackBox(@as(u64, @intFromBool(once.done.load(.acquire))));
    }
};

const OnceDoneFastpathContext = struct {
    once: static_sync.once.Once = .{},
    sink: u64 = 0,

    fn reset(self: *@This()) void {
        self.once = .{};
        self.once.call(noop);
        assert(self.once.done.load(.acquire));
    }

    fn prepare(context_ptr: *anyopaque, _: bench.case.BenchmarkRunPhase, _: u32) void {
        const context: *OnceDoneFastpathContext = @ptrCast(@alignCast(context_ptr));
        context.reset();
    }

    fn run(context_ptr: *anyopaque) void {
        const context: *OnceDoneFastpathContext = @ptrCast(@alignCast(context_ptr));
        context.once.call(noop);
        assert(context.once.done.load(.acquire));
        context.sink +%= bench.case.blackBox(@as(u64, @intFromBool(context.once.done.load(.acquire))));
    }
};

const OnceCycleContext = struct {
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *OnceCycleContext = @ptrCast(@alignCast(context_ptr));
        var once = static_sync.once.Once{};
        once.call(noop);
        once.call(noop);
        assert(once.done.load(.acquire));
        context.sink +%= bench.case.blackBox(@as(u64, @intFromBool(once.done.load(.acquire))));
    }
};

const GrantIssueTokenContext = struct {
    grant: GrantType = undefined,
    sink: u64 = 0,

    fn reset(self: *@This()) void {
        self.grant = GrantType.begin(grant_id);
        self.grant.grantWrite(grant_resource_id) catch unreachable;
        assert(self.grant.canWrite(grant_resource_id));
    }

    fn prepare(context_ptr: *anyopaque, _: bench.case.BenchmarkRunPhase, _: u32) void {
        const context: *GrantIssueTokenContext = @ptrCast(@alignCast(context_ptr));
        context.reset();
    }

    fn run(context_ptr: *anyopaque) void {
        const context: *GrantIssueTokenContext = @ptrCast(@alignCast(context_ptr));
        const token = context.grant.issueToken(grant_resource_id, .write) catch unreachable;
        assert(token.resource_id == grant_resource_id);
        assert(token.access == .write);
        context.sink +%= bench.case.blackBox(token.resource_id);
    }
};

const GrantValidateTokenContext = struct {
    grant: GrantType = undefined,
    token: static_sync.grant.CapabilityToken = undefined,
    sink: u64 = 0,

    fn reset(self: *@This()) void {
        self.grant = GrantType.begin(grant_id);
        self.grant.grantWrite(grant_resource_id) catch unreachable;
        self.token = self.grant.issueToken(grant_resource_id, .write) catch unreachable;
        assert(self.grant.validateToken(self.token, .write));
    }

    fn prepare(context_ptr: *anyopaque, _: bench.case.BenchmarkRunPhase, _: u32) void {
        const context: *GrantValidateTokenContext = @ptrCast(@alignCast(context_ptr));
        context.reset();
    }

    fn run(context_ptr: *anyopaque) void {
        const context: *GrantValidateTokenContext = @ptrCast(@alignCast(context_ptr));
        const is_valid = context.grant.validateToken(context.token, .write);
        assert(is_valid);
        context.sink +%= bench.case.blackBox(@as(u64, @intFromBool(is_valid)));
    }
};

const GrantIssueValidateContext = struct {
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *GrantIssueValidateContext = @ptrCast(@alignCast(context_ptr));
        var grant = GrantType.begin(grant_id);
        grant.grantWrite(grant_resource_id) catch unreachable;

        const token = grant.issueToken(grant_resource_id, .write) catch unreachable;
        assert(grant.validateToken(token, .read));
        assert(grant.validateToken(token, .write));
        context.sink +%= bench.case.blackBox(@as(u64, @intFromBool(grant.validateToken(token, .write))));
    }
};

const GrantRecordWriteFirstContext = struct {
    grant: GrantType = undefined,
    sink: u64 = 0,

    fn reset(self: *@This()) void {
        self.grant = GrantType.begin(9);
        self.grant.grantWrite(grant_write_resource_id) catch unreachable;
        assert(self.grant.writtenCount() == 0);
    }

    fn prepare(context_ptr: *anyopaque, _: bench.case.BenchmarkRunPhase, _: u32) void {
        const context: *GrantRecordWriteFirstContext = @ptrCast(@alignCast(context_ptr));
        context.reset();
    }

    fn run(context_ptr: *anyopaque) void {
        const context: *GrantRecordWriteFirstContext = @ptrCast(@alignCast(context_ptr));
        context.grant.recordWrite(grant_write_resource_id, grant_write_instance_id) catch unreachable;
        assert(context.grant.wasWritten(grant_write_resource_id, grant_write_instance_id));
        assert(context.grant.writtenCount() == 1);
        context.sink +%= bench.case.blackBox(@as(u64, context.grant.writtenCount()));
    }
};

const GrantRecordWriteDuplicateContext = struct {
    grant: GrantType = undefined,
    sink: u64 = 0,

    fn reset(self: *@This()) void {
        self.grant = GrantType.begin(9);
        self.grant.grantWrite(grant_write_resource_id) catch unreachable;
        self.grant.recordWrite(grant_write_resource_id, grant_write_instance_id) catch unreachable;
        assert(self.grant.writtenCount() == 1);
    }

    fn prepare(context_ptr: *anyopaque, _: bench.case.BenchmarkRunPhase, _: u32) void {
        const context: *GrantRecordWriteDuplicateContext = @ptrCast(@alignCast(context_ptr));
        context.reset();
    }

    fn run(context_ptr: *anyopaque) void {
        const context: *GrantRecordWriteDuplicateContext = @ptrCast(@alignCast(context_ptr));
        context.grant.recordWrite(grant_write_resource_id, grant_write_instance_id) catch unreachable;
        assert(context.grant.writtenCount() == 1);
        context.sink +%= bench.case.blackBox(@as(u64, context.grant.writtenCount()));
    }
};

const GrantWasWrittenHitContext = struct {
    grant: GrantType = undefined,
    sink: u64 = 0,

    fn reset(self: *@This()) void {
        self.grant = GrantType.begin(9);
        self.grant.grantWrite(grant_write_resource_id) catch unreachable;
        self.grant.recordWrite(grant_write_resource_id, grant_write_instance_id) catch unreachable;
        assert(self.grant.wasWritten(grant_write_resource_id, grant_write_instance_id));
    }

    fn prepare(context_ptr: *anyopaque, _: bench.case.BenchmarkRunPhase, _: u32) void {
        const context: *GrantWasWrittenHitContext = @ptrCast(@alignCast(context_ptr));
        context.reset();
    }

    fn run(context_ptr: *anyopaque) void {
        const context: *GrantWasWrittenHitContext = @ptrCast(@alignCast(context_ptr));
        const was_written = context.grant.wasWritten(grant_write_resource_id, grant_write_instance_id);
        assert(was_written);
        context.sink +%= bench.case.blackBox(@as(u64, @intFromBool(was_written)));
    }
};

const GrantRecordWriteContext = struct {
    sink: u64 = 0,

    fn run(context_ptr: *anyopaque) void {
        const context: *GrantRecordWriteContext = @ptrCast(@alignCast(context_ptr));
        var grant = GrantType.begin(9);
        grant.grantWrite(grant_write_resource_id) catch unreachable;
        grant.recordWrite(grant_write_resource_id, grant_write_instance_id) catch unreachable;
        assert(grant.wasWritten(grant_write_resource_id, grant_write_instance_id));
        assert(grant.writtenCount() == 1);
        grant.recordWrite(grant_write_resource_id, grant_write_instance_id) catch unreachable;
        assert(grant.writtenCount() == 1);
        context.sink +%= bench.case.blackBox(@as(u64, grant.writtenCount()));
    }
};

pub fn main() !void {
    validateSemanticPreflight();

    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
        .environ = .empty,
    });
    defer threaded_io.deinit();

    const io = threaded_io.io();
    var output_dir = try support.openOutputDir(io, benchmark_name);
    defer output_dir.close(io);

    var once_first_context = OnceFirstCallContext{};
    var once_done_fastpath_context = OnceDoneFastpathContext{};
    var once_cycle_context = OnceCycleContext{};
    var grant_issue_context = GrantIssueTokenContext{};
    var grant_validate_context = GrantValidateTokenContext{};
    var grant_issue_validate_context = GrantIssueValidateContext{};
    var grant_record_first_context = GrantRecordWriteFirstContext{};
    var grant_record_duplicate_context = GrantRecordWriteDuplicateContext{};
    var grant_written_hit_context = GrantWasWrittenHitContext{};
    var grant_record_write_context = GrantRecordWriteContext{};

    var case_storage: [10]bench.case.BenchmarkCase = undefined;
    var group = try bench.group.BenchmarkGroup.init(&case_storage, .{
        .name = "static_sync_once_and_grant_baselines",
        .config = bench_config,
    });
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "once_first_call_only",
        .tags = once_first_only_tags,
        .context = &once_first_context,
        .run_fn = OnceFirstCallContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "once_done_fastpath_only",
        .tags = once_done_fastpath_tags,
        .context = &once_done_fastpath_context,
        .run_fn = OnceDoneFastpathContext.run,
        .prepare_context = &once_done_fastpath_context,
        .prepare_fn = OnceDoneFastpathContext.prepare,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "once_first_call_cycle",
        .tags = once_cycle_tags,
        .context = &once_cycle_context,
        .run_fn = OnceCycleContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "grant_issue_token_write",
        .tags = grant_issue_only_tags,
        .context = &grant_issue_context,
        .run_fn = GrantIssueTokenContext.run,
        .prepare_context = &grant_issue_context,
        .prepare_fn = GrantIssueTokenContext.prepare,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "grant_validate_token_write",
        .tags = grant_validate_tags,
        .context = &grant_validate_context,
        .run_fn = GrantValidateTokenContext.run,
        .prepare_context = &grant_validate_context,
        .prepare_fn = GrantValidateTokenContext.prepare,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "grant_issue_validate_write",
        .tags = grant_issue_validate_tags,
        .context = &grant_issue_validate_context,
        .run_fn = GrantIssueValidateContext.run,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "grant_record_write_first",
        .tags = grant_record_first_tags,
        .context = &grant_record_first_context,
        .run_fn = GrantRecordWriteFirstContext.run,
        .prepare_context = &grant_record_first_context,
        .prepare_fn = GrantRecordWriteFirstContext.prepare,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "grant_record_write_duplicate",
        .tags = grant_record_duplicate_tags,
        .context = &grant_record_duplicate_context,
        .run_fn = GrantRecordWriteDuplicateContext.run,
        .prepare_context = &grant_record_duplicate_context,
        .prepare_fn = GrantRecordWriteDuplicateContext.prepare,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "grant_was_written_hit",
        .tags = grant_written_hit_tags,
        .context = &grant_written_hit_context,
        .run_fn = GrantWasWrittenHitContext.run,
        .prepare_context = &grant_written_hit_context,
        .prepare_fn = GrantWasWrittenHitContext.prepare,
    }));
    try group.addCase(bench.case.BenchmarkCase.init(.{
        .name = "grant_record_write_dedup",
        .tags = grant_write_tags,
        .context = &grant_record_write_context,
        .run_fn = GrantRecordWriteContext.run,
    }));

    var sample_storage: [10 * bench_config.sample_count]bench.runner.BenchmarkSample = undefined;
    var case_result_storage: [10]bench.runner.BenchmarkCaseResult = undefined;
    const run_result = try bench.runner.runGroup(
        &group,
        &sample_storage,
        &case_result_storage,
    );

    try support.writeGroupReport(
        10,
        benchmark_name,
        run_result,
        io,
        output_dir,
        support.fast_path_compare_config,
        .{
            .environment_note = support.default_environment_note,
            .environment_tags = support.fast_path_environment_tags,
        },
    );
}

fn validateSemanticPreflight() void {
    var once_first_context = OnceFirstCallContext{};
    OnceFirstCallContext.run(&once_first_context);
    assert(once_first_context.sink != 0);

    var once_done_fastpath_context = OnceDoneFastpathContext{};
    once_done_fastpath_context.reset();
    OnceDoneFastpathContext.run(&once_done_fastpath_context);
    assert(once_done_fastpath_context.sink != 0);

    var once_cycle_context = OnceCycleContext{};
    OnceCycleContext.run(&once_cycle_context);
    assert(once_cycle_context.sink != 0);

    var grant_issue_context = GrantIssueTokenContext{};
    grant_issue_context.reset();
    GrantIssueTokenContext.run(&grant_issue_context);
    assert(grant_issue_context.sink == grant_resource_id);

    var grant_validate_context = GrantValidateTokenContext{};
    grant_validate_context.reset();
    GrantValidateTokenContext.run(&grant_validate_context);
    assert(grant_validate_context.sink == 1);

    var grant_issue_validate_context = GrantIssueValidateContext{};
    GrantIssueValidateContext.run(&grant_issue_validate_context);
    assert(grant_issue_validate_context.sink == 1);

    var grant_record_first_context = GrantRecordWriteFirstContext{};
    grant_record_first_context.reset();
    GrantRecordWriteFirstContext.run(&grant_record_first_context);
    assert(grant_record_first_context.sink == 1);

    var grant_record_duplicate_context = GrantRecordWriteDuplicateContext{};
    grant_record_duplicate_context.reset();
    GrantRecordWriteDuplicateContext.run(&grant_record_duplicate_context);
    assert(grant_record_duplicate_context.sink == 1);

    var grant_written_hit_context = GrantWasWrittenHitContext{};
    grant_written_hit_context.reset();
    GrantWasWrittenHitContext.run(&grant_written_hit_context);
    assert(grant_written_hit_context.sink == 1);

    var grant_record_write_context = GrantRecordWriteContext{};
    GrantRecordWriteContext.run(&grant_record_write_context);
    assert(grant_record_write_context.sink == 1);
}

fn noop() void {}
