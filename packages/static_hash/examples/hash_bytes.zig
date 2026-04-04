const hash = @import("static_hash");

pub fn main() !void {
    var h = hash.fnv1a.Fnv1a64.initDefault();
    h.update("hello");
    _ = h.final();
}
