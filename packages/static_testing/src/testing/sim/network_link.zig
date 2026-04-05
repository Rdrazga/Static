//! Bounded deterministic message-delivery simulator over logical time.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const trace = @import("../trace.zig");
const clock = @import("clock.zig");
const mailbox = @import("mailbox.zig");

pub const PartitionMode = union(enum(u8)) {
    connected,
    drop_all,
    isolate_node: u32,
    partition_groups: GroupPartition,
};

pub const GroupPartition = struct {
    from_nodes: []const u32,
    to_nodes: []const u32,
    bidirectional: bool = false,
};

pub const RouteMatch = struct {
    source_id: ?u32 = null,
    destination_id: ?u32 = null,

    pub fn matches(self: @This(), source_id: u32, destination_id: u32) bool {
        if (self.source_id) |expected_source| {
            if (expected_source != source_id) return false;
        }
        if (self.destination_id) |expected_destination| {
            if (expected_destination != destination_id) return false;
        }
        return true;
    }
};

pub const FaultEffect = union(enum(u8)) {
    drop: void,
    add_delay: clock.LogicalDuration,
};

pub const FaultRule = struct {
    route: RouteMatch,
    effect: FaultEffect,
};

pub const CongestionWindow = struct {
    route: RouteMatch,
    active_from: clock.LogicalTime,
    active_until: clock.LogicalTime,
};

pub const BacklogOverflowBehavior = enum(u8) {
    drop_newest,
    drop_oldest,
    reject_new,
};

pub const BacklogPolicy = struct {
    route: RouteMatch,
    max_pending: usize,
    overflow: BacklogOverflowBehavior,
};

pub const NetworkLinkError = error{
    InvalidConfig,
    InvalidInput,
    NoSpaceLeft,
};

pub const NetworkLinkConfig = struct {
    default_delay: clock.LogicalDuration,
    partition_mode: PartitionMode = .connected,
    fault_rules: []const FaultRule = &.{},
    congestion_windows: []const CongestionWindow = &.{},
    backlog_policies: []const BacklogPolicy = &.{},
};

pub fn Delivery(comptime T: type) type {
    return struct {
        source_id: u32,
        destination_id: u32,
        due_time: clock.LogicalTime,
        payload: T,
    };
}

pub const DeliveryResult = struct {
    delivered_count: u32 = 0,
    dropped_count: u32 = 0,
};

