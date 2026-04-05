//! Intrusive linked containers: IntrusiveList and IntrusiveMpscQueue.
//!
//! Capacity: IntrusiveList is unbounded (nodes are owned by the caller).
//!   IntrusiveMpscQueue is unbounded by default; set `max_len` to impose a limit.
//! Thread safety: IntrusiveList is not thread-safe.
//!   IntrusiveMpscQueue serializes all access with an internal mutex.
//! Blocking behavior: non-blocking; operations return `error.WouldBlock` rather than block.
const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const sync = @import("static_sync");
const qi = @import("queue_internal.zig");
const contracts = @import("../contracts.zig");

/// Node to embed inside user-owned objects.
///
/// A node must only belong to one intrusive container at a time.
pub const Node = struct {
    prev: ?*Node = null,
    next: ?*Node = null,
};

fn validateIntrusiveNodeField(comptime T: type, comptime node_field: []const u8) void {
    if (!@hasField(T, node_field)) {
        @compileError(
            "Type `" ++ @typeName(T) ++ "` is missing intrusive node field `" ++ node_field ++ "`.",
        );
    }

    if (@FieldType(T, node_field) != Node) {
        @compileError(
            "Field `" ++ node_field ++ "` on type `" ++ @typeName(T) ++ "` must be intrusive.Node.",
        );
    }
}

