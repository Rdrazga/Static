const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const posix = std.posix;
const windows = std.os.windows;

pub const Instant = struct {
    timestamp: if (is_posix) posix.timespec else u64,

    const is_posix = switch (builtin.os.tag) {
        .windows, .uefi, .wasi => false,
        else => true,
    };

    pub fn now() error{Unsupported}!Instant {
        const clock_id = switch (builtin.os.tag) {
            .windows => return .{ .timestamp = queryPerformanceCounter() },
            .wasi => {
                var ns: std.os.wasi.timestamp_t = undefined;
                const rc = std.os.wasi.clock_time_get(.MONOTONIC, 1, &ns);
                if (rc != .SUCCESS) return error.Unsupported;
                return .{ .timestamp = ns };
            },
            .uefi => {
                const value, _ = std.os.uefi.system_table.runtime_services.getTime() catch return error.Unsupported;
                return .{ .timestamp = value.toEpoch() };
            },
            .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => posix.CLOCK.UPTIME_RAW,
            .freebsd, .dragonfly => posix.CLOCK.MONOTONIC_FAST,
            .linux => posix.CLOCK.BOOTTIME,
            else => posix.CLOCK.MONOTONIC,
        };

        const ts = posix.clock_gettime(clock_id) catch return error.Unsupported;
        return .{ .timestamp = ts };
    }

    pub fn order(self: Instant, other: Instant) std.math.Order {
        if (!is_posix) return std.math.order(self.timestamp, other.timestamp);

        var ord = std.math.order(self.timestamp.sec, other.timestamp.sec);
        if (ord == .eq) ord = std.math.order(self.timestamp.nsec, other.timestamp.nsec);
        return ord;
    }

    pub fn since(self: Instant, earlier: Instant) u64 {
        switch (builtin.os.tag) {
            .windows => {
                const qpc = self.timestamp - earlier.timestamp;
                const qpf = queryPerformanceFrequency();
                const common_qpf = 10_000_000;
                if (qpf == common_qpf) return qpc * (std.time.ns_per_s / common_qpf);

                const scale = @as(u64, std.time.ns_per_s << 32) / @as(u32, @intCast(qpf));
                const result = (@as(u96, qpc) * scale) >> 32;
                return @as(u64, @truncate(result));
            },
            .uefi, .wasi => return self.timestamp - earlier.timestamp,
            else => {
                const seconds = @as(u64, @intCast(self.timestamp.sec - earlier.timestamp.sec));
                const elapsed = (seconds * std.time.ns_per_s) + @as(u32, @intCast(self.timestamp.nsec));
                return elapsed - @as(u32, @intCast(earlier.timestamp.nsec));
            },
        }
    }
};

fn queryPerformanceCounter() u64 {
    var qpc: windows.LARGE_INTEGER = undefined;
    assert(windows.ntdll.RtlQueryPerformanceCounter(&qpc).toBool());
    return @bitCast(qpc);
}

fn queryPerformanceFrequency() u64 {
    var qpf: windows.LARGE_INTEGER = undefined;
    assert(windows.ntdll.RtlQueryPerformanceFrequency(&qpf).toBool());
    return @bitCast(qpf);
}

pub const Timer = struct {
    started: Instant,
    previous: Instant,

    pub const Error = error{TimerUnsupported};

    pub fn start() Error!Timer {
        const current = Instant.now() catch return error.TimerUnsupported;
        return .{ .started = current, .previous = current };
    }

    pub fn read(self: *Timer) u64 {
        const current = self.sample();
        return current.since(self.started);
    }

    pub fn reset(self: *Timer) void {
        self.started = self.sample();
    }

    pub fn lap(self: *Timer) u64 {
        const current = self.sample();
        defer self.started = current;
        return current.since(self.started);
    }

    fn sample(self: *Timer) Instant {
        const current = Instant.now() catch unreachable;
        if (current.order(self.previous) == .gt) self.previous = current;
        return self.previous;
    }
};

test "time compat timer reads monotonic deltas" {
    var timer = try Timer.start();
    _ = timer.read();
    const later = timer.read();
    assert(later <= std.math.maxInt(u64));
}
