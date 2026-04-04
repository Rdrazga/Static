//! static_math — Linear algebra types for games, graphics, physics, and UI.
//!
//! Conventions (RFC-0053):
//!   - Coordinate system: right-handed. +X right, +Y up, -Z forward.
//!   - Matrix storage: column-major. `cols[0]` is the first column.
//!   - Matrix-vector multiply: column-vector convention (`v' = M * v`).
//!   - Projection depth range: [0, 1] (Vulkan/Metal/DX12).
//!   - Angles: radians everywhere.
//!   - Rotation direction: counter-clockwise looking down the axis toward origin.
//!   - Quaternion storage: (x, y, z, w) where w is the scalar part. Hamilton product.
//!   - Transform order: Scale -> Rotate -> Translate (SRT). Matrix: T * R * S.
//!
//! All types are `extern struct` for layout stability and C ABI compatibility.
//! All operations are pure, allocation-free, and deterministic (no hidden
//! time, RNG, or OS calls).
//!
//! Root exports stay centered on convention-bearing types. Scalar wrappers that
//! overlap heavily with `std.math` remain under `static_math.scalar` instead of
//! expanding the package root into a general-purpose numeric helper bag.
//!
//! ## Validation policy (§3.10.1)
//!
//! **Preconditions** (non-zero divisors, normalized inputs, etc.) are enforced
//! via `std.debug.assert` — these are programmer errors per §3.10.1.
//!
//! **`tryNormalize`** and similar `try*` variants return `?T` for boundary-
//! facing code that operates on external/untrusted data. Internal code should
//! use the asserting versions exclusively.

pub const scalar = @import("math/scalar.zig");
pub const vec2 = @import("math/vec2.zig");
pub const vec3 = @import("math/vec3.zig");
pub const vec4 = @import("math/vec4.zig");
pub const mat3 = @import("math/mat3.zig");
pub const mat4 = @import("math/mat4.zig");
pub const quat = @import("math/quat.zig");
pub const transform = @import("math/transform.zig");

// Re-export primary types for convenience.
pub const Vec2 = vec2.Vec2;
pub const Vec3 = vec3.Vec3;
pub const Vec4 = vec4.Vec4;
pub const Mat3 = mat3.Mat3;
pub const Mat4 = mat4.Mat4;
pub const Quat = quat.Quat;
pub const Transform = transform.Transform;

// Re-export only the scalar items that directly teach package conventions.
pub const pi = scalar.pi;
pub const tau = scalar.tau;
pub const epsilon = scalar.epsilon;
pub const toRadians = scalar.toRadians;
pub const toDegrees = scalar.toDegrees;

test {
    _ = scalar;
    _ = vec2;
    _ = vec3;
    _ = vec4;
    _ = mat3;
    _ = mat4;
    _ = quat;
    _ = transform;
}
