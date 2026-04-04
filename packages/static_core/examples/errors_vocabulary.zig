const core = @import("static_core");

pub fn main() !void {
    const matches = core.errors.has(.InvalidInput, error.InvalidInput);
    try core.config.validate(matches);
}
