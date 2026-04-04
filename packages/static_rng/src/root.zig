//! static_rng: deterministic pseudo-random number engines and helpers.
//!
//! Key types: `Pcg32`, `SplitMix64`, `Xoroshiro128Plus`, `DistributionError`.
//! Key functions: `shuffleSlice`.
//!
//! Package posture:
//! - keep this as a curated deterministic RNG layer for simulation, tests, and
//!   bounded helper operations;
//! - do not broaden it into a general random toolkit while std already covers
//!   a wider algorithm catalog and there are not yet real downstream consumers.
//!
//! All engines hold their state explicitly; there is no global RNG state.
//! Generators are seeded with a u64 value and an optional stream selector.
//! Use `split` or `jump` on an existing generator to derive independent
//! parallel streams without overlap.
//!
//! Choosing a generator:
//! - `Pcg32`: 32-bit output, multiple independent streams via sequence param.
//!   Best for reproducible per-object seeds with distinct stream IDs.
//! - `SplitMix64`: fastest; use only for seeding `Xoroshiro128Plus`.
//! - `Xoroshiro128Plus`: 64-bit output, high throughput, best for simulations.
//!
//! None of these generators are cryptographically secure.
//! Thread safety: no instance is thread-safe; use one instance per thread.

pub const splitmix64 = @import("rng/splitmix64.zig");
pub const pcg32 = @import("rng/pcg32.zig");
pub const xoroshiro128plus = @import("rng/xoroshiro128plus.zig");
pub const distributions = @import("rng/distributions.zig");
pub const shuffle = @import("rng/shuffle.zig");

pub const SplitMix64 = splitmix64.SplitMix64;
pub const Pcg32 = pcg32.Pcg32;
pub const Xoroshiro128Plus = xoroshiro128plus.Xoroshiro128Plus;
pub const DistributionError = distributions.DistributionError;
pub const shuffleSlice = shuffle.shuffleSlice;

test {
    _ = splitmix64;
    _ = pcg32;
    _ = xoroshiro128plus;
    _ = distributions;
    _ = shuffle;
}
