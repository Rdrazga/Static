const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const static_io = @import("static_io");
const static_testing = @import("static_testing");

const checker = static_testing.testing.checker;
const fuzz_runner = static_testing.testing.fuzz_runner;
const identity = static_testing.testing.identity;

const case_count_max: u32 = 64;
const steps_per_case: u32 = 256;
const pool_capacity: usize = 8;
const buffer_size: u32 = 64;

const fuzz_violations = [_]checker.Violation{
    .{
        .code = "static_io.fuzz_invariant",
        .message = "runtime/buffer fuzz sequence violated a bounded ownership invariant",
    },
};

const PendingOperation = struct {
    operation_id: static_io.types.OperationId,
    tag: static_io.types.OperationTag,
    expected_used_len: u32,
    expected_byte: u8,
};

test "static_io runtime and buffer pool survive larger deterministic fuzz sequences" {
    const Runner = fuzz_runner.FuzzRunner(error{}, error{});
    const summary = try fuzz_runner.runFuzzCases(error{}, error{}, Runner{
        .config = .{
            .package_name = "static_io",
            .run_name = "runtime_buffer_sequences",
            .base_seed = .init(0x51A71C0),
            .build_mode = .debug,
            .case_count_max = case_count_max,
        },
        .target = .{
            .context = undefined,
            .run_fn = FuzzContext.run,
        },
    });

    try testing.expectEqual(case_count_max, summary.executed_case_count);
    try testing.expect(summary.failed_case == null);
}

const FuzzContext = struct {
    fn run(
        _: *const anyopaque,
        run_identity: identity.RunIdentity,
    ) error{}!fuzz_runner.FuzzExecution {
        var prng = std.Random.DefaultPrng.init(run_identity.seed.value);
        const random = prng.random();

        var pool = static_io.BufferPool.init(testing.allocator, .{
            .buffer_size = buffer_size,
            .capacity = pool_capacity,
        }) catch unreachable;
        defer pool.deinit();

        var runtime_config = static_io.RuntimeConfig.initForTest(pool_capacity);
        runtime_config.backend_kind = .fake;
        var runtime = static_io.Runtime.init(testing.allocator, runtime_config) catch unreachable;
        defer runtime.deinit();

        var held_buffers: [pool_capacity]?static_io.Buffer = [_]?static_io.Buffer{null} ** pool_capacity;
        var pending_storage: [pool_capacity]PendingOperation = undefined;
        var pending_count: usize = 0;
        var max_pending_count: usize = 0;
        var steps_executed: u32 = 0;

        while (steps_executed < steps_per_case) : (steps_executed += 1) {
            switch (random.int(u32) % 5) {
                0 => tryAcquire(&pool, &held_buffers),
                1 => submitHeldBuffer(random, &runtime, &held_buffers, &pending_storage, &pending_count),
                2 => drainPending(random, &runtime, &pool, &pending_storage, &pending_count),
                3 => releaseHeld(random, &pool, &held_buffers),
                4 => validateNoSpaceLeftFastPath(&pool, &held_buffers, pending_count),
                else => unreachable,
            }

            max_pending_count = @max(max_pending_count, pending_count);
            if (!invariantsHold(&pool, &held_buffers, pending_count)) {
                return failExecution(steps_executed + 1, max_pending_count);
            }
        }

        while (pending_count != 0) {
            drainPending(random, &runtime, &pool, &pending_storage, &pending_count);
            if (!invariantsHold(&pool, &held_buffers, pending_count)) {
                return failExecution(steps_executed, max_pending_count);
            }
        }
        releaseAllHeld(&pool, &held_buffers);

        if (pool.available() != pool.capacity()) {
            return failExecution(steps_executed, max_pending_count);
        }

        return .{
            .trace_metadata = .{
                .event_count = steps_executed,
                .truncated = false,
                .has_range = true,
                .first_sequence_no = 0,
                .last_sequence_no = steps_executed,
                .first_timestamp_ns = run_identity.seed.value,
                .last_timestamp_ns = run_identity.seed.value + steps_executed + max_pending_count,
            },
            .check_result = checker.CheckResult.pass(checker.CheckpointDigest.init(
                (@as(u128, steps_executed) << 64) |
                    @as(u128, pool.available()) |
                    (@as(u128, max_pending_count) << 32),
            )),
        };
    }
};

fn tryAcquire(
    pool: *static_io.BufferPool,
    held_buffers: *[pool_capacity]?static_io.Buffer,
) void {
    assert(pool.capacity() == pool_capacity);

    const free_slot = firstFreeHeldSlot(held_buffers);
    if (free_slot == null) return;
    held_buffers[free_slot.?] = pool.acquire() catch |err| switch (err) {
        error.NoSpaceLeft => return,
    };
}

fn submitHeldBuffer(
    random: std.Random,
    runtime: *static_io.Runtime,
    held_buffers: *[pool_capacity]?static_io.Buffer,
    pending_storage: *[pool_capacity]PendingOperation,
    pending_count: *usize,
) void {
    const held_index = firstHeldSlot(held_buffers) orelse return;
    assert(pending_count.* < pending_storage.len);

    var buffer = held_buffers[held_index].?;
    held_buffers[held_index] = null;

    const submit_fill = (random.int(u32) & 1) == 0;
    if (submit_fill) {
        const len = @max(@as(u32, 1), @as(u32, @intCast((random.int(u32) % buffer.capacity()) + 1)));
        const byte: u8 = @truncate(random.int(u32));
        const operation_id = runtime.submit(.{ .fill = .{
            .buffer = buffer,
            .len = len,
            .byte = byte,
        } }) catch unreachable;
        pending_storage[pending_count.*] = .{
            .operation_id = operation_id,
            .tag = .fill,
            .expected_used_len = len,
            .expected_byte = byte,
        };
        pending_count.* += 1;
        return;
    }

    const operation_id = runtime.submit(.{ .nop = buffer }) catch unreachable;
    pending_storage[pending_count.*] = .{
        .operation_id = operation_id,
        .tag = .nop,
        .expected_used_len = 0,
        .expected_byte = 0,
    };
    pending_count.* += 1;
}