pub fn NetworkLink(comptime T: type) type {
    return struct {
        const Self = @This();
        const PendingDelivery = Delivery(T);

        config: NetworkLinkConfig,
        storage: []PendingDelivery,
        pending_count: usize = 0,

        pub fn init(
            storage: []PendingDelivery,
            config: NetworkLinkConfig,
        ) NetworkLinkError!Self {
            if (storage.len == 0) return error.InvalidConfig;
            try validateConfig(config);
            return .{
                .config = config,
                .storage = storage,
            };
        }

        pub fn setPartitionMode(self: *Self, mode: PartitionMode) NetworkLinkError!void {
            try validatePartitionMode(mode);
            self.config.partition_mode = mode;
        }

        pub fn send(
            self: *Self,
            now: clock.LogicalTime,
            source_id: u32,
            destination_id: u32,
            payload: T,
        ) NetworkLinkError!void {
            return self.sendAfter(now, source_id, destination_id, self.config.default_delay, payload);
        }

        pub fn sendAfter(
            self: *Self,
            now: clock.LogicalTime,
            source_id: u32,
            destination_id: u32,
            delay: clock.LogicalDuration,
            payload: T,
        ) NetworkLinkError!void {
            if (destination_id == 0) return error.InvalidInput;

            const effective_delay = try self.resolveDelay(source_id, destination_id, delay) orelse return;
            var due_time = now.add(effective_delay) catch |err| switch (err) {
                error.InvalidInput => return error.InvalidInput,
                error.Overflow => return error.InvalidInput,
            };
            due_time = try self.applyCongestionWindows(now, source_id, destination_id, due_time);
            switch (try self.applyBacklogPolicies(source_id, destination_id)) {
                .enqueue => {},
                .drop_newest => return,
            }
            if (self.pending_count >= self.storage.len) return error.NoSpaceLeft;
            self.storage[self.pending_count] = .{
                .source_id = source_id,
                .destination_id = destination_id,
                .due_time = due_time,
                .payload = payload,
            };
            self.pending_count += 1;
            assert(self.pending_count <= self.storage.len);
        }

        pub fn deliverDueToMailbox(
            self: *Self,
            now: clock.LogicalTime,
            destination_id: u32,
            destination_mailbox: *mailbox.Mailbox(T),
            trace_buffer: ?*trace.TraceBuffer,
        ) (NetworkLinkError || trace.TraceAppendError || mailbox.MailboxError)!DeliveryResult {
            if (destination_id == 0) return error.InvalidInput;

            var result: DeliveryResult = .{};
            var read_index: usize = 0;
            while (read_index < self.pending_count) {
                const pending = self.storage[read_index];
                if (pending.destination_id != destination_id or pending.due_time.tick > now.tick) {
                    read_index += 1;
                    continue;
                }

                try ensureDeliveryCanProceed(trace_buffer, destination_mailbox);
                try destination_mailbox.send(pending.payload);
                try appendDeliveryTrace(trace_buffer, now, pending);
                result.delivered_count += 1;
                removePendingAt(self.storage, &self.pending_count, read_index);
            }
            return result;
        }

        pub fn recordPending(
            self: *const Self,
            out: []PendingDelivery,
        ) NetworkLinkError![]const PendingDelivery {
            if (out.len < self.pending_count) return error.NoSpaceLeft;
            std.mem.copyForwards(PendingDelivery, out[0..self.pending_count], self.storage[0..self.pending_count]);
            return out[0..self.pending_count];
        }

        pub fn replayRecordedPending(
            self: *Self,
            recorded: []const PendingDelivery,
        ) NetworkLinkError!void {
            if (self.pending_count != 0) return error.InvalidInput;
            if (recorded.len > self.storage.len) return error.NoSpaceLeft;

            for (recorded, 0..) |delivery, index| {
                if (delivery.destination_id == 0) return error.InvalidInput;
                self.storage[index] = delivery;
            }
            self.pending_count = recorded.len;
            assert(self.pending_count <= self.storage.len);
        }

        pub fn pendingItems(self: *const Self) []const PendingDelivery {
            return self.storage[0..self.pending_count];
        }

        fn resolveDelay(
            self: *const Self,
            source_id: u32,
            destination_id: u32,
            delay: clock.LogicalDuration,
        ) NetworkLinkError!?clock.LogicalDuration {
            if (partitionDropsTraffic(self.config.partition_mode, source_id, destination_id)) {
                return null;
            }

            for (self.config.fault_rules) |rule| {
                if (!rule.route.matches(source_id, destination_id)) continue;
                return switch (rule.effect) {
                    .drop => null,
                    .add_delay => |extra_delay| .{
                        .ticks = std.math.add(u64, delay.ticks, extra_delay.ticks) catch return error.InvalidInput,
                    },
                };
            }
            return delay;
        }

        fn applyCongestionWindows(
            self: *const Self,
            now: clock.LogicalTime,
            source_id: u32,
            destination_id: u32,
            due_time: clock.LogicalTime,
        ) NetworkLinkError!clock.LogicalTime {
            var effective_due_time = due_time;
            for (self.config.congestion_windows) |window| {
                if (!window.route.matches(source_id, destination_id)) continue;
                if (!windowIntersectsDelivery(now, effective_due_time, window)) continue;
                if (window.active_until.tick > effective_due_time.tick) {
                    effective_due_time = window.active_until;
                }
            }
            return effective_due_time;
        }

        fn applyBacklogPolicies(
            self: *Self,
            source_id: u32,
            destination_id: u32,
        ) NetworkLinkError!BacklogDecision {
            for (self.config.backlog_policies) |policy| {
                if (!policy.route.matches(source_id, destination_id)) continue;

                const saturation = findBacklogSaturation(self.pendingItems(), policy.route);
                if (saturation.matching_count < policy.max_pending) return .enqueue;

                return switch (policy.overflow) {
                    .drop_newest => .drop_newest,
                    .drop_oldest => blk: {
                        assert(saturation.oldest_index != null);
                        removePendingAt(self.storage, &self.pending_count, saturation.oldest_index.?);
                        break :blk .enqueue;
                    },
                    .reject_new => error.NoSpaceLeft,
                };
            }

            return .enqueue;
        }
    };
}

const BacklogDecision = enum(u8) {
    enqueue,
    drop_newest,
};

const BacklogSaturation = struct {
    matching_count: usize = 0,
    oldest_index: ?usize = null,
};

