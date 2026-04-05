const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const simd = @import("static_simd");

pub fn main() !void {
    const source = [_]f32{ 10.0, 20.0, 30.0, 40.0, 50.0 };
    const indices = simd.vec4i.Vec4i.init(.{ 4, -1, 2, 99 });
    const mask = simd.masked.Mask4.fromBits(0b0101);
    const passthrough = simd.vec4f.Vec4f.splat(-1.0);

    // Masked gather is lane-explicit: masked-out lanes keep their passthrough
    // value, and invalid indices in those lanes are ignored.
    const gathered = try simd.gather_scatter.gatherMasked4f(
        &source,
        indices,
        mask,
        passthrough,
    );
    const gathered_arr = gathered.toArray();
    assert(gathered_arr[0] == 50.0);
    assert(gathered_arr[1] == -1.0);
    assert(gathered_arr[2] == 30.0);
    assert(gathered_arr[3] == -1.0);

    var destination = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0 };
    const before = destination;
    const values = simd.vec4f.Vec4f.init(.{ 500.0, 600.0, 700.0, 800.0 });

    // Masked scatter validates all active lanes before writing anything, so an
    // out-of-bounds active lane preserves the original slice.
    const failing_mask = simd.masked.Mask4.fromBits(0b1001);
    const failing_indices = simd.vec4i.Vec4i.init(.{ 0, 1, 2, 9 });
    try testing.expectError(
        error.IndexOutOfBounds,
        simd.gather_scatter.scatterMasked4f(
            destination[0..],
            failing_indices,
            values,
            failing_mask,
        ),
    );
    assert(std.mem.eql(f32, before[0..], destination[0..]));

    try simd.gather_scatter.scatterMasked4f(
        destination[0..],
        indices,
        values,
        mask,
    );
    assert(destination[4] == 500.0);
    assert(destination[2] == 700.0);
    assert(destination[1] == 2.0);
    assert(destination[3] == 4.0);
}
