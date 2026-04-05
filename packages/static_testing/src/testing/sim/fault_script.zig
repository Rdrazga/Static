//! Deterministic fault schedule storage and due-fault lookup.

const std = @import("std");
const testing = std.testing;
const clock = @import("clock.zig");

/// Public fault script operating errors.
pub const FaultScriptError = error{
    InvalidConfig,
};

/// Generic fault categories copied from the capability sketch.
pub const FaultKind = enum(u8) {
    drop = 1,
    delay = 2,
    reorder = 3,
    duplicate = 4,
    corrupt = 5,
    pause = 6,
    crash = 7,
    recover = 8,
};

/// A single deterministic fault script entry.
pub const FaultEvent = struct {
    time: clock.LogicalTime,
    kind: FaultKind,
    target_id: u32,
    value: u64 = 0,
};

/// Immutable fault script view plus deterministic cursor.
pub const FaultScript = struct {
    events: []const FaultEvent,
    next_index: usize = 0,

    /// Validate one script and construct a cursor positioned at the first event.
    pub fn init(events: []const FaultEvent) FaultScriptError!FaultScript {
        try validateScript(events);
        return .{ .events = events };
    }

    /// Rewind the cursor so the script can be replayed from the beginning.
    pub fn reset(self: *FaultScript) void {
        self.next_index = 0;
    }

    /// View all faults that are due at or before `now_time` without advancing.
    pub fn peekDueAt(self: *const FaultScript, now_time: clock.LogicalTime) []const FaultEvent {
        const due_end_index = findDueEndIndex(self, now_time);
        return self.events[self.next_index..due_end_index];
    }

    /// Report the next scheduled fault time without advancing the cursor.
    pub fn peekNextTime(self: *const FaultScript) ?clock.LogicalTime {
        if (self.next_index >= self.events.len) return null;
        return self.events[self.next_index].time;
    }

    /// Report the next scheduled fault time after all currently due faults.
    pub fn peekNextTimeAfter(self: *const FaultScript, now_time: clock.LogicalTime) ?clock.LogicalTime {
        const due_end_index = findDueEndIndex(self, now_time);
        if (due_end_index >= self.events.len) return null;
        return self.events[due_end_index].time;
    }

    /// Return all currently due faults and advance the cursor past them.
    pub fn nextFaultsAt(
        self: *FaultScript,
        now_time: clock.LogicalTime,
    ) []const FaultEvent {
        const start_index = self.next_index;
        self.next_index = findDueEndIndex(self, now_time);
        return self.events[start_index..self.next_index];
    }
};

/// Validate monotonic ordering for a fault script.
pub fn validateScript(events: []const FaultEvent) FaultScriptError!void {
    var index: usize = 1;
    while (index < events.len) : (index += 1) {
        if (events[index].time.tick < events[index - 1].time.tick) {
            return error.InvalidConfig;
        }
    }
}

fn findDueEndIndex(self: *const FaultScript, now_time: clock.LogicalTime) usize {
    var due_end_index = self.next_index;
    while (due_end_index < self.events.len and self.events[due_end_index].time.tick <= now_time.tick) {
        due_end_index += 1;
    }
    return due_end_index;
}

test "fault script rejects non-monotonic time ordering" {
    const events = [_]FaultEvent{
        .{ .time = .init(2), .kind = .drop, .target_id = 1 },
        .{ .time = .init(1), .kind = .recover, .target_id = 1 },
    };
    try testing.expectError(error.InvalidConfig, FaultScript.init(&events));
}

test "fault script returns all due events at and before the current time" {
    const events = [_]FaultEvent{
        .{ .time = .init(1), .kind = .drop, .target_id = 1 },
        .{ .time = .init(1), .kind = .duplicate, .target_id = 2 },
        .{ .time = .init(3), .kind = .recover, .target_id = 1 },
    };
    var script = try FaultScript.init(&events);

    const due_tick_1 = script.nextFaultsAt(.init(1));
    try testing.expectEqual(@as(usize, 2), due_tick_1.len);
    try testing.expectEqual(FaultKind.drop, due_tick_1[0].kind);

    const due_tick_3 = script.nextFaultsAt(.init(3));
    try testing.expectEqual(@as(usize, 1), due_tick_3.len);
    try testing.expectEqual(FaultKind.recover, due_tick_3[0].kind);
}
