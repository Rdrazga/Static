const std = @import("std");
const testing = @import("static_testing");

const ordered_effect = testing.testing.ordered_effect;

pub fn main() !void {
    var sequencer = ordered_effect.OrderedEffectSequencer([]const u8, 4).init();
    var next_expected_sequence_no: u64 = 0;

    std.debug.assert(sequencer.insert(next_expected_sequence_no, 1, "second") == .accepted);
    std.debug.assert(sequencer.insert(next_expected_sequence_no, 0, "first") == .accepted);
    std.debug.assert(sequencer.insert(next_expected_sequence_no, 2, "third") == .accepted);
    std.debug.assert(sequencer.insert(next_expected_sequence_no, 1, "duplicate") == .duplicate_ignored);

    while (sequencer.popReady(&next_expected_sequence_no)) |ready| {
        std.debug.print("release seq={d} payload={s}\n", .{ ready.sequence_no, ready.effect });
    }

    const status = sequencer.status();
    std.debug.assert(status.pending_count == 0);
    std.debug.assert(status.free == 4);
}
