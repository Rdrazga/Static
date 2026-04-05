const std = @import("std");
const assert = std.debug.assert;
const rng = @import("static_rng");

pub fn main() !void {
    var parent = rng.Xoroshiro128Plus.init(0x1234_5678_9abc_def0);
    var child = parent.split();

    // `split` is the package's intended way to derive deterministic parallel
    // streams without introducing shared global RNG state.
    const parent_roll = try rng.distributions.uintInRange(&parent, 10, 20);
    const child_roll = try rng.distributions.uintInRange(&child, 10, 20);
    assert(parent_roll >= 10);
    assert(parent_roll <= 20);
    assert(child_roll >= 10);
    assert(child_roll <= 20);

    const parent_bucket = try rng.distributions.uintBelow(&parent, 8);
    const child_bucket = try rng.distributions.uintBelow(&child, 8);
    assert(parent_bucket < 8);
    assert(child_bucket < 8);

    const parent_unit32 = rng.distributions.f32Unit(&parent);
    const child_unit64 = rng.distributions.f64Unit(&child);
    assert(parent_unit32 >= 0.0);
    assert(parent_unit32 < 1.0);
    assert(child_unit64 >= 0.0);
    assert(child_unit64 < 1.0);

    std.debug.print(
        "parent roll={d} bucket={d} unit32={d:.6}\nchild  roll={d} bucket={d} unit64={d:.6}\n",
        .{
            parent_roll,
            parent_bucket,
            parent_unit32,
            child_roll,
            child_bucket,
            child_unit64,
        },
    );
}