pub fn IntrusiveList(comptime T: type, comptime node_field: []const u8) type {
    comptime {
        validateIntrusiveNodeField(T, node_field);
    }

    return struct {
        const Self = @This();

        head: ?*Node = null,
        tail: ?*Node = null,
        len_value: usize = 0,

        pub fn init() Self {
            const self: Self = .{};
            // Postcondition: an empty list has no head, no tail, and zero length.
            assert(self.head == null);
            assert(self.tail == null);
            assert(self.len_value == 0);
            return self;
        }

        /// Initializes the list while accepting (and ignoring) an allocator.
        ///
        /// This exists for API compatibility with generic code that expects
        /// `init(allocator, cfg)`-style constructors. Intrusive containers do not
        /// allocate; callers own all node storage.
        pub fn initWithAllocator(_: std.mem.Allocator) Self {
            return init();
        }

        pub fn isEmpty(self: Self) bool {
            // Invariant: head and tail are either both null or both non-null.
            if (self.head == null) assert(self.tail == null);
            if (self.head != null) assert(self.tail != null);
            return self.head == null;
        }

        pub fn len(self: Self) usize {
            // Invariant: a zero len_value implies both head and tail are null.
            if (self.len_value == 0) assert(self.head == null);
            if (self.len_value == 0) assert(self.tail == null);
            return self.len_value;
        }

        pub fn clear(self: *Self) void {
            const old_len = self.len_value;
            var cleared_count: usize = 0;
            var node = self.head;
            while (node) |current| : (cleared_count += 1) {
                const next_node = current.next;
                current.prev = null;
                current.next = null;
                node = next_node;
            }
            self.head = null;
            self.tail = null;
            self.len_value = 0;
            assert(cleared_count == old_len);
            assert(self.head == null);
            assert(self.tail == null);
            assert(self.len_value == 0);
        }

        pub fn pushFront(self: *Self, item: *T) void {
            const node = nodePtr(item);
            // Precondition: the node must not already belong to a list (assertDetached).
            assertDetached(node);

            node.prev = null;
            node.next = self.head;
            if (self.head) |head| {
                head.prev = node;
            } else {
                self.tail = node;
            }
            self.head = node;
            self.len_value += 1;
            // Postcondition: the list is non-empty and head points to the inserted node.
            assert(self.head == node);
            assert(self.len_value > 0);
        }

        pub fn pushBack(self: *Self, item: *T) void {
            const node = nodePtr(item);
            // Precondition: the node must not already belong to a list (assertDetached).
            assertDetached(node);

            node.prev = self.tail;
            node.next = null;
            if (self.tail) |tail| {
                tail.next = node;
            } else {
                self.head = node;
            }
            self.tail = node;
            self.len_value += 1;
            // Postcondition: the list is non-empty and tail points to the inserted node.
            assert(self.tail == node);
            assert(self.len_value > 0);
        }

        pub fn popFront(self: *Self) ?*T {
            const node = self.head orelse return null;
            self.removeNode(node);
            const item = nodeToItem(node);
            // Postcondition: the removed node is now fully detached (no list membership).
            assert(node.prev == null);
            assert(node.next == null);
            return item;
        }

        pub fn popBack(self: *Self) ?*T {
            const node = self.tail orelse return null;
            self.removeNode(node);
            const item = nodeToItem(node);
            // Postcondition: the removed node is now fully detached (no list membership).
            assert(node.prev == null);
            assert(node.next == null);
            return item;
        }

        pub fn remove(self: *Self, item: *T) void {
            const node = nodePtr(item);
            // Precondition: len must be positive before remove (the node must be in the list).
            assert(self.len_value > 0);
            self.removeNode(node);
        }

        pub const Iterator = struct {
            cursor: ?*Node,

            pub fn next(self: *Iterator) ?*T {
                const node = self.cursor orelse return null;
                // Invariant: a node in the list must not point to itself in the next
                // field -- that would form a cycle and loop this iterator forever.
                assert(node.next != node);
                self.cursor = node.next;
                return nodeToItem(node);
            }
        };

        pub const ReverseIterator = struct {
            cursor: ?*Node,

            pub fn next(self: *ReverseIterator) ?*T {
                const node = self.cursor orelse return null;
                assert(node.prev != node);
                self.cursor = node.prev;
                return nodeToItem(node);
            }
        };

        pub fn iter(self: *const Self) Iterator {
            // Invariant: head and tail are either both null or both non-null.
            if (self.head == null) assert(self.tail == null);
            if (self.head != null) assert(self.tail != null);
            return .{ .cursor = self.head };
        }

        pub fn iterBack(self: *const Self) ReverseIterator {
            if (self.head == null) assert(self.tail == null);
            if (self.head != null) assert(self.tail != null);
            return .{ .cursor = self.tail };
        }

        fn removeNode(self: *Self, node: *Node) void {
            // Precondition: can only remove from a non-empty list.
            assert(self.len_value > 0);
            if (node.prev) |prev| {
                prev.next = node.next;
            } else {
                self.head = node.next;
            }

            if (node.next) |next| {
                next.prev = node.prev;
            } else {
                self.tail = node.prev;
            }

            self.len_value -= 1;
            node.prev = null;
            node.next = null;
            // Postcondition: the removed node is now fully detached.
            assert(node.prev == null);
            assert(node.next == null);
        }

        fn nodePtr(item: *T) *Node {
            return &@field(item, node_field);
        }

        fn nodeToItem(node: *Node) *T {
            return @fieldParentPtr(node_field, node);
        }

        fn assertDetached(node: *Node) void {
            assert(node.prev == null);
            assert(node.next == null);
        }
    };
}

