const std = @import("std");
const simd = @import("static_simd");

pub fn main() void {
    const lhs = simd.vec4f.Vec4f.init(.{ -3.0, 4.0, -1.0, 8.0 });
    const rhs = simd.vec4f.Vec4f.splat(0.0);
    const positive_mask = simd.compare.cmpGt(lhs, rhs);

    // Compare modules produce typed masks, and the vector type owns the
    // corresponding select operation.
    std.debug.assert(positive_mask.toBits() == 0b1010);

    const magnitudes = simd.vec4f.Vec4f.abs(lhs);
    const signed = simd.vec4f.Vec4f.select(
        positive_mask,
        magnitudes,
        simd.vec4f.Vec4f.negate(magnitudes),
    );
    const signed_arr = signed.toArray();
    std.debug.assert(signed_arr[0] == -3.0);
    std.debug.assert(signed_arr[1] == 4.0);
    std.debug.assert(signed_arr[2] == -1.0);
    std.debug.assert(signed_arr[3] == 8.0);

    const min_mask = simd.compare.cmpLt(
        lhs,
        simd.vec4f.Vec4f.splat(2.0),
    );
    std.debug.assert(min_mask.any());
    std.debug.assert(!min_mask.all());
}
