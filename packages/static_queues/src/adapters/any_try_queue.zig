const concepts = @import("../concepts/root.zig");
const contracts = @import("../contracts.zig");

pub fn AnyTryQueue(
    comptime T: type,
    comptime queue_concurrency: contracts.Concurrency,
    comptime TrySendError: type,
    comptime TryRecvError: type,
) type {
    return struct {
        const Self = @This();

        pub const Element = T;
        pub const Concurrency = queue_concurrency;
        pub const SendError = TrySendError;
        pub const RecvError = TryRecvError;

        ptr: *anyopaque,
        vtable: *const VTable,

        const VTable = struct {
            capacity: *const fn (ctx: *const anyopaque) usize,
            len: *const fn (ctx: *const anyopaque) usize,
            isEmpty: *const fn (ctx: *const anyopaque) bool,
            trySend: *const fn (ctx: *anyopaque, value: T) TrySendError!void,
            tryRecv: *const fn (ctx: *anyopaque) TryRecvError!T,
        };

        pub fn from(queue_ptr: anytype) Self {
            const ptr_info = @typeInfo(@TypeOf(queue_ptr));
            if (ptr_info != .pointer) {
                @compileError("`AnyTryQueue.from` requires a pointer argument.");
            }
            const Q = ptr_info.pointer.child;
            concepts.try_queue.requireTryQueue(Q, T);
            if (Q.concurrency != queue_concurrency) {
                @compileError("`AnyTryQueue` concurrency parameter does not match wrapped queue.");
            }
            if (Q.TrySendError != TrySendError) {
                @compileError("`AnyTryQueue` send error set does not match wrapped queue.");
            }
            if (Q.TryRecvError != TryRecvError) {
                @compileError("`AnyTryQueue` recv error set does not match wrapped queue.");
            }

            return .{
                .ptr = queue_ptr,
                .vtable = &VTableImpl(Q).vtable,
            };
        }

        pub fn capacity(self: *const Self) usize {
            return self.vtable.capacity(self.ptr);
        }

        pub fn len(self: *const Self) usize {
            return self.vtable.len(self.ptr);
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.vtable.isEmpty(self.ptr);
        }

        pub fn trySend(self: *Self, value: T) TrySendError!void {
            return self.vtable.trySend(self.ptr, value);
        }

        pub fn tryRecv(self: *Self) TryRecvError!T {
            return self.vtable.tryRecv(self.ptr);
        }

        fn VTableImpl(comptime Q: type) type {
            return struct {
                fn capacityFn(ctx: *const anyopaque) usize {
                    const queue: *const Q = @ptrCast(@alignCast(ctx));
                    return queue.capacity();
                }

                fn lenFn(ctx: *const anyopaque) usize {
                    const queue: *const Q = @ptrCast(@alignCast(ctx));
                    return queue.len();
                }

                fn isEmptyFn(ctx: *const anyopaque) bool {
                    const queue: *const Q = @ptrCast(@alignCast(ctx));
                    return queue.isEmpty();
                }

                fn trySendFn(ctx: *anyopaque, value: T) TrySendError!void {
                    const queue: *Q = @ptrCast(@alignCast(ctx));
                    return queue.trySend(value);
                }

                fn tryRecvFn(ctx: *anyopaque) TryRecvError!T {
                    const queue: *Q = @ptrCast(@alignCast(ctx));
                    return queue.tryRecv();
                }

                const vtable: VTable = .{
                    .capacity = capacityFn,
                    .len = lenFn,
                    .isEmpty = isEmptyFn,
                    .trySend = trySendFn,
                    .tryRecv = tryRecvFn,
                };
            };
        }
    };
}
