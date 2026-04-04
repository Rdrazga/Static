//! static_simd — Portable SIMD lane-vector types and helpers.
//!
//! Provides explicit, width-typed operations across float and integer element
//! types, plus supporting modules for memory access, reductions, comparisons,
//! shuffles, and elementwise math. Built on Zig `@Vector` with a scalar
//! baseline always available.
//!
//! Package boundary:
//! - `static_simd` owns lane-parallel execution helpers and SIMD-specific policy;
//! - `static_math` owns geometry, matrix/quaternion algebra, and scalar math conventions.
//! Keep this package narrow unless a real downstream consumer proves broader SIMD surface is worth owning.
//! Width-specific wrapper modules and width-suffixed aliases are compatibility
//! surface, not a growth target. New parallel entry points stay frozen until a
//! real consumer shows that the added API carries its weight.
//!
//! Key modules: `vec_type` (generic factory), `math`, `compare`, `horizontal`,
//! `shuffle`, `trig`, `memory`, `gather_scatter`.
//! Key types: `Vec2f`, `Vec4f`, `Vec8f`, `Vec16f`, `Vec4d`, `Vec2i`, `Vec4i`,
//! `Vec8i`, `Vec4u`, `Mask2`, `Mask4`, `Mask8`, `Mask16`.
//! Thread safety: all vector operations are pure functions with no shared state.

// -- Platform detection --
pub const platform = @import("simd/platform.zig");

// -- Vector types --
pub const vec_type = @import("simd/vec_type.zig");
pub const vec2f = @import("simd/vec2f.zig");
pub const vec4f = @import("simd/vec4f.zig");
pub const vec8f = @import("simd/vec8f.zig");
pub const vec16f = @import("simd/vec16f.zig");
pub const vec4d = @import("simd/vec4d.zig");
pub const vec2i = @import("simd/vec2i.zig");
pub const vec4i = @import("simd/vec4i.zig");
pub const vec8i = @import("simd/vec8i.zig");
pub const vec4u = @import("simd/vec4u.zig");

// -- Masks --
pub const masked = @import("simd/masked.zig");

// -- Operations --
pub const memory = @import("simd/memory.zig");
pub const gather_scatter = @import("simd/gather_scatter.zig");
pub const compare = @import("simd/compare.zig");
pub const horizontal = @import("simd/horizontal.zig");
pub const math = @import("simd/math.zig");
pub const trig = @import("simd/trig.zig");
pub const shuffle = @import("simd/shuffle.zig");

test {
    _ = platform;
    _ = vec_type;
    _ = vec2f;
    _ = vec4f;
    _ = vec8f;
    _ = vec16f;
    _ = vec4d;
    _ = vec2i;
    _ = vec4i;
    _ = vec8i;
    _ = vec4u;
    _ = masked;
    _ = memory;
    _ = gather_scatter;
    _ = compare;
    _ = horizontal;
    _ = math;
    _ = trig;
    _ = shuffle;
}
