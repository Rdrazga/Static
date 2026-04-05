//! Bounded deterministic reassembly of out-of-order effects into one stable sequence.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

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
        assert(capacity > 0);
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
            assert(self.pending_count <= capacity);
            self.pending_count = 0;
            assert(self.pending_count == 0);
        }

        pub fn insert(
            self: *Self,
            next_expected_sequence_no: u64,
            sequence_no: u64,
            effect: T,
        ) InsertStatus {
            assert(self.pending_count <= capacity);
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
            assert(self.pending_count <= capacity);
            return .accepted;
        }

        pub fn contains(self: *const Self, sequence_no: u64) bool {
            assert(self.pending_count <= capacity);
            return self.findIndex(sequence_no) != null;
        }

        pub fn peekReady(
            self: *const Self,
            next_expected_sequence_no: u64,
        ) ?*const ReadyEffect {
            assert(self.pending_count <= capacity);
            if (self.pending_count == 0) return null;
            const first = &self.entries[0];
            if (first.sequence_no != next_expected_sequence_no) return null;
            return first;
        }

        pub fn popReady(
            self: *Self,
            next_expected_sequence_no: *u64,
        ) ?ReadyEffect {
            assert(self.pending_count <= capacity);
            const ready = self.peekReady(next_expected_sequence_no.*) orelse return null;
            const result = ready.*;

            var index: usize = 1;
            while (index < self.pending_count) : (index += 1) {
                self.entries[index - 1] = self.entries[index];
            }
            self.pending_count -= 1;
            next_expected_sequence_no.* += 1;
            assert(self.pending_count <= capacity);
            return result;
        }

        pub fn pendingCount(self: *const Self) usize {
            assert(self.pending_count <= capacity);
            return self.pending_count;
        }

        pub fn free(self: *const Self) usize {
            assert(self.pending_count <= capacity);
            return capacity - self.pending_count;
        }

        pub fn status(self: *const Self) SequencerStatus {
            assert(self.pending_count <= capacity);
            return .{
                .pending_count = self.pending_count,
                .free = self.free(),
                .lowest_buffered_sequence_no = if (self.pending_count == 0) null else self.entries[0].sequence_no,
                .highest_buffered_sequence_no = if (self.pending_count == 0) null else self.entries[self.pending_count - 1].sequence_no,
            };
        }

        fn lowerBound(self: *const Self, sequence_no: u64) usize {
            assert(self.pending_count <= capacity);
            var index: usize = 0;
            while (index < self.pending_count) : (index += 1) {
                if (self.entries[index].sequence_no >= sequence_no) return index;
            }
            return self.pending_count;
        }

        fn findIndex(self: *const Self, sequence_no: u64) ?usize {
            assert(self.pending_count <= capacity);
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

    try testing.expectEqual(InsertStatus.accepted, sequencer.insert(next_expected, 1, 22));
    try testing.expectEqual(@as(?*const OrderedEffectSequencer(u32, 4).ReadyEffect, null), sequencer.peekReady(next_expected));

    try testing.expectEqual(InsertStatus.accepted, sequencer.insert(next_expected, 0, 11));
    try testing.expectEqual(@as(u64, 0), sequencer.peekReady(next_expected).?.sequence_no);
    try testing.expectEqual(@as(u32, 11), sequencer.peekReady(next_expected).?.effect);

    const first = sequencer.popReady(&next_expected).?;
    try testing.expectEqual(@as(u64, 0), first.sequence_no);
    try testing.expectEqual(@as(u32, 11), first.effect);
    try testing.expectEqual(@as(u64, 1), next_expected);

    const second = sequencer.popReady(&next_expected).?;
    try testing.expectEqual(@as(u64, 1), second.sequence_no);
    try testing.expectEqual(@as(u32, 22), second.effect);
    try testing.expectEqual(@as(u64, 2), next_expected);
    try testing.expectEqual(@as(usize, 0), sequencer.pendingCount());
}

test "ordered effect sequencer ignores duplicates and stale inserts explicitly" {
    var sequencer = OrderedEffectSequencer(u8, 3).init();
    var next_expected: u64 = 4;

    try testing.expectEqual(InsertStatus.accepted, sequencer.insert(next_expected, 5, 55));
    try testing.expectEqual(InsertStatus.duplicate_ignored, sequencer.insert(next_expected, 5, 99));
    try testing.expectEqual(InsertStatus.stale, sequencer.insert(next_expected, 3, 33));

    try testing.expect(sequencer.contains(5));
    try testing.expect(!sequencer.contains(4));

    try testing.expectEqual(@as(?OrderedEffectSequencer(u8, 3).ReadyEffect, null), sequencer.popReady(&next_expected));
    try testing.expectEqual(InsertStatus.accepted, sequencer.insert(next_expected, 4, 44));
    const ready = sequencer.popReady(&next_expected).?;
    try testing.expectEqual(@as(u64, 4), ready.sequence_no);
    try testing.expectEqual(@as(u8, 44), ready.effect);
}

test "ordered effect sequencer reports capacity pressure and bounded status" {
    var sequencer = OrderedEffectSequencer(u16, 2).init();
    const next_expected: u64 = 10;

    try testing.expectEqual(InsertStatus.accepted, sequencer.insert(next_expected, 12, 120));
    try testing.expectEqual(InsertStatus.accepted, sequencer.insert(next_expected, 10, 100));
    try testing.expectEqual(InsertStatus.no_space, sequencer.insert(next_expected, 11, 110));

    const status = sequencer.status();
    try testing.expectEqual(@as(usize, 2), status.pending_count);
    try testing.expectEqual(@as(usize, 0), status.free);
    try testing.expectEqual(@as(?u64, 10), status.lowest_buffered_sequence_no);
    try testing.expectEqual(@as(?u64, 12), status.highest_buffered_sequence_no);

    sequencer.reset();
    try testing.expectEqual(@as(usize, 0), sequencer.pendingCount());
    try testing.expectEqual(@as(usize, 2), sequencer.free());
}
