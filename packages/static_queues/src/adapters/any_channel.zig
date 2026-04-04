const sync = @import("static_sync");
const concepts = @import("../concepts/root.zig");

pub fn AnyChannel(
    comptime T: type,
    comptime TrySendError: type,
    comptime TryRecvError: type,
    comptime SendError: type,
    comptime RecvError: type,
    comptime SendTimeoutError: type,
    comptime RecvTimeoutError: type,
) type {
    return struct {
        const Self = @This();

        pub const Element = T;
        pub const NonBlockingSendError = TrySendError;
        pub const NonBlockingRecvError = TryRecvError;
        pub const BlockingSendError = SendError;
        pub const BlockingRecvError = RecvError;
        pub const BlockingSendTimeoutError = SendTimeoutError;
        pub const BlockingRecvTimeoutError = RecvTimeoutError;

        ptr: *anyopaque,
        vtable: *const VTable,

        const VTable = struct {
            capacity: *const fn (ctx: *const anyopaque) usize,
            len: *const fn (ctx: *const anyopaque) usize,
            isEmpty: *const fn (ctx: *const anyopaque) bool,
            close: *const fn (ctx: *anyopaque) void,
            trySend: *const fn (ctx: *anyopaque, value: T) TrySendError!void,
            tryRecv: *const fn (ctx: *anyopaque) TryRecvError!T,
            send: *const fn (ctx: *anyopaque, value: T, cancel: ?sync.cancel.CancelToken) SendError!void,
            recv: *const fn (ctx: *anyopaque, cancel: ?sync.cancel.CancelToken) RecvError!T,
            sendTimeout: *const fn (ctx: *anyopaque, value: T, cancel: ?sync.cancel.CancelToken, timeout_ns: u64) SendTimeoutError!void,
            recvTimeout: *const fn (ctx: *anyopaque, cancel: ?sync.cancel.CancelToken, timeout_ns: u64) RecvTimeoutError!T,
        };

        pub fn from(channel_ptr: anytype) Self {
            const ptr_info = @typeInfo(@TypeOf(channel_ptr));
            if (ptr_info != .pointer) {
                @compileError("`AnyChannel.from` requires a pointer argument.");
            }
            const C = ptr_info.pointer.child;
            concepts.channel.requireChannel(C, T);
            if (!C.supports_blocking_wait) {
                @compileError("`AnyChannel` requires a channel with blocking support enabled.");
            }
            if (!@hasDecl(C, "supports_timed_wait") or !C.supports_timed_wait) {
                @compileError("`AnyChannel` requires a channel with timed wait support enabled.");
            }
            if (!@hasDecl(C, "sendTimeout")) {
                @compileError("`AnyChannel` requires `sendTimeout` on the concrete channel type.");
            }
            if (!@hasDecl(C, "recvTimeout")) {
                @compileError("`AnyChannel` requires `recvTimeout` on the concrete channel type.");
            }
            if (C.TrySendError != TrySendError) {
                @compileError(
                    "`AnyChannel` non-blocking send error set mismatch: expected `" ++
                        @typeName(TrySendError) ++ "`, got `" ++ @typeName(C.TrySendError) ++ "`.",
                );
            }
            if (C.TryRecvError != TryRecvError) {
                @compileError(
                    "`AnyChannel` non-blocking recv error set mismatch: expected `" ++
                        @typeName(TryRecvError) ++ "`, got `" ++ @typeName(C.TryRecvError) ++ "`.",
                );
            }
            if (C.SendError != SendError) {
                @compileError(
                    "`AnyChannel` blocking send error set mismatch: expected `" ++
                        @typeName(SendError) ++ "`, got `" ++ @typeName(C.SendError) ++ "`.",
                );
            }
            if (C.RecvError != RecvError) {
                @compileError(
                    "`AnyChannel` blocking recv error set mismatch: expected `" ++
                        @typeName(RecvError) ++ "`, got `" ++ @typeName(C.RecvError) ++ "`.",
                );
            }
            // Keep the timed-wait vocabulary identical to the concrete channel.
            // `Unsupported` stays in the contract because the shared timeout
            // budget and wait-queue helpers can surface it on supported builds.
            if (!@hasDecl(C, "SendTimeoutError")) {
                @compileError("`AnyChannel` requires `SendTimeoutError` on the concrete channel type.");
            }
            if (C.SendTimeoutError != SendTimeoutError) {
                @compileError(
                    "`AnyChannel` blocking sendTimeout error set mismatch: expected `" ++
                        @typeName(SendTimeoutError) ++ "`, got `" ++ @typeName(C.SendTimeoutError) ++ "`.",
                );
            }
            if (!@hasDecl(C, "RecvTimeoutError")) {
                @compileError("`AnyChannel` requires `RecvTimeoutError` on the concrete channel type.");
            }
            if (C.RecvTimeoutError != RecvTimeoutError) {
                @compileError(
                    "`AnyChannel` blocking recvTimeout error set mismatch: expected `" ++
                        @typeName(RecvTimeoutError) ++ "`, got `" ++ @typeName(C.RecvTimeoutError) ++ "`.",
                );
            }

            return .{
                .ptr = channel_ptr,
                .vtable = &VTableImpl(C).vtable,
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

        pub fn close(self: *Self) void {
            self.vtable.close(self.ptr);
        }

        pub fn trySend(self: *Self, value: T) TrySendError!void {
            return self.vtable.trySend(self.ptr, value);
        }

        pub fn tryRecv(self: *Self) TryRecvError!T {
            return self.vtable.tryRecv(self.ptr);
        }

        pub fn send(self: *Self, value: T, cancel: ?sync.cancel.CancelToken) SendError!void {
            return self.vtable.send(self.ptr, value, cancel);
        }

        pub fn recv(self: *Self, cancel: ?sync.cancel.CancelToken) RecvError!T {
            return self.vtable.recv(self.ptr, cancel);
        }

        pub fn sendTimeout(
            self: *Self,
            value: T,
            cancel: ?sync.cancel.CancelToken,
            timeout_ns: u64,
        ) SendTimeoutError!void {
            return self.vtable.sendTimeout(self.ptr, value, cancel, timeout_ns);
        }

        pub fn recvTimeout(
            self: *Self,
            cancel: ?sync.cancel.CancelToken,
            timeout_ns: u64,
        ) RecvTimeoutError!T {
            return self.vtable.recvTimeout(self.ptr, cancel, timeout_ns);
        }

        fn VTableImpl(comptime C: type) type {
            return struct {
                fn capacityFn(ctx: *const anyopaque) usize {
                    const channel: *const C = @ptrCast(@alignCast(ctx));
                    return channel.capacity();
                }

                fn lenFn(ctx: *const anyopaque) usize {
                    const channel: *const C = @ptrCast(@alignCast(ctx));
                    return channel.len();
                }

                fn isEmptyFn(ctx: *const anyopaque) bool {
                    const channel: *const C = @ptrCast(@alignCast(ctx));
                    return channel.isEmpty();
                }

                fn closeFn(ctx: *anyopaque) void {
                    const channel: *C = @ptrCast(@alignCast(ctx));
                    channel.close();
                }

                fn trySendFn(ctx: *anyopaque, value: T) TrySendError!void {
                    const channel: *C = @ptrCast(@alignCast(ctx));
                    return channel.trySend(value);
                }

                fn tryRecvFn(ctx: *anyopaque) TryRecvError!T {
                    const channel: *C = @ptrCast(@alignCast(ctx));
                    return channel.tryRecv();
                }

                fn sendFn(ctx: *anyopaque, value: T, cancel: ?sync.cancel.CancelToken) SendError!void {
                    const channel: *C = @ptrCast(@alignCast(ctx));
                    return channel.send(value, cancel);
                }

                fn recvFn(ctx: *anyopaque, cancel: ?sync.cancel.CancelToken) RecvError!T {
                    const channel: *C = @ptrCast(@alignCast(ctx));
                    return channel.recv(cancel);
                }

                fn sendTimeoutFn(
                    ctx: *anyopaque,
                    value: T,
                    cancel: ?sync.cancel.CancelToken,
                    timeout_ns: u64,
                ) SendTimeoutError!void {
                    const channel: *C = @ptrCast(@alignCast(ctx));
                    return channel.sendTimeout(value, cancel, timeout_ns);
                }

                fn recvTimeoutFn(
                    ctx: *anyopaque,
                    cancel: ?sync.cancel.CancelToken,
                    timeout_ns: u64,
                ) RecvTimeoutError!T {
                    const channel: *C = @ptrCast(@alignCast(ctx));
                    return channel.recvTimeout(cancel, timeout_ns);
                }

                const vtable: VTable = .{
                    .capacity = capacityFn,
                    .len = lenFn,
                    .isEmpty = isEmptyFn,
                    .close = closeFn,
                    .trySend = trySendFn,
                    .tryRecv = tryRecvFn,
                    .send = sendFn,
                    .recv = recvFn,
                    .sendTimeout = sendTimeoutFn,
                    .recvTimeout = recvTimeoutFn,
                };
            };
        }
    };
}
