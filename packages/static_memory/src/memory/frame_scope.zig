//! Lightweight scope guards for stack- and scratch-style allocators.
//!
//! These helpers are intentionally explicit: callers must invoke `end()` (usually via `defer`) to
//! restore the allocator's previous mark.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Stack = @import("stack.zig").Stack;
const Scratch = @import("scratch.zig").Scratch;

pub const StackFrameScope = struct {
    stack: *Stack,
    mark: Stack.Marker,

    pub fn begin(stack: *Stack) StackFrameScope {
        assert(stack.capacity() != 0);
        const scope: StackFrameScope = .{ .stack = stack, .mark = stack.mark() };
        // Postcondition: the captured mark must equal the current stack cursor. A stale
        // mark would silently allow end() to free memory that was not allocated by this scope.
        assert(scope.mark == stack.used());
        return scope;
    }

    pub fn end(self: *const StackFrameScope) void {
        // Precondition: the saved mark must not exceed the current stack top. If it did, the
        // scope was either never properly begun or the stack was reset between begin and end,
        // both of which are programmer errors.
        assert(self.mark <= self.stack.used());
        self.stack.freeTo(self.mark);
        // Postcondition: the stack cursor must be restored to the mark captured at begin().
        assert(self.stack.used() == self.mark);
    }
};

pub const ScratchFrameScope = struct {
    scratch: *Scratch,
    mark: Scratch.Mark,

    pub fn begin(scratch: *Scratch) ScratchFrameScope {
        assert(scratch.capacity() != 0);
        const scope: ScratchFrameScope = .{ .scratch = scratch, .mark = scratch.begin() };
        // Postcondition: the captured mark must equal the current scratch cursor. A stale
        // mark would silently allow end() to free memory outside this scope's allocation.
        assert(scope.mark == scratch.used());
        return scope;
    }

    pub fn end(self: *const ScratchFrameScope) void {
        // Precondition: the saved mark must not exceed the current scratch position. If it
        // did, the scope was never properly begun or scratch was reset between begin and end.
        assert(self.mark <= self.scratch.used());
        self.scratch.end(self.mark);
        // Postcondition: the scratch position must be restored to the mark captured at begin().
        assert(self.scratch.used() == self.mark);
    }
};

test "stack frame scope frees to mark" {
    // Verifies that `StackFrameScope` returns the stack to the pre-scope mark.
    const allocator = testing.allocator;
    var stack = try Stack.init(allocator, 128);
    defer stack.deinit();

    _ = try stack.alloc(16, 8);

    const scope = StackFrameScope.begin(&stack);
    _ = try stack.alloc(32, 8);
    scope.end();

    try testing.expectEqual(scope.mark, stack.used());
}

test "scratch frame scope ends scope" {
    // Verifies that `ScratchFrameScope` ends the scratch scope and restores the prior mark.
    var scratch = try Scratch.init(testing.allocator, 128);
    defer scratch.deinit();

    const scope = ScratchFrameScope.begin(&scratch);
    _ = try scratch.allocator().alloc(u8, 32);
    scope.end();

    try testing.expectEqual(scope.mark, scratch.used());
}