/// Lock-based intrusive MPSC queue.
///
/// Producers enqueue user-owned nodes without allocation. The consumer dequeues
/// one item at a time using `tryRecv`.
///
/// The `max_len` field is optional. When null the queue is intentionally unbounded:
/// producers supply their own node storage so no heap allocation occurs; the only
/// resource consumed is the lock hold time and the pointer chain. Callers that need
/// a firm upper bound (e.g. to prevent a runaway producer from exhausting memory)
/// should set `max_len` at construction time and handle `error.WouldBlock` from
/// `trySend`.
pub fn IntrusiveMpscQueue(comptime T: type, comptime node_field: []const u8) type {
    comptime {
        validateIntrusiveNodeField(T, node_field);
    }

    return struct {
        const Self = @This();

        pub const Element = T;
        pub const concurrency: contracts.Concurrency = .mpsc;
        pub const is_lock_free = false;
        pub const supports_close = false;
        pub const supports_blocking_wait = false;
        pub const len_semantics: contracts.LenSemantics = .exact;
        pub const TrySendError = error{WouldBlock};
        pub const TryRecvError = error{WouldBlock};

        mutex: std.Thread.Mutex = .{},
        head: ?*Node = null,
        tail: ?*Node = null,
        len_value: usize = 0,
        // null = intentionally unbounded; producers own their node storage so
        // there is no hidden allocation to bound. Set to a positive value to
        // enforce a capacity limit and receive `error.WouldBlock` when full.
        max_len: ?usize = null,

        pub fn init() Self {
            const self: Self = .{};
            // Postcondition: a freshly initialized queue has no head and no tail.
            assert(self.head == null);
            assert(self.tail == null);
            assert(self.len_value == 0);
            return self;
        }

        /// Initializes the queue while accepting (and ignoring) an allocator.
        ///
        /// This exists for API compatibility with generic code that expects
        /// `init(allocator, cfg)`-style constructors. Intrusive queues do not
        /// allocate; producers own and manage node storage.
        pub fn initWithAllocator(_: std.mem.Allocator) Self {
            return init();
        }

        pub fn len(self: *const Self) usize {
            var guard = qi.lockConstMutex(&self.mutex);
            defer guard.unlock();
            // Invariant: len_value is consistent with the linked structure.
            if (self.len_value == 0) assert(self.head == null);
            if (self.len_value > 0) assert(self.head != null);
            return self.len_value;
        }

        pub fn isEmpty(self: *const Self) bool {
            var guard = qi.lockConstMutex(&self.mutex);
            defer guard.unlock();
            // Invariant: head and tail are either both null or both non-null.
            if (self.head == null) assert(self.tail == null);
            if (self.head != null) assert(self.tail != null);
            return self.head == null;
        }

        pub fn capacity(self: *const Self) usize {
            var guard = qi.lockConstMutex(&self.mutex);
            defer guard.unlock();
            if (self.max_len) |limit| {
                assert(limit > 0);
                return limit;
            }
            return std.math.maxInt(usize);
        }

        pub fn trySend(self: *Self, item: *T) TrySendError!void {
            const node = nodePtr(item);
            // Precondition: node must be detached before enqueueing.
            assert(node.prev == null);
            assert(node.next == null);

            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.max_len) |limit| {
                // Precondition: limit must be positive; a zero-capacity queue is unusable.
                assert(limit > 0);
                if (self.len_value >= limit) return error.WouldBlock;
                assert(self.len_value < limit);
            }

            if (self.tail) |tail| {
                tail.next = node;
                self.tail = node;
            } else {
                self.head = node;
                self.tail = node;
            }
            self.len_value += 1;
            // Postcondition: the queue is non-empty and tail points to the new node.
            assert(self.tail == node);
            assert(self.head != null);
            assert(self.len_value > 0);
        }

        pub fn tryRecv(self: *Self) TryRecvError!*T {
            self.mutex.lock();
            defer self.mutex.unlock();

            const node = self.head orelse return error.WouldBlock;
            const old_len = self.len_value;
            self.head = node.next;
            if (self.head == null) self.tail = null;
            node.next = null;
            node.prev = null;
            self.len_value -= 1;
            // Postcondition: the dequeued node is fully detached.
            assert(node.next == null);
            assert(node.prev == null);
            assert(self.len_value == old_len - 1);
            return @fieldParentPtr(node_field, node);
        }

        fn nodePtr(item: *T) *Node {
            return &@field(item, node_field);
        }
    };
}

test "intrusive list push/pop order and remove" {
    const Item = struct {
        value: u8,
        node: Node = .{},
    };

    var a = Item{ .value = 1 };
    var b = Item{ .value = 2 };
    var c = Item{ .value = 3 };

    var list = IntrusiveList(Item, "node").init();
    list.pushBack(&a);
    list.pushBack(&b);
    list.pushFront(&c);
    try testing.expectEqual(@as(usize, 3), list.len());

    try testing.expectEqual(@as(u8, 3), list.popFront().?.value);
    list.remove(&b);
    try testing.expectEqual(@as(usize, 1), list.len());
    try testing.expectEqual(@as(u8, 1), list.popBack().?.value);
}

