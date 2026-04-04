const concepts = @import("../concepts/root.zig");

pub fn AnyRegisteredFanoutRing(
    comptime T: type,
    comptime TrySendError: type,
    comptime TryRecvError: type,
) type {
    return struct {
        const Self = @This();

        pub const Element = T;
        pub const ConsumerId = usize;
        pub const SendError = TrySendError;
        pub const RecvError = TryRecvError;

        ptr: *anyopaque,
        vtable: *const VTable,

        const VTable = struct {
            addConsumer: *const fn (ctx: *anyopaque) error{NoSpaceLeft}!ConsumerId,
            removeConsumer: *const fn (ctx: *anyopaque, consumer_id: ConsumerId) void,
            trySend: *const fn (ctx: *anyopaque, value: T) TrySendError!void,
            tryRecv: *const fn (ctx: *anyopaque, consumer_id: ConsumerId) TryRecvError!T,
            pending: *const fn (ctx: *anyopaque, consumer_id: ConsumerId) usize,
        };

        pub fn from(fanout_ptr: anytype) Self {
            const ptr_info = @typeInfo(@TypeOf(fanout_ptr));
            if (ptr_info != .pointer) {
                @compileError("`AnyRegisteredFanoutRing.from` requires a pointer argument.");
            }
            const F = ptr_info.pointer.child;
            concepts.registered_fanout_ring.requireRegisteredFanoutRing(F, T);
            if (F.ConsumerId != ConsumerId) {
                @compileError("`AnyRegisteredFanoutRing` currently requires `ConsumerId == usize`.");
            }
            if (F.TrySendError != TrySendError) {
                @compileError("`AnyRegisteredFanoutRing` send error set mismatch.");
            }
            if (F.TryRecvError != TryRecvError) {
                @compileError("`AnyRegisteredFanoutRing` recv error set mismatch.");
            }

            return .{
                .ptr = fanout_ptr,
                .vtable = &VTableImpl(F).vtable,
            };
        }

        pub fn addConsumer(self: *Self) error{NoSpaceLeft}!ConsumerId {
            return self.vtable.addConsumer(self.ptr);
        }

        pub fn removeConsumer(self: *Self, consumer_id: ConsumerId) void {
            self.vtable.removeConsumer(self.ptr, consumer_id);
        }

        pub fn trySend(self: *Self, value: T) TrySendError!void {
            return self.vtable.trySend(self.ptr, value);
        }

        pub fn tryRecv(self: *Self, consumer_id: ConsumerId) TryRecvError!T {
            return self.vtable.tryRecv(self.ptr, consumer_id);
        }

        pub fn pending(self: *Self, consumer_id: ConsumerId) usize {
            return self.vtable.pending(self.ptr, consumer_id);
        }

        fn VTableImpl(comptime F: type) type {
            return struct {
                fn addConsumerFn(ctx: *anyopaque) error{NoSpaceLeft}!ConsumerId {
                    const fanout: *F = @ptrCast(@alignCast(ctx));
                    return fanout.addConsumer();
                }

                fn removeConsumerFn(ctx: *anyopaque, consumer_id: ConsumerId) void {
                    const fanout: *F = @ptrCast(@alignCast(ctx));
                    fanout.removeConsumer(consumer_id);
                }

                fn trySendFn(ctx: *anyopaque, value: T) TrySendError!void {
                    const fanout: *F = @ptrCast(@alignCast(ctx));
                    return fanout.trySend(value);
                }

                fn tryRecvFn(ctx: *anyopaque, consumer_id: ConsumerId) TryRecvError!T {
                    const fanout: *F = @ptrCast(@alignCast(ctx));
                    return fanout.tryRecv(consumer_id);
                }

                fn pendingFn(ctx: *anyopaque, consumer_id: ConsumerId) usize {
                    const fanout: *F = @ptrCast(@alignCast(ctx));
                    return fanout.pending(consumer_id);
                }

                const vtable: VTable = .{
                    .addConsumer = addConsumerFn,
                    .removeConsumer = removeConsumerFn,
                    .trySend = trySendFn,
                    .tryRecv = tryRecvFn,
                    .pending = pendingFn,
                };
            };
        }
    };
}
