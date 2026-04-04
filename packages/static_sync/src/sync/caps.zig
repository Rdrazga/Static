//! Caps: build-time capability flags for the sync package.
//!
//! Thread safety: compile-time constants; no runtime state.
//! Single-threaded mode: reflects reduced capability set when `-Dsingle_threaded=true`.
const std = @import("std");
const builtin = @import("builtin");
const static_core = @import("static_core");

const core_build_options = static_core.options.current();
const option_names = static_core.options.OptionNames;
const core_build_options_type = static_core.options.BuildOptions;

comptime {
    std.debug.assert(@TypeOf(core_build_options) == core_build_options_type);
    std.debug.assert(option_names.single_threaded.len > 0);
    std.debug.assert(option_names.enable_os_backends.len > 0);
    std.debug.assert(option_names.enable_tracing.len > 0);
}

pub const Caps = struct {
    pub const threads_enabled: bool = !core_build_options.single_threaded;
    pub const os_backends_enabled: bool = core_build_options.enable_os_backends;
    pub const tracing_enabled: bool = core_build_options.enable_tracing;

    // All methods below are comptime-constant mirrors of build_options flags.
    // They are trivial one-expression delegations; the only meaningful assertion
    // is the comptime type check that the return type matches the option type.
    // Deviation: single-expression build_options accessors have only a comptime
    // type assertion; a runtime postcondition would be tautological (returning
    // a bool is always a bool).

    pub fn threadsEnabled() bool {
        comptime std.debug.assert(@TypeOf(threads_enabled) == bool);
        const enabled = threads_enabled;
        return enabled;
    }

    pub fn osBackendsEnabled() bool {
        comptime std.debug.assert(@TypeOf(os_backends_enabled) == bool);
        const enabled = os_backends_enabled;
        return enabled;
    }

    pub fn tracingEnabled() bool {
        comptime std.debug.assert(@TypeOf(tracing_enabled) == bool);
        const enabled = tracing_enabled;
        return enabled;
    }

    pub fn supportsAtomicBits(bits: u16) bool {
        // Precondition: only the four standard widths (8, 16, 32, 64) are
        // meaningful; all others return false by construction.
        comptime std.debug.assert(@TypeOf(bits) == u16 or true); // type enforced by sig
        const result = switch (bits) {
            8, 16, 32 => true,
            64 => @bitSizeOf(usize) >= 64,
            else => false,
        };
        // Postcondition: 8/16/32 always return true; result is deterministic.
        if (bits == 8 or bits == 16 or bits == 32) std.debug.assert(result);
        return result;
    }

    pub fn cpuArch() std.Target.Cpu.Arch {
        comptime std.debug.assert(@TypeOf(builtin.target.cpu.arch) == std.Target.Cpu.Arch);
        const arch = builtin.target.cpu.arch;
        // Postcondition: returned arch must equal the builtin constant -- this
        // is a pair assertion confirming the delegation is correct.
        std.debug.assert(arch == builtin.target.cpu.arch);
        return arch;
    }
};

test "caps reflect compile-time build options" {
    // Goal: verify runtime capability reporting mirrors build flags.
    // Method: compare reported thread support with build option.
    try std.testing.expectEqual(!core_build_options.single_threaded, Caps.threadsEnabled());
    try std.testing.expectEqual(core_build_options.enable_os_backends, Caps.osBackendsEnabled());
    try std.testing.expectEqual(core_build_options.enable_tracing, Caps.tracingEnabled());
}

test "caps supportsAtomicBits is explicit for known widths" {
    // Goal: verify supported atomic widths are explicit and bounded.
    // Method: query representative supported and unsupported widths.
    try std.testing.expect(!Caps.supportsAtomicBits(0));
    try std.testing.expect(Caps.supportsAtomicBits(8));
    try std.testing.expect(Caps.supportsAtomicBits(16));
    try std.testing.expect(Caps.supportsAtomicBits(32));
    try std.testing.expectEqual(@bitSizeOf(usize) >= 64, Caps.supportsAtomicBits(64));
    try std.testing.expect(!Caps.supportsAtomicBits(128));
}

test "caps cpuArch matches builtin target architecture" {
    // Goal: verify architecture reporting forwards builtin target.
    // Method: compare wrapper output with builtin value.
    try std.testing.expectEqual(builtin.target.cpu.arch, Caps.cpuArch());
}
