//! Scratch allocator built on a `Stack` with explicit begin/end scoping.
//!
//! Key types: `Scratch`, `ScratchError`, `Mark`.
//! Usage pattern: call `Scratch.init` with a backing allocator and capacity. Use `begin()` to
//! capture a scope mark and `end(mark)` to roll back all allocations since that mark. Obtain a
//! `std.mem.Allocator` via `allocator()` for use with standard library functions.
//! Thread safety: not thread-safe. Callers must serialise access externally.
//! Memory budget: a single contiguous buffer is allocated at init via the backing allocator; no
//! allocation occurs during scoped use. Stack is 48 bytes on 64-bit targets.

const std = @import("std");
const Stack = @import("stack.zig").Stack;
const StackError = @import("stack.zig").StackError;
const CapacityReport = @import("capacity_report.zig").CapacityReport;

pub const ScratchError = StackError;

pub const Scratch = struct {
    stack: Stack,

    pub const Mark = Stack.Marker;

    pub fn init(backing_allocator: std.mem.Allocator, capacity_bytes: u32) ScratchError!Scratch {
        // Precondition: a zero-capacity scratch is never valid; Stack.init also rejects it,
        // but asserting here documents the contract at the Scratch boundary.
        std.debug.assert(capacity_bytes != 0);
        const out: Scratch = .{ .stack = try Stack.init(backing_allocator, capacity_bytes) };
        // Postcondition: the scratch must be immediately usable with non-zero capacity.
        std.debug.assert(out.stack.capacity() == capacity_bytes);
        return out;
    }

    pub fn deinit(self: *Scratch) void {
        // Precondition: scratch must be initialized (capacity non-zero); deInit on an
        // already-deinitialized scratch would free an already-freed buffer.
        std.debug.assert(self.stack.capacity() != 0);
        self.stack.deinit();
    }

    pub fn begin(self: *Scratch) Mark {
        // Precondition: scratch must be initialized (capacity non-zero) before scoping begins.
        std.debug.assert(self.stack.capacity() != 0);
        const scope_mark = self.stack.mark();
        // Postcondition: the returned mark equals the current stack position. A begin() that
        // returns a stale mark would silently corrupt nested scope rollbacks.
        std.debug.assert(scope_mark == self.stack.used());
        return scope_mark;
    }

    pub fn end(self: *Scratch, scope_mark: Mark) void {
        // Precondition: the mark must not exceed the current stack top. Restoring past the
        // current top would imply the mark was fabricated or the scope was ended twice.
        std.debug.assert(scope_mark <= self.stack.used());
        self.stack.freeTo(scope_mark);
        // Postcondition: the stack position must equal the mark that was passed in.
        std.debug.assert(self.stack.used() == scope_mark);
    }

    pub fn reset(self: *Scratch) void {
        // Precondition: scratch must be initialized.
        std.debug.assert(self.stack.capacity() != 0);
        self.stack.reset();
        // Postcondition: all memory has been released; the stack cursor must be at zero.
        std.debug.assert(self.stack.used() == 0);
    }

    pub fn used(self: *const Scratch) u32 {
        // Precondition: scratch must be initialized.
        std.debug.assert(self.stack.capacity() != 0);
        const val = self.stack.used();
        // Postcondition: used must not exceed capacity.
        std.debug.assert(val <= self.stack.capacity());
        return val;
    }

    pub fn capacity(self: *const Scratch) u32 {
        const cap = self.stack.capacity();
        // Postcondition: capacity must be non-zero for any initialized scratch.
        std.debug.assert(cap != 0);
        // Postcondition: capacity must be >= used bytes.
        std.debug.assert(cap >= self.stack.used());
        return cap;
    }

    pub fn highWater(self: *const Scratch) u32 {
        // Precondition: scratch must be initialized.
        std.debug.assert(self.stack.capacity() != 0);
        const hw = self.stack.highWater();
        // Postcondition: high-water must be >= current used (monotonically tracked).
        std.debug.assert(hw >= self.stack.used());
        return hw;
    }

    pub fn overflowCount(self: *const Scratch) u32 {
        // Precondition: scratch must be initialized.
        std.debug.assert(self.stack.capacity() != 0);
        const count = self.stack.overflowCount();
        // Pair assertion: if any overflow occurred, the high-water mark must have been
        // set above the current cursor at some point, recorded as a diagnostic.
        if (count > 0) std.debug.assert(self.stack.highWater() >= self.stack.used());
        return count;
    }

    pub fn report(self: *const Scratch) CapacityReport {
        // Precondition: scratch must be initialized.
        std.debug.assert(self.stack.capacity() != 0);
        const r = self.stack.report();
        // Postcondition: the report must reflect the capacity that was configured.
        std.debug.assert(r.capacity == @as(u64, self.stack.capacity()));
        return r;
    }

    pub fn remaining(self: *const Scratch) u32 {
        // Precondition: scratch must be initialized.
        std.debug.assert(self.stack.capacity() != 0);
        const rem = self.stack.remaining();
        // Postcondition: remaining + used must equal capacity.
        std.debug.assert(@as(usize, rem) + @as(usize, self.stack.used()) == @as(usize, self.stack.capacity()));
        return rem;
    }

    pub fn allocator(self: *Scratch) std.mem.Allocator {
        // Precondition: scratch must be initialized before handing out an allocator handle.
        std.debug.assert(self.stack.capacity() != 0);
        const alloc_if = self.stack.allocator();
        // Postcondition: the returned allocator ptr must be non-null; the stack's own
        // allocator() already enforces this, but asserting here documents the Scratch contract.
        std.debug.assert(@intFromPtr(alloc_if.ptr) != 0);
        return alloc_if;
    }

    // Backwards-compatible aliases (non-normative).
    pub fn mark(self: *Scratch) Mark {
        return self.begin();
    }

    pub fn rollback(self: *Scratch, scope_mark: Mark) void {
        self.end(scope_mark);
    }
};

test "Scratch begin/end" {
    // Verifies that `begin()`/`end()` restore the stack mark and effectively discard scoped allocations.
    var scratch = try Scratch.init(std.testing.allocator, 128);
    defer scratch.deinit();

    const mark = scratch.begin();
    const alloc = scratch.allocator();
    _ = try alloc.alloc(u8, 16);
    scratch.end(mark);
    try std.testing.expectEqual(mark, scratch.used());
}
