//! Bounded deterministic reassembly of out-of-order effects into one stable sequence.

const std = @import("std");

pub const InsertStatus = enum(u8) {
    accepted = 1,
    duplicate_ignored = 2,
    stale = 3,
    no_space = 4,
};

pub const SequencerStatus = struct {
    pending_count: usize,
    free: usize,
    lowest_buffered_sequence_no: ?u64 = null,
    highest_buffered_sequence_no: ?u64 = null,
};

pub fn OrderedEffectSequencer(comptime T: type, comptime capacity: usize) type {
    comptime {
        std.debug.assert(capacity > 0);
    }

    return struct {
        const Self = @This();

        pub const ReadyEffect = struct {
            sequence_no: u64,
            effect: T,
        };

        entries: [capacity]ReadyEffect = undefined,
        pending_count: usize = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn reset(self: *Self) void {
            std.debug.assert(self.pending_count <= capacity);
            self.pending_count = 0;
            std.debug.assert(self.pending_count == 0);
        }

        pub fn insert(
            self: *Self,
            next_expected_sequence_no: u64,
            sequence_no: u64,
            effect: T,
        ) InsertStatus {
            std.debug.assert(self.pending_count <= capacity);
            if (sequence_no < next_expected_sequence_no) return .stale;
            if (self.contains(sequence_no)) return .duplicate_ignored;
            if (self.pending_count == capacity) return .no_space;

            const insert_index = self.lowerBound(sequence_no);
            var cursor = self.pending_count;
            while (cursor > insert_index) : (cursor -= 1) {
                self.entries[cursor] = self.entries[cursor - 1];
            }
            self.entries[insert_index] = .{
                .sequence_no = sequence_no,
                .effect = effect,
            };
            self.pending_count += 1;
            std.debug.assert(self.pending_count <= capacity);
            return .accepted;
        }

        pub fn contains(self: *const Self, sequence_no: u64) bool {
            std.debug.assert(self.pending_count <= capacity);
            return self.findIndex(sequence_no) != null;
        }

        pub fn peekReady(
            self: *const Self,
            next_expected_sequence_no: u64,
        ) ?*const ReadyEffect {
            std.debug.assert(self.pending_count <= capacity);
            if (self.pending_count == 0) return null;
            const first = &self.entries[0];
            if (first.sequence_no != next_expected_sequence_no) return null;
            return first;
        }

        pub fn popReady(
            self: *Self,
            next_expected_sequence_no: *u64,
        ) ?ReadyEffect {
            std.debug.assert(self.pending_count <= capacity);
            const ready = self.peekReady(next_expected_sequence_no.*) orelse return null;
            const result = ready.*;

            var index: usize = 1;
            while (index < self.pending_count) : (index += 1) {
                self.entries[index - 1] = self.entries[index];
            }
            self.pending_count -= 1;
            next_expected_sequence_no.* += 1;
            std.debug.assert(self.pending_count <= capacity);
            return result;
        }

        pub fn pendingCount(self: *const Self) usize {
            std.debug.assert(self.pending_count <= capacity);
            return self.pending_count;
        }

        pub fn free(self: *const Self) usize {
            std.debug.assert(self.pending_count <= capacity);
            return capacity - self.pending_count;
        }

        pub fn status(self: *const Self) SequencerStatus {
            std.debug.assert(self.pending_count <= capacity);
            return .{
                .pending_count = self.pending_count,
                .free = self.free(),
                .lowest_buffered_sequence_no = if (self.pending_count == 0) null else self.entries[0].sequence_no,
                .highest_buffered_sequence_no = if (self.pending_count == 0) null else self.entries[self.pending_count - 1].sequence_no,
            };
        }

        fn lowerBound(self: *const Self, sequence_no: u64) usize {
            std.debug.assert(self.pending_count <= capacity);
            var index: usize = 0;
            while (index < self.pending_count) : (index += 1) {
                if (self.entries[index].sequence_no >= sequence_no) return index;
            }
            return self.pending_count;
        }

        fn findIndex(self: *const Self, sequence_no: u64) ?usize {
            std.debug.assert(self.pending_count <= capacity);
            var index: usize = 0;
            while (index < self.pending_count) : (index += 1) {
                const candidate = self.entries[index].sequence_no;
                if (candidate == sequence_no) return index;
                if (candidate > sequence_no) return null;
            }
            return null;
        }
    };
}

