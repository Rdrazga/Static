const std = @import("std");
const sync = @import("static_sync");

pub fn main() !void {
    var once = sync.once.Once{};
    once.call(noop);
    _ = std;
}

fn noop() void {}
