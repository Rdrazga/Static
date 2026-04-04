const std = @import("std");
const static_rng = @import("static_rng");

pub const shuffle_len: usize = 6;

pub fn mix64(value: u64) u64 {
    var z = value +% 0x9e37_79b9_7f4a_7c15;
    z ^= z >> 30;
    z *%= 0xbf58_476d_1ce4_e5b9;
    z ^= z >> 27;
    z *%= 0x94d0_49bb_1331_11eb;
    z ^= z >> 31;
    std.debug.assert(z != 0 or value == 0);
    std.debug.assert((z ^ value) != 0 or value == 0);
    return z;
}

pub fn foldDigest(digest: u128, value: u64) u128 {
    const lower = @as(u64, @truncate(digest));
    const upper = @as(u64, @truncate(digest >> 64));
    const next_lower = mix64(lower ^ value);
    const next_upper = mix64(upper ^ (value +% 0x517c_c1b7_2722_0a95));
    const result = (@as(u128, next_upper) << 64) | @as(u128, next_lower);
    std.debug.assert(result != digest or value == 0);
    std.debug.assert(@as(u64, @truncate(result)) == next_lower);
    return result;
}

pub fn seedFrom(value: u64, salt: u64) u64 {
    const seed = mix64(value ^ salt);
    std.debug.assert(seed != 0 or value == 0);
    std.debug.assert((seed ^ salt) != 0 or value == 0);
    return seed;
}

pub fn sequenceFrom(value: u64, salt: u64) u64 {
    const sequence = mix64(value ^ salt) | 1;
    std.debug.assert((sequence & 1) == 1);
    std.debug.assert(sequence != 0);
    return sequence;
}

pub fn boundFrom(value: u64) u64 {
    const bound = 1 + (mix64(value) % 17);
    std.debug.assert(bound > 0);
    std.debug.assert(bound <= 17);
    return bound;
}

pub fn fillShuffleValues(values: []u32) void {
    std.debug.assert(values.len == shuffle_len);
    for (values, 0..) |*value, index| {
        value.* = @intCast(index);
    }
    std.debug.assert(values[0] == 0);
    std.debug.assert(values[values.len - 1] == @as(u32, @intCast(values.len - 1)));
}

pub fn shuffleSlice(rng: anytype, values: []u32) static_rng.distributions.DistributionError!void {
    std.debug.assert(values.len == shuffle_len);
    if (values.len <= 1) return;

    var index = values.len - 1;
    while (true) {
        const chosen64 = try static_rng.distributions.uintBelow(rng, @intCast(index + 1));
        const chosen: usize = @intCast(chosen64);
        std.debug.assert(chosen <= index);
        if (chosen != index) {
            std.mem.swap(u32, &values[index], &values[chosen]);
        }
        if (index == 0) break;
        index -= 1;
    }
    std.debug.assert(values.len == shuffle_len);
    std.debug.assert(values[0] < @as(u32, @intCast(shuffle_len)));
}

pub const ReferencePcg32 = struct {
    state: u64,
    inc: u64,

    pub fn init(seed: u64, sequence: u64) ReferencePcg32 {
        var result = ReferencePcg32{
            .state = 0,
            .inc = (sequence << 1) | 1,
        };
        _ = result.nextU32();
        result.state +%= seed;
        _ = result.nextU32();
        std.debug.assert((result.inc & 1) == 1);
        std.debug.assert(result.state != 0 or seed == 0);
        return result;
    }

    pub fn nextU32(self: *ReferencePcg32) u32 {
        std.debug.assert((self.inc & 1) == 1);
        const old_state = self.state;
        self.state = old_state *% 6364136223846793005 +% self.inc;
        const xorshifted: u32 = @truncate(((old_state >> 18) ^ old_state) >> 27);
        const rot: u5 = @truncate(old_state >> 59);
        const result = rotateRight32(xorshifted, rot);
        std.debug.assert((self.inc & 1) == 1);
        std.debug.assert(self.state != old_state or self.inc != 1);
        return result;
    }

    pub fn nextU64(self: *ReferencePcg32) u64 {
        const hi = @as(u64, self.nextU32());
        const lo = @as(u64, self.nextU32());
        const result = (hi << 32) | lo;
        std.debug.assert(self.inc != 0);
        std.debug.assert(result == ((hi << 32) | lo));
        return result;
    }

    pub fn split(self: *ReferencePcg32) ReferencePcg32 {
        const parent_state = self.state;
        const parent_inc = self.inc;
        const child_seed = self.nextU64();
        const child_sequence = self.nextU64() | 1;
        const child = init(child_seed, child_sequence);
        std.debug.assert(self.state != parent_state or self.inc != parent_inc);
        std.debug.assert((child.inc & 1) == 1);
        return child;
    }

    fn rotateRight32(value: u32, count: u5) u32 {
        if (count == 0) return value;
        return (value >> count) | (value << @as(u5, (0 -% count) & 31));
    }
};

