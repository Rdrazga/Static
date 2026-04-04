const std = @import("std");
const memory = @import("static_memory");

pub fn main() !void {
    var budget = try memory.budget.Budget.init(4096);
    budget.lockIn();
    _ = std;
}