fn validateConfig(config: NetworkLinkConfig) NetworkLinkError!void {
    try validatePartitionMode(config.partition_mode);
    for (config.fault_rules) |rule| {
        if (rule.route.source_id == null and rule.route.destination_id == null) {
            return error.InvalidConfig;
        }
    }
    for (config.congestion_windows) |window| {
        if (window.route.source_id == null and window.route.destination_id == null) {
            return error.InvalidConfig;
        }
        if (window.active_until.tick <= window.active_from.tick) {
            return error.InvalidConfig;
        }
    }
    for (config.backlog_policies) |policy| {
        if (policy.route.source_id == null and policy.route.destination_id == null) {
            return error.InvalidConfig;
        }
        if (policy.max_pending == 0) return error.InvalidConfig;
    }
}

fn validatePartitionMode(mode: PartitionMode) NetworkLinkError!void {
    switch (mode) {
        .connected, .drop_all => {},
        .isolate_node => |node_id| {
            if (node_id == 0) return error.InvalidConfig;
        },
        .partition_groups => |partition| {
            try validateNodeGroup(partition.from_nodes);
            try validateNodeGroup(partition.to_nodes);
        },
    }
}

fn partitionDropsTraffic(
    mode: PartitionMode,
    source_id: u32,
    destination_id: u32,
) bool {
    return switch (mode) {
        .connected => false,
        .drop_all => true,
        .isolate_node => |node_id| source_id == node_id or destination_id == node_id,
        .partition_groups => |partition| partitionMatches(partition, source_id, destination_id),
    };
}

fn validateNodeGroup(nodes: []const u32) NetworkLinkError!void {
    if (nodes.len == 0) return error.InvalidConfig;

    for (nodes) |node_id| {
        if (node_id == 0) return error.InvalidConfig;
    }
}

fn partitionMatches(
    partition: GroupPartition,
    source_id: u32,
    destination_id: u32,
) bool {
    assert(partition.from_nodes.len > 0);
    assert(partition.to_nodes.len > 0);

    const forward_match = groupContains(partition.from_nodes, source_id) and
        groupContains(partition.to_nodes, destination_id);
    if (forward_match) return true;
    if (!partition.bidirectional) return false;

    return groupContains(partition.to_nodes, source_id) and
        groupContains(partition.from_nodes, destination_id);
}

fn groupContains(nodes: []const u32, candidate: u32) bool {
    assert(candidate != 0);

    for (nodes) |node_id| {
        if (node_id == candidate) return true;
    }
    return false;
}

fn findBacklogSaturation(
    pending_items: anytype,
    route: RouteMatch,
) BacklogSaturation {
    var saturation: BacklogSaturation = .{};

    for (pending_items, 0..) |pending, index| {
        if (!route.matches(pending.source_id, pending.destination_id)) continue;

        saturation.matching_count += 1;
        if (saturation.oldest_index == null) {
            saturation.oldest_index = index;
        }
    }

    return saturation;
}

fn windowIntersectsDelivery(
    now: clock.LogicalTime,
    due_time: clock.LogicalTime,
    window: CongestionWindow,
) bool {
    if (now.tick >= window.active_until.tick) return false;
    if (due_time.tick < window.active_from.tick) return false;
    return true;
}

fn appendDeliveryTrace(
    trace_buffer: ?*trace.TraceBuffer,
    timestamp: clock.LogicalTime,
    pending: anytype,
) trace.TraceAppendError!void {
    if (trace_buffer) |buffer| {
        try buffer.append(.{
            .timestamp_ns = timestamp.tick,
            .category = .input,
            .label = "network_link.deliver",
            .value = pending.destination_id,
            .lineage = .{
                .correlation_id = pending.source_id,
                .surface_label = "network_link",
            },
        });
    }
}

fn ensureDeliveryCanProceed(
    trace_buffer: ?*trace.TraceBuffer,
    destination_mailbox: anytype,
) (trace.TraceAppendError || mailbox.MailboxError)!void {
    if (trace_buffer) |buffer| {
        if (buffer.freeSlots() == 0) return error.NoSpaceLeft;
    }
    if (destination_mailbox.freeSlots() == 0) return error.NoSpaceLeft;
}

fn removePendingAt(
    storage: anytype,
    pending_count: *usize,
    index: usize,
) void {
    assert(index < pending_count.*);
    var cursor = index;
    while (cursor + 1 < pending_count.*) : (cursor += 1) {
        storage[cursor] = storage[cursor + 1];
    }
    pending_count.* -= 1;
}

