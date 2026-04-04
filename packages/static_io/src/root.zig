//! `static_io` package root.
//!
//! Deterministic bounded I/O runtime primitives with explicit backend selection.

pub const core = @import("static_core");
pub const memory = @import("static_memory");
pub const net_native = @import("static_net_native");
pub const queues = @import("static_queues");

pub const types = @import("io/types.zig");
pub const config = @import("io/config.zig");
pub const caps = @import("io/caps.zig");
pub const buffer_pool = @import("io/buffer_pool.zig");
pub const backend = @import("io/backend.zig");
pub const fake_backend = @import("io/fake_backend.zig");
pub const threaded_backend = @import("io/threaded_backend.zig");
pub const runtime = @import("io/runtime.zig");
pub const platform = @import("io/platform/selected_backend.zig");

pub const Buffer = types.Buffer;
pub const Operation = types.Operation;
pub const Completion = types.Completion;
pub const CapabilityFlags = types.CapabilityFlags;
pub const Handle = types.Handle;
pub const NativeHandle = types.NativeHandle;
pub const HandleKind = types.HandleKind;
pub const File = types.File;
pub const Stream = types.Stream;
pub const Listener = types.Listener;
pub const Endpoint = types.Endpoint;
pub const Ownership = runtime.Ownership;
pub const RuntimeConfig = config.Config;
pub const Runtime = runtime.Runtime;
pub const BufferPool = buffer_pool.BufferPool;

test {
    _ = core;
    _ = memory;
    _ = net_native;
    _ = queues;
    _ = types;
    _ = config;
    _ = caps;
    _ = buffer_pool;
    _ = backend;
    _ = fake_backend;
    _ = threaded_backend;
    _ = runtime;
    _ = platform;
}