test "intrusive list clear empties list and detaches nodes" {
    const Item = struct {
        value: u8,
        node: Node = .{},
    };

    var a = Item{ .value = 1 };
    var b = Item{ .value = 2 };
    var c = Item{ .value = 3 };

    var list = IntrusiveList(Item, "node").init();
    list.pushBack(&a);
    list.pushBack(&b);
    list.pushBack(&c);
    list.clear();

    try testing.expectEqual(@as(usize, 0), list.len());
    try testing.expect(list.isEmpty());
    try testing.expect(a.node.prev == null);
    try testing.expect(a.node.next == null);
    try testing.expect(b.node.prev == null);
    try testing.expect(b.node.next == null);
    try testing.expect(c.node.prev == null);
    try testing.expect(c.node.next == null);
}

test "intrusive list reverse iteration walks tail to head" {
    const Item = struct {
        value: u8,
        node: Node = .{},
    };

    var a = Item{ .value = 1 };
    var b = Item{ .value = 2 };
    var c = Item{ .value = 3 };

    var list = IntrusiveList(Item, "node").init();
    list.pushBack(&a);
    list.pushBack(&b);
    list.pushBack(&c);

    var reverse = list.iterBack();
    try testing.expectEqual(@as(u8, 3), reverse.next().?.value);
    try testing.expectEqual(@as(u8, 2), reverse.next().?.value);
    try testing.expectEqual(@as(u8, 1), reverse.next().?.value);
    try testing.expect(reverse.next() == null);
}

test "intrusive mpsc queue returns WouldBlock when empty" {
    const Item = struct {
        value: u8,
        node: Node = .{},
    };

    var q = IntrusiveMpscQueue(Item, "node").init();
    var a = Item{ .value = 11 };
    var b = Item{ .value = 12 };

    try q.trySend(&a);
    try q.trySend(&b);
    try testing.expectEqual(@as(u8, 11), (try q.tryRecv()).value);
    try testing.expectEqual(@as(u8, 12), (try q.tryRecv()).value);
    try testing.expectError(error.WouldBlock, q.tryRecv());
}

test "intrusive mpsc queue respects max_len bound" {
    // Goal: verify that trySend returns error.WouldBlock when max_len is reached.
    // Method: set max_len=1, fill it, then attempt a second send.
    const Item = struct {
        value: u8,
        node: Node = .{},
    };

    var q = IntrusiveMpscQueue(Item, "node"){ .max_len = 1 };
    var a = Item{ .value = 1 };
    var b = Item{ .value = 2 };

    try q.trySend(&a);
    try testing.expectError(error.WouldBlock, q.trySend(&b));
    try testing.expectEqual(@as(usize, 1), q.len());
    _ = try q.tryRecv();
    // After draining, should accept again.
    try q.trySend(&b);
}

test "intrusive mpsc queue capacity reports max_len or unbounded sentinel" {
    const Item = struct {
        value: u8,
        node: Node = .{},
    };

    var bounded = IntrusiveMpscQueue(Item, "node"){ .max_len = 3 };
    try testing.expectEqual(@as(usize, 3), bounded.capacity());

    var unbounded = IntrusiveMpscQueue(Item, "node").init();
    try testing.expectEqual(std.math.maxInt(usize), unbounded.capacity());
}

test "intrusive mpsc queue unbounded when max_len is null" {
    // Goal: verify that a null max_len imposes no capacity limit.
    // Method: enqueue more items than would fit in any typical fixed bound.
    const Item = struct {
        value: u8,
        node: Node = .{},
    };

    var q = IntrusiveMpscQueue(Item, "node").init();
    // max_len defaults to null, so this must succeed.
    assert(q.max_len == null);
    var items: [4]Item = .{
        .{ .value = 1 },
        .{ .value = 2 },
        .{ .value = 3 },
        .{ .value = 4 },
    };
    for (&items) |*item| {
        try q.trySend(item);
    }
    try testing.expectEqual(@as(usize, 4), q.len());
}