test "ordered effect sequencer buffers out-of-order effects and releases them in sequence" {
    var sequencer = OrderedEffectSequencer(u32, 4).init();
    var next_expected: u64 = 0;

    try std.testing.expectEqual(InsertStatus.accepted, sequencer.insert(next_expected, 1, 22));
    try std.testing.expectEqual(@as(?*const OrderedEffectSequencer(u32, 4).ReadyEffect, null), sequencer.peekReady(next_expected));

    try std.testing.expectEqual(InsertStatus.accepted, sequencer.insert(next_expected, 0, 11));
    try std.testing.expectEqual(@as(u64, 0), sequencer.peekReady(next_expected).?.sequence_no);
    try std.testing.expectEqual(@as(u32, 11), sequencer.peekReady(next_expected).?.effect);

    const first = sequencer.popReady(&next_expected).?;
    try std.testing.expectEqual(@as(u64, 0), first.sequence_no);
    try std.testing.expectEqual(@as(u32, 11), first.effect);
    try std.testing.expectEqual(@as(u64, 1), next_expected);

    const second = sequencer.popReady(&next_expected).?;
    try std.testing.expectEqual(@as(u64, 1), second.sequence_no);
    try std.testing.expectEqual(@as(u32, 22), second.effect);
    try std.testing.expectEqual(@as(u64, 2), next_expected);
    try std.testing.expectEqual(@as(usize, 0), sequencer.pendingCount());
}

test "ordered effect sequencer ignores duplicates and stale inserts explicitly" {
    var sequencer = OrderedEffectSequencer(u8, 3).init();
    var next_expected: u64 = 4;

    try std.testing.expectEqual(InsertStatus.accepted, sequencer.insert(next_expected, 5, 55));
    try std.testing.expectEqual(InsertStatus.duplicate_ignored, sequencer.insert(next_expected, 5, 99));
    try std.testing.expectEqual(InsertStatus.stale, sequencer.insert(next_expected, 3, 33));

    try std.testing.expect(sequencer.contains(5));
    try std.testing.expect(!sequencer.contains(4));

    try std.testing.expectEqual(@as(?OrderedEffectSequencer(u8, 3).ReadyEffect, null), sequencer.popReady(&next_expected));
    try std.testing.expectEqual(InsertStatus.accepted, sequencer.insert(next_expected, 4, 44));
    const ready = sequencer.popReady(&next_expected).?;
    try std.testing.expectEqual(@as(u64, 4), ready.sequence_no);
    try std.testing.expectEqual(@as(u8, 44), ready.effect);
}

test "ordered effect sequencer reports capacity pressure and bounded status" {
    var sequencer = OrderedEffectSequencer(u16, 2).init();
    const next_expected: u64 = 10;

    try std.testing.expectEqual(InsertStatus.accepted, sequencer.insert(next_expected, 12, 120));
    try std.testing.expectEqual(InsertStatus.accepted, sequencer.insert(next_expected, 10, 100));
    try std.testing.expectEqual(InsertStatus.no_space, sequencer.insert(next_expected, 11, 110));

    const status = sequencer.status();
    try std.testing.expectEqual(@as(usize, 2), status.pending_count);
    try std.testing.expectEqual(@as(usize, 0), status.free);
    try std.testing.expectEqual(@as(?u64, 10), status.lowest_buffered_sequence_no);
    try std.testing.expectEqual(@as(?u64, 12), status.highest_buffered_sequence_no);

    sequencer.reset();
    try std.testing.expectEqual(@as(usize, 0), sequencer.pendingCount());
    try std.testing.expectEqual(@as(usize, 2), sequencer.free());
}
