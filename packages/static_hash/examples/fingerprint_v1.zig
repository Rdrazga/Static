const hash = @import("static_hash");

pub fn main() !void {
    var fp = hash.fingerprint.Fingerprint64V1.init();
    fp.addU64(1234);
    _ = fp.final();
}
