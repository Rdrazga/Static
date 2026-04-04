//! static_meta - Type identity and bounded registry utilities.
//!
//! This package separates runtime identity from durable stable identity:
//! - Runtime identity is derived from `@typeName(T)` and is useful for in-process registries.
//! - Stable identity is opt-in through `static_name` + `static_version`.
//!
//! `TypeRegistry` is intentionally small: caller-provided storage, append-only
//! registration order, and linear lookup until a real consumer proves that more
//! indexing complexity is warranted.
//!
//! All APIs are allocation-free and deterministic.

pub const type_name = @import("meta/type_name.zig");
pub const type_id = @import("meta/type_id.zig");
pub const type_fingerprint = @import("meta/type_fingerprint.zig");
pub const type_registry = @import("meta/type_registry.zig");

pub const StableIdentity = type_name.StableIdentity;
pub const TypeId = type_id.TypeId;
pub const TypeFingerprint64 = type_fingerprint.TypeFingerprint64;
pub const TypeFingerprint128 = type_fingerprint.TypeFingerprint128;
pub const Entry = type_registry.Entry;
pub const RegistryError = type_registry.RegistryError;
pub const TypeRegistry = type_registry.TypeRegistry;

test {
    _ = type_name;
    _ = type_id;
    _ = type_fingerprint;
    _ = type_registry;
}