test "network link delivers bounded messages after their due time" {
    var storage: [4]Delivery(u32) = undefined;
    var link = try NetworkLink(u32).init(&storage, .{
        .default_delay = .init(2),
    });
    var destination = try mailbox.Mailbox(u32).init(testing.allocator, .{ .capacity = 4 });
    defer destination.deinit();

    try link.send(.init(1), 7, 11, 99);
    try testing.expectEqual(@as(usize, 1), link.pendingItems().len);

    const early = try link.deliverDueToMailbox(.init(2), 11, &destination, null);
    try testing.expectEqual(@as(u32, 0), early.delivered_count);
    try testing.expectEqual(@as(usize, 1), link.pendingItems().len);

    const delivered = try link.deliverDueToMailbox(.init(3), 11, &destination, null);
    try testing.expectEqual(@as(u32, 1), delivered.delivered_count);
    try testing.expectEqual(@as(usize, 0), link.pendingItems().len);
    try testing.expectEqual(@as(u32, 99), try destination.recv());
}

test "network link drops future sends while partitioned" {
    var storage: [2]Delivery(u32) = undefined;
    var link = try NetworkLink(u32).init(&storage, .{
        .default_delay = .init(1),
        .partition_mode = .drop_all,
    });

    try link.send(.init(0), 1, 9, 55);
    try testing.expectEqual(@as(usize, 0), link.pendingItems().len);

    try link.setPartitionMode(.connected);
    try link.send(.init(0), 1, 9, 56);
    try testing.expectEqual(@as(usize, 1), link.pendingItems().len);
}

test "network link supports isolating one node from all traffic" {
    var storage: [4]Delivery(u32) = undefined;
    var link = try NetworkLink(u32).init(&storage, .{
        .default_delay = .init(1),
        .partition_mode = .{ .isolate_node = 9 },
    });
    var destination_9 = try mailbox.Mailbox(u32).init(testing.allocator, .{ .capacity = 2 });
    defer destination_9.deinit();
    var destination_5 = try mailbox.Mailbox(u32).init(testing.allocator, .{ .capacity = 2 });
    defer destination_5.deinit();

    try link.send(.init(0), 1, 9, 11);
    try link.send(.init(0), 9, 5, 22);
    try link.send(.init(0), 5, 6, 33);
    try testing.expectEqual(@as(usize, 1), link.pendingItems().len);

    const to_9 = try link.deliverDueToMailbox(.init(1), 9, &destination_9, null);
    try testing.expectEqual(@as(u32, 0), to_9.delivered_count);

    const to_5 = try link.deliverDueToMailbox(.init(1), 5, &destination_5, null);
    try testing.expectEqual(@as(u32, 0), to_5.delivered_count);

    // The unaffected route remains deliverable.
    var destination_6 = try mailbox.Mailbox(u32).init(testing.allocator, .{ .capacity = 2 });
    defer destination_6.deinit();
    const to_6 = try link.deliverDueToMailbox(.init(1), 6, &destination_6, null);
    try testing.expectEqual(@as(u32, 1), to_6.delivered_count);
    try testing.expectEqual(@as(u32, 33), try destination_6.recv());
}

test "network link supports directed and bidirectional group partitions" {
    var storage: [6]Delivery(u32) = undefined;
    const left_group = [_]u32{ 1, 2 };
    const right_group = [_]u32{ 3, 4 };
    var link = try NetworkLink(u32).init(&storage, .{
        .default_delay = .init(1),
        .partition_mode = .{
            .partition_groups = .{
                .from_nodes = &left_group,
                .to_nodes = &right_group,
                .bidirectional = false,
            },
        },
    });
    var mailbox_1 = try mailbox.Mailbox(u32).init(testing.allocator, .{ .capacity = 2 });
    defer mailbox_1.deinit();
    var mailbox_2 = try mailbox.Mailbox(u32).init(testing.allocator, .{ .capacity = 2 });
    defer mailbox_2.deinit();
    var mailbox_3 = try mailbox.Mailbox(u32).init(testing.allocator, .{ .capacity = 2 });
    defer mailbox_3.deinit();
    var mailbox_4 = try mailbox.Mailbox(u32).init(testing.allocator, .{ .capacity = 2 });
    defer mailbox_4.deinit();

    try link.send(.init(0), 1, 3, 11);
    try link.send(.init(0), 3, 1, 22);
    try link.send(.init(0), 1, 2, 33);
    try link.send(.init(0), 4, 3, 44);
    try testing.expectEqual(@as(usize, 3), link.pendingItems().len);

    const to_3_directed = try link.deliverDueToMailbox(.init(1), 3, &mailbox_3, null);
    try testing.expectEqual(@as(u32, 1), to_3_directed.delivered_count);
    try testing.expectEqual(@as(u32, 44), try mailbox_3.recv());

    const to_2_directed = try link.deliverDueToMailbox(.init(1), 2, &mailbox_2, null);
    try testing.expectEqual(@as(u32, 1), to_2_directed.delivered_count);
    try testing.expectEqual(@as(u32, 33), try mailbox_2.recv());

    const to_1_directed = try link.deliverDueToMailbox(.init(1), 1, &mailbox_1, null);
    try testing.expectEqual(@as(u32, 1), to_1_directed.delivered_count);
    try testing.expectEqual(@as(u32, 22), try mailbox_1.recv());

    const to_4_directed = try link.deliverDueToMailbox(.init(1), 4, &mailbox_4, null);
    try testing.expectEqual(@as(u32, 0), to_4_directed.delivered_count);
    try testing.expectEqual(@as(usize, 0), link.pendingItems().len);

    try link.setPartitionMode(.{
        .partition_groups = .{
            .from_nodes = &left_group,
            .to_nodes = &right_group,
            .bidirectional = true,
        },
    });

    try link.send(.init(1), 2, 4, 55);
    try link.send(.init(1), 4, 2, 66);
    try testing.expectEqual(@as(usize, 0), link.pendingItems().len);
}

