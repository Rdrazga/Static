//! Demonstrates basic MinHeap usage: push values and pop them in min order.
const std = @import("std");
const collections = @import("static_collections");

const Cmp = struct {
    pub fn lessThan(_: @This(), a: u32, b: u32) bool {
        return a < b;
    }
};

pub fn main() !void {
    var heap = try collections.min_heap.MinHeap(u32, Cmp).init(
        std.heap.page_allocator,
        .{ .capacity = 16 },
        .{},
    );
    defer heap.deinit();

    try heap.push(10);
    try heap.push(3);
    try heap.push(7);
    try heap.push(1);
    try heap.push(5);

    // Pops in ascending order: 1, 3, 5, 7, 10.
    while (heap.popMin()) |v| {
        std.debug.print("popped: {d}\n", .{v});
    }
}
