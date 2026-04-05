const std = @import("std");
const assert = std.debug.assert;
const sync = @import("static_sync");

pub fn main() !void {
    var grant = sync.grant.Grant(8, 8).begin(1);
    try grant.grantWrite(42);
    try grant.recordWrite(42, 7);

    const token = try grant.issueToken(42, .write);
    assert(grant.validateToken(token, .write));
    assert(grant.wasWritten(42, 7));
}
