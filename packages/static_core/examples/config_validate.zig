const std = @import("std");
const core = @import("static_core");

pub fn main() !void {
    try core.config.validate(true);
    _ = std;
}