test "network link supports asymmetric route-specific drops" {
    var storage: [4]Delivery(u32) = undefined;
    const rules = [_]FaultRule{
        .{
            .route = .{
                .source_id = 7,
                .destination_id = 11,
            },
            .effect = .{ .drop = {} },
        },
    };
    var link = try NetworkLink(u32).init(&storage, .{
        .default_delay = .init(1),
        .fault_rules = &rules,
    });
    var destination_11 = try mailbox.Mailbox(u32).init(testing.allocator, .{ .capacity = 2 });
    defer destination_11.deinit();
    var destination_7 = try mailbox.Mailbox(u32).init(testing.allocator, .{ .capacity = 2 });
    defer destination_7.deinit();

    try link.send(.init(0), 7, 11, 99);
    try link.send(.init(0), 11, 7, 42);
    try testing.expectEqual(@as(usize, 1), link.pendingItems().len);

    const to_11 = try link.deliverDueToMailbox(.init(1), 11, &destination_11, null);
    try testing.expectEqual(@as(u32, 0), to_11.delivered_count);

    const to_7 = try link.deliverDueToMailbox(.init(1), 7, &destination_7, null);
    try testing.expectEqual(@as(u32, 1), to_7.delivered_count);
    try testing.expectEqual(@as(u32, 42), try destination_7.recv());
}

test "network link supports route-specific extra delay" {
    var storage: [2]Delivery(u32) = undefined;
    const rules = [_]FaultRule{
        .{
            .route = .{
                .destination_id = 11,
            },
            .effect = .{ .add_delay = .init(2) },
        },
    };
    var link = try NetworkLink(u32).init(&storage, .{
        .default_delay = .init(1),
        .fault_rules = &rules,
    });
    var destination = try mailbox.Mailbox(u32).init(testing.allocator, .{ .capacity = 2 });
    defer destination.deinit();

    try link.send(.init(0), 7, 11, 88);

    const early = try link.deliverDueToMailbox(.init(2), 11, &destination, null);
    try testing.expectEqual(@as(u32, 0), early.delivered_count);
    try testing.expectEqual(@as(usize, 1), link.pendingItems().len);

    const on_time = try link.deliverDueToMailbox(.init(3), 11, &destination, null);
    try testing.expectEqual(@as(u32, 1), on_time.delivered_count);
    try testing.expectEqual(@as(u32, 88), try destination.recv());
}

test "network link supports route-specific congestion windows" {
    var storage: [2]Delivery(u32) = undefined;
    const windows = [_]CongestionWindow{
        .{
            .route = .{
                .destination_id = 11,
            },
            .active_from = .init(1),
            .active_until = .init(4),
        },
    };
    var link = try NetworkLink(u32).init(&storage, .{
        .default_delay = .init(1),
        .congestion_windows = &windows,
    });
    var destination = try mailbox.Mailbox(u32).init(testing.allocator, .{ .capacity = 2 });
    defer destination.deinit();

    try link.send(.init(0), 7, 11, 88);

    const early = try link.deliverDueToMailbox(.init(3), 11, &destination, null);
    try testing.expectEqual(@as(u32, 0), early.delivered_count);
    try testing.expectEqual(@as(usize, 1), link.pendingItems().len);

    const released = try link.deliverDueToMailbox(.init(4), 11, &destination, null);
    try testing.expectEqual(@as(u32, 1), released.delivered_count);
    try testing.expectEqual(@as(u32, 88), try destination.recv());
}

