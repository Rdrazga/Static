const std = @import("std");
const static_io = @import("static_io");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pool = try static_io.BufferPool.init(allocator, .{
        .buffer_size = 16,
        .capacity = 2,
    });
    defer pool.deinit();

    var runtime = try static_io.Runtime.init(allocator, static_io.RuntimeConfig.initForTest(2));
    defer runtime.deinit();

    const buffer = try pool.acquire();
    const operation_id = try runtime.submit(.{ .fill = .{
        .buffer = buffer,
        .len = 4,
        .byte = 0x7F,
    } });

    _ = try runtime.pump(1);
    const completion = runtime.poll() orelse return error.UnexpectedCompletion;
    defer pool.release(completion.buffer) catch unreachable;

    std.debug.print(
        "op={d} status={s} bytes={d} first={d}\n",
        .{
            operation_id,
            @tagName(completion.status),
            completion.bytes_transferred,
            completion.buffer.bytes[0],
        },
    );
}