fn drainPending(
    random: std.Random,
    runtime: *static_io.Runtime,
    pool: *static_io.BufferPool,
    pending_storage: *[pool_capacity]PendingOperation,
    pending_count: *usize,
) void {
    if (pending_count.* == 0) return;

    const pump_max: u32 = @intCast((random.int(u32) % pending_count.*) + 1);
    _ = runtime.pump(pump_max) catch unreachable;

    while (runtime.poll()) |completion| {
        const pending_index = pendingIndex(pending_storage[0..pending_count.*], completion.operation_id) orelse continue;
        const pending = pending_storage[pending_index];
        swapRemovePending(pending_storage, pending_count, pending_index);

        if (completion.status != .success) unreachable;
        if (completion.tag != pending.tag) unreachable;
        if (completion.tag == .fill) {
            if (completion.buffer.used_len != pending.expected_used_len) unreachable;
            if (completion.buffer.usedSlice().len != pending.expected_used_len) unreachable;
            for (completion.buffer.usedSlice()) |byte| {
                if (byte != pending.expected_byte) unreachable;
            }
        } else if (completion.buffer.used_len != 0) {
            unreachable;
        }

        pool.release(completion.buffer) catch unreachable;
    }
}

fn releaseHeld(
    random: std.Random,
    pool: *static_io.BufferPool,
    held_buffers: *[pool_capacity]?static_io.Buffer,
) void {
    const held_count = countHeld(held_buffers.*);
    if (held_count == 0) return;

    const target = random.int(u32) % @as(u32, @intCast(held_count));
    var ordinal: u32 = 0;
    for (held_buffers, 0..) |buffer, index| {
        if (buffer == null) continue;
        if (ordinal != target) {
            ordinal += 1;
            continue;
        }

        pool.release(buffer.?) catch unreachable;
        held_buffers[index] = null;
        return;
    }
    unreachable;
}

fn validateNoSpaceLeftFastPath(
    pool: *static_io.BufferPool,
    held_buffers: *[pool_capacity]?static_io.Buffer,
    pending_count: usize,
) void {
    if (pool.available() != 0) return;
    if (countHeld(held_buffers.*) + pending_count != pool_capacity) return;
    assert(pool.acquire() == error.NoSpaceLeft);
}

fn invariantsHold(
    pool: *const static_io.BufferPool,
    held_buffers: *const [pool_capacity]?static_io.Buffer,
    pending_count: usize,
) bool {
    const held_count = countHeld(held_buffers.*);
    const total_owned = held_count + pending_count + pool.available();
    return total_owned == pool.capacity();
}

fn failExecution(
    steps_executed: u32,
    max_pending_count: usize,
) fuzz_runner.FuzzExecution {
    return .{
        .trace_metadata = .{
            .event_count = steps_executed,
            .truncated = false,
            .has_range = true,
            .first_sequence_no = 0,
            .last_sequence_no = steps_executed,
            .first_timestamp_ns = steps_executed,
            .last_timestamp_ns = steps_executed + max_pending_count,
        },
        .check_result = checker.CheckResult.fail(
            &fuzz_violations,
            checker.CheckpointDigest.init(
                (@as(u128, steps_executed) << 64) | @as(u128, max_pending_count),
            ),
        ),
    };
}

fn firstFreeHeldSlot(
    held_buffers: *[pool_capacity]?static_io.Buffer,
) ?usize {
    for (held_buffers, 0..) |buffer, index| {
        if (buffer == null) return index;
    }
    return null;
}

fn firstHeldSlot(
    held_buffers: *[pool_capacity]?static_io.Buffer,
) ?usize {
    for (held_buffers, 0..) |buffer, index| {
        if (buffer != null) return index;
    }
    return null;
}

fn releaseAllHeld(
    pool: *static_io.BufferPool,
    held_buffers: *[pool_capacity]?static_io.Buffer,
) void {
    for (held_buffers) |*buffer| {
        if (buffer.*) |value| {
            pool.release(value) catch unreachable;
            buffer.* = null;
        }
    }
}

fn countHeld(held_buffers: [pool_capacity]?static_io.Buffer) usize {
    var count: usize = 0;
    for (held_buffers) |buffer| {
        if (buffer != null) count += 1;
    }
    return count;
}

fn pendingIndex(
    pending: []const PendingOperation,
    operation_id: static_io.types.OperationId,
) ?usize {
    for (pending, 0..) |entry, index| {
        if (entry.operation_id == operation_id) return index;
    }
    return null;
}

fn swapRemovePending(
    pending_storage: *[pool_capacity]PendingOperation,
    pending_count: *usize,
    index: usize,
) void {
    assert(index < pending_count.*);
    pending_count.* -= 1;
    pending_storage[index] = pending_storage[pending_count.*];
}