test "network link backlog policy can drop the newest saturated send" {
    var storage: [3]Delivery(u32) = undefined;
    const policies = [_]BacklogPolicy{
        .{
            .route = .{ .destination_id = 11 },
            .max_pending = 1,
            .overflow = .drop_newest,
        },
    };
    var link = try NetworkLink(u32).init(&storage, .{
        .default_delay = .init(1),
        .backlog_policies = &policies,
    });
    var destination = try mailbox.Mailbox(u32).init(testing.allocator, .{ .capacity = 2 });
    defer destination.deinit();

    try link.send(.init(0), 1, 11, 88);
    try link.send(.init(0), 2, 11, 99);
    try testing.expectEqual(@as(usize, 1), link.pendingItems().len);

    const delivered = try link.deliverDueToMailbox(.init(1), 11, &destination, null);
    try testing.expectEqual(@as(u32, 1), delivered.delivered_count);
    try testing.expectEqual(@as(u32, 88), try destination.recv());
}

test "network link backlog policy can drop the oldest saturated send" {
    var storage: [3]Delivery(u32) = undefined;
    const policies = [_]BacklogPolicy{
        .{
            .route = .{ .destination_id = 11 },
            .max_pending = 1,
            .overflow = .drop_oldest,
        },
    };
    var link = try NetworkLink(u32).init(&storage, .{
        .default_delay = .init(1),
        .backlog_policies = &policies,
    });
    var destination = try mailbox.Mailbox(u32).init(testing.allocator, .{ .capacity = 2 });
    defer destination.deinit();

    try link.send(.init(0), 1, 11, 88);
    try link.send(.init(0), 2, 11, 99);
    try testing.expectEqual(@as(usize, 1), link.pendingItems().len);
    try testing.expectEqual(@as(u32, 2), link.pendingItems()[0].source_id);

    const delivered = try link.deliverDueToMailbox(.init(1), 11, &destination, null);
    try testing.expectEqual(@as(u32, 1), delivered.delivered_count);
    try testing.expectEqual(@as(u32, 99), try destination.recv());
}

test "network link backlog policy can reject saturated sends" {
    var storage: [3]Delivery(u32) = undefined;
    const policies = [_]BacklogPolicy{
        .{
            .route = .{ .destination_id = 11 },
            .max_pending = 1,
            .overflow = .reject_new,
        },
    };
    var link = try NetworkLink(u32).init(&storage, .{
        .default_delay = .init(1),
        .backlog_policies = &policies,
    });
    var destination = try mailbox.Mailbox(u32).init(testing.allocator, .{ .capacity = 2 });
    defer destination.deinit();

    try link.send(.init(0), 1, 11, 88);
    try testing.expectError(error.NoSpaceLeft, link.send(.init(0), 2, 11, 99));
    try testing.expectEqual(@as(usize, 1), link.pendingItems().len);

    const delivered = try link.deliverDueToMailbox(.init(1), 11, &destination, null);
    try testing.expectEqual(@as(u32, 1), delivered.delivered_count);
    try testing.expectEqual(@as(u32, 88), try destination.recv());
}

