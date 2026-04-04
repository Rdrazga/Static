const std = @import("std");
const sync = @import("static_sync");

pub fn main() !void {
    var src = sync.cancel.CancelSource{};
    const tok = src.token();
    _ = tok.isCancelled();
    src.cancel();
    _ = tok.isCancelled();
    _ = std;
}