pub const ReferenceSplitMix64 = struct {
    state: u64,

    pub fn init(seed: u64) ReferenceSplitMix64 {
        const result = ReferenceSplitMix64{ .state = seed };
        std.debug.assert(result.state == seed);
        std.debug.assert(result.state ^ seed == 0);
        return result;
    }

    pub fn next(self: *ReferenceSplitMix64) u64 {
        const previous_state = self.state;
        self.state +%= 0x9e37_79b9_7f4a_7c15;
        var z = self.state;
        z ^= z >> 30;
        z *%= 0xbf58_476d_1ce4_e5b9;
        z ^= z >> 27;
        z *%= 0x94d0_49bb_1331_11eb;
        z ^= z >> 31;
        std.debug.assert(self.state == previous_state +% 0x9e37_79b9_7f4a_7c15);
        std.debug.assert(self.state != previous_state);
        return z;
    }
};

pub const ReferenceXoroshiro128Plus = struct {
    s0: u64,
    s1: u64,

    pub fn init(seed: u64) ReferenceXoroshiro128Plus {
        var seeder = ReferenceSplitMix64.init(seed);
        const s0 = seeder.next();
        var s1 = seeder.next();
        if (s0 == 0 and s1 == 0) {
            s1 = 1;
        }
        std.debug.assert(s0 != 0 or s1 != 0);
        std.debug.assert(s1 != 0 or s0 != 0);
        return .{
            .s0 = s0,
            .s1 = s1,
        };
    }

    pub fn nextU64(self: *ReferenceXoroshiro128Plus) u64 {
        const before = self.*;
        const result = self.s0 +% self.s1;
        const mixed = self.s1 ^ self.s0;
        self.s0 = rotl64(self.s0, 55) ^ mixed ^ (mixed << 14);
        self.s1 = rotl64(mixed, 36);
        std.debug.assert(result == before.s0 +% before.s1);
        std.debug.assert(self.s0 != 0 or self.s1 != 0);
        std.debug.assert(self.s0 != before.s0 or self.s1 != before.s1);
        return result;
    }

    pub fn jump(self: *ReferenceXoroshiro128Plus) void {
        std.debug.assert(self.s0 != 0 or self.s1 != 0);
        const before = self.*;
        const jump_constants = [_]u64{
            0xbeac_0467_eba5_facb,
            0xd86b_048b_86aa_9922,
        };

        var next_s0: u64 = 0;
        var next_s1: u64 = 0;
        for (jump_constants) |constant| {
            var bit: usize = 0;
            while (bit < 64) : (bit += 1) {
                const shift: u6 = @intCast(bit);
                if (((constant >> shift) & 1) == 1) {
                    next_s0 ^= self.s0;
                    next_s1 ^= self.s1;
                }
                _ = self.nextU64();
            }
        }

        self.s0 = next_s0;
        self.s1 = next_s1;
        std.debug.assert(self.s0 != before.s0 or self.s1 != before.s1);
        std.debug.assert(self.s0 != 0 or self.s1 != 0);
    }

    pub fn split(self: *ReferenceXoroshiro128Plus) ReferenceXoroshiro128Plus {
        const child_start = self.*;
        self.jump();
        std.debug.assert(self.s0 != child_start.s0 or self.s1 != child_start.s1);
        std.debug.assert(self.s0 != 0 or self.s1 != 0);
        return child_start;
    }

    fn rotl64(value: u64, count: u6) u64 {
        if (count == 0) return value;
        return (value << count) | (value >> @as(u6, (0 -% count) & 63));
    }
};