test "network link can record and replay pending deliveries after fault resolution" {
    var source_storage: [4]Delivery(u32) = undefined;
    const fault_rules = [_]FaultRule{
        .{
            .route = .{ .destination_id = 9 },
            .effect = .{ .add_delay = .init(2) },
        },
        .{
            .route = .{ .source_id = 5, .destination_id = 7 },
            .effect = .{ .drop = {} },
        },
    };
    const congestion_windows = [_]CongestionWindow{
        .{
            .route = .{ .destination_id = 11 },
            .active_from = .init(1),
            .active_until = .init(4),
        },
    };
    var source_link = try NetworkLink(u32).init(&source_storage, .{
        .default_delay = .init(1),
        .fault_rules = &fault_rules,
        .congestion_windows = &congestion_windows,
    });

    try source_link.send(.init(0), 1, 9, 99);
    try source_link.send(.init(0), 2, 11, 111);
    try source_link.send(.init(0), 5, 7, 77);
    try testing.expectEqual(@as(usize, 2), source_link.pendingItems().len);

    var recorded_storage: [4]Delivery(u32) = undefined;
    const recorded = try source_link.recordPending(&recorded_storage);
    try testing.expectEqual(@as(usize, 2), recorded.len);
    try testing.expectEqual(@as(u64, 3), recorded[0].due_time.tick);
    try testing.expectEqual(@as(u64, 4), recorded[1].due_time.tick);

    var replay_storage: [4]Delivery(u32) = undefined;
    var replay_link = try NetworkLink(u32).init(&replay_storage, .{
        .default_delay = .init(9),
        .partition_mode = .drop_all,
    });
    try replay_link.replayRecordedPending(recorded);

    var mailbox_9 = try mailbox.Mailbox(u32).init(testing.allocator, .{ .capacity = 2 });
    defer mailbox_9.deinit();
    var mailbox_11 = try mailbox.Mailbox(u32).init(testing.allocator, .{ .capacity = 2 });
    defer mailbox_11.deinit();

    const early_9 = try replay_link.deliverDueToMailbox(.init(2), 9, &mailbox_9, null);
    try testing.expectEqual(@as(u32, 0), early_9.delivered_count);
    const on_time_9 = try replay_link.deliverDueToMailbox(.init(3), 9, &mailbox_9, null);
    try testing.expectEqual(@as(u32, 1), on_time_9.delivered_count);
    try testing.expectEqual(@as(u32, 99), try mailbox_9.recv());

    const early_11 = try replay_link.deliverDueToMailbox(.init(3), 11, &mailbox_11, null);
    try testing.expectEqual(@as(u32, 0), early_11.delivered_count);
    const on_time_11 = try replay_link.deliverDueToMailbox(.init(4), 11, &mailbox_11, null);
    try testing.expectEqual(@as(u32, 1), on_time_11.delivered_count);
    try testing.expectEqual(@as(u32, 111), try mailbox_11.recv());
}

test "network link rejects fault rules without a route selector" {
    var storage: [1]Delivery(u32) = undefined;
    const rules = [_]FaultRule{
        .{
            .route = .{},
            .effect = .{ .drop = {} },
        },
    };

    try testing.expectError(error.InvalidConfig, NetworkLink(u32).init(&storage, .{
        .default_delay = .init(1),
        .fault_rules = &rules,
    }));
}

test "network link rejects congestion windows without a route selector" {
    var storage: [1]Delivery(u32) = undefined;
    const windows = [_]CongestionWindow{
        .{
            .route = .{},
            .active_from = .init(1),
            .active_until = .init(2),
        },
    };

    try testing.expectError(error.InvalidConfig, NetworkLink(u32).init(&storage, .{
        .default_delay = .init(1),
        .congestion_windows = &windows,
    }));
}

test "network link rejects empty or backwards congestion windows" {
    var storage: [1]Delivery(u32) = undefined;
    const windows = [_]CongestionWindow{
        .{
            .route = .{ .destination_id = 11 },
            .active_from = .init(2),
            .active_until = .init(2),
        },
    };

    try testing.expectError(error.InvalidConfig, NetworkLink(u32).init(&storage, .{
        .default_delay = .init(1),
        .congestion_windows = &windows,
    }));
}

test "network link rejects invalid backlog policies" {
    var storage: [1]Delivery(u32) = undefined;
    const invalid_selector = [_]BacklogPolicy{
        .{
            .route = .{},
            .max_pending = 1,
            .overflow = .drop_newest,
        },
    };
    const invalid_capacity = [_]BacklogPolicy{
        .{
            .route = .{ .destination_id = 11 },
            .max_pending = 0,
            .overflow = .drop_newest,
        },
    };

    try testing.expectError(error.InvalidConfig, NetworkLink(u32).init(&storage, .{
        .default_delay = .init(1),
        .backlog_policies = &invalid_selector,
    }));
    try testing.expectError(error.InvalidConfig, NetworkLink(u32).init(&storage, .{
        .default_delay = .init(1),
        .backlog_policies = &invalid_capacity,
    }));
}

test "network link rejects isolate-node partitions with invalid node id" {
    var storage: [1]Delivery(u32) = undefined;

    try testing.expectError(error.InvalidConfig, NetworkLink(u32).init(&storage, .{
        .default_delay = .init(1),
        .partition_mode = .{ .isolate_node = 0 },
    }));
}

test "network link rejects invalid group partitions" {
    var storage: [1]Delivery(u32) = undefined;
    const valid_nodes = [_]u32{1};
    const invalid_nodes = [_]u32{0};

    try testing.expectError(error.InvalidConfig, NetworkLink(u32).init(&storage, .{
        .default_delay = .init(1),
        .partition_mode = .{
            .partition_groups = .{
                .from_nodes = &.{},
                .to_nodes = &valid_nodes,
            },
        },
    }));

    try testing.expectError(error.InvalidConfig, NetworkLink(u32).init(&storage, .{
        .default_delay = .init(1),
        .partition_mode = .{
            .partition_groups = .{
                .from_nodes = &valid_nodes,
                .to_nodes = &invalid_nodes,
            },
        },
    }));
}

test "network link rejects invalid runtime partition updates" {
    var storage: [2]Delivery(u32) = undefined;
    var link = try NetworkLink(u32).init(&storage, .{
        .default_delay = .init(1),
    });
    const valid_nodes = [_]u32{1};

    try testing.expectError(error.InvalidConfig, link.setPartitionMode(.{
        .isolate_node = 0,
    }));
    try testing.expectError(error.InvalidConfig, link.setPartitionMode(.{
        .partition_groups = .{
            .from_nodes = &.{},
            .to_nodes = &valid_nodes,
        },
    }));

    try link.send(.init(0), 1, 9, 22);
    try testing.expectEqual(@as(usize, 1), link.pendingItems().len);
}

test "network link replay rejects non-empty state or invalid deliveries" {
    var storage: [2]Delivery(u32) = undefined;
    var link = try NetworkLink(u32).init(&storage, .{
        .default_delay = .init(1),
    });
    try link.send(.init(0), 1, 9, 22);

    const recorded = [_]Delivery(u32){
        .{
            .source_id = 1,
            .destination_id = 9,
            .due_time = .init(1),
            .payload = 22,
        },
    };
    try testing.expectError(error.InvalidInput, link.replayRecordedPending(&recorded));

    var empty_storage: [1]Delivery(u32) = undefined;
    var empty_link = try NetworkLink(u32).init(&empty_storage, .{
        .default_delay = .init(1),
    });
    const invalid = [_]Delivery(u32){
        .{
            .source_id = 1,
            .destination_id = 0,
            .due_time = .init(1),
            .payload = 22,
        },
    };
    try testing.expectError(error.InvalidInput, empty_link.replayRecordedPending(&invalid));

    var small_record_buffer: [0]Delivery(u32) = .{};
    try testing.expectError(error.NoSpaceLeft, link.recordPending(&small_record_buffer));
}

test "network link can trace deliveries and preserve source metadata" {
    var storage: [2]Delivery(u32) = undefined;
    var link = try NetworkLink(u32).init(&storage, .{
        .default_delay = .init(1),
    });
    var destination = try mailbox.Mailbox(u32).init(testing.allocator, .{ .capacity = 2 });
    defer destination.deinit();
    var trace_storage: [2]trace.TraceEvent = undefined;
    var trace_buffer = try trace.TraceBuffer.init(&trace_storage, .{ .max_events = 2 });

    try link.send(.init(0), 44, 9, 77);
    _ = try link.deliverDueToMailbox(.init(1), 9, &destination, &trace_buffer);

    const snapshot = trace_buffer.snapshot();
    try testing.expectEqual(@as(usize, 1), snapshot.items.len);
    try testing.expectEqualStrings("network_link.deliver", snapshot.items[0].label);
    try testing.expectEqual(@as(u64, 9), snapshot.items[0].value);
    try testing.expectEqual(@as(?u64, 44), snapshot.items[0].lineage.correlation_id);
    try testing.expectEqualStrings("network_link", snapshot.items[0].lineage.surface_label.?);
}

test "network link leaves pending delivery untouched when trace capacity is exhausted" {
    var storage: [2]Delivery(u32) = undefined;
    var link = try NetworkLink(u32).init(&storage, .{
        .default_delay = .init(1),
    });
    var destination = try mailbox.Mailbox(u32).init(testing.allocator, .{ .capacity = 2 });
    defer destination.deinit();
    var trace_storage: [1]trace.TraceEvent = undefined;
    var trace_buffer = try trace.TraceBuffer.init(&trace_storage, .{ .max_events = 1 });
    try trace_buffer.append(.{
        .timestamp_ns = 0,
        .category = .info,
        .label = "prefill",
        .value = 0,
    });

    try link.send(.init(0), 44, 9, 77);
    try testing.expectError(
        error.NoSpaceLeft,
        link.deliverDueToMailbox(.init(1), 9, &destination, &trace_buffer),
    );
    try testing.expectEqual(@as(usize, 1), link.pendingItems().len);
    try testing.expectEqual(@as(usize, 0), destination.len());

    trace_buffer.reset();
    const delivered = try link.deliverDueToMailbox(.init(1), 9, &destination, &trace_buffer);
    try testing.expectEqual(@as(u32, 1), delivered.delivered_count);
    try testing.expectEqual(@as(usize, 0), link.pendingItems().len);
    try testing.expectEqual(@as(u32, 77), try destination.recv());
}
