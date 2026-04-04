//! Grant: typed access-level token for capability-based authorization.
//!
//! Thread safety: grants are immutable values; safe to copy and read from any thread.
//! Single-threaded mode: no behavioral difference.
//! Ownership note: this is retained in `static_sync` because runtime-facing
//! packages often need bounded capability scopes alongside coordination state.
//! It is a capability contract, not a thread primitive.
const std = @import("std");

pub const Access = enum(u2) {
    none = 0,
    read = 1,
    write = 2,

    pub fn allowsRead(self: Access) bool {
        return self == .read or self == .write;
    }

    pub fn allowsWrite(self: Access) bool {
        return self == .write;
    }

    pub fn combine(existing: Access, requested: Access) Access {
        if (requested == .none) return existing;
        return switch (existing) {
            .none => requested,
            .read => switch (requested) {
                .none => .read,
                .read => .read,
                .write => .write,
            },
            .write => .write,
        };
    }
};

comptime {
    std.debug.assert(@intFromEnum(Access.none) == 0);
    std.debug.assert(@intFromEnum(Access.read) == 1);
    std.debug.assert(@intFromEnum(Access.write) == 2);
}

pub const GrantError = error{
    GrantInactive,
    AccessDenied,
    NoSpaceLeft,
};

pub const CapabilityToken = struct {
    grant_id: u64,
    grant_epoch: u64,
    resource_id: u64,
    access: Access,
    consume: bool,
};

/// Compile-time bounded grant token.
///
/// Grants are explicit capability scopes that track per-resource permissions
/// and write records with fixed upper bounds and no allocation.
pub fn Grant(comptime max_resources: usize, comptime max_writes: usize) type {
    comptime {
        if (max_resources == 0) @compileError("Grant requires max_resources > 0.");
        if (max_writes == 0) @compileError("Grant requires max_writes > 0.");
    }

    return struct {
        const Self = @This();

        const ResourceGrant = struct {
            resource_id: u64,
            access: Access,
            consume: bool = false,
        };

        const WriteRecord = struct {
            resource_id: u64,
            instance_id: u64,
        };

        id: u64,
        epoch: u64 = 0,
        active: bool = true,
        resource_count: usize = 0,
        resources: [max_resources]ResourceGrant = undefined,
        write_count: usize = 0,
        writes: [max_writes]WriteRecord = undefined,

        pub fn begin(id: u64) Self {
            const initial_grant = Self{
                .id = id,
                .epoch = 0,
            };
            std.debug.assert(initial_grant.active);
            std.debug.assert(initial_grant.epoch == 0);
            std.debug.assert(initial_grant.resource_count == 0);
            std.debug.assert(initial_grant.write_count == 0);
            return initial_grant;
        }

        pub fn end(self: *Self) void {
            std.debug.assert(self.resource_count <= max_resources);
            std.debug.assert(self.write_count <= max_writes);
            self.active = false;
            self.resource_count = 0;
            self.write_count = 0;
            std.debug.assert(!self.active);
            std.debug.assert(self.resource_count == 0);
            std.debug.assert(self.write_count == 0);
        }

        pub fn reset(self: *Self, id: u64) void {
            const previous_epoch = self.epoch;
            self.epoch +%= 1;
            self.id = id;
            self.active = true;
            self.resource_count = 0;
            self.write_count = 0;
            std.debug.assert(self.active);
            std.debug.assert(self.id == id);
            std.debug.assert(self.epoch != previous_epoch or previous_epoch == std.math.maxInt(u64));
            std.debug.assert(self.resource_count == 0);
            std.debug.assert(self.write_count == 0);
        }

        pub fn isActive(self: *const Self) bool {
            // Invariant: resource_count and write_count are only non-zero when
            // the grant is active; an inactive grant must have both zeroed by end().
            if (!self.active) {
                std.debug.assert(self.resource_count == 0);
                std.debug.assert(self.write_count == 0);
            }
            return self.active;
        }

        pub fn grantRead(self: *Self, resource_id: u64) GrantError!void {
            try self.grant(resource_id, .read, false);
            std.debug.assert(self.canRead(resource_id));
        }

        pub fn grantWrite(self: *Self, resource_id: u64) GrantError!void {
            try self.grant(resource_id, .write, false);
            std.debug.assert(self.canWrite(resource_id));
        }

        pub fn grantConsume(self: *Self, resource_id: u64) GrantError!void {
            try self.grant(resource_id, .write, true);
            std.debug.assert(self.canWrite(resource_id));
            std.debug.assert(self.canConsume(resource_id));
        }

        pub fn canRead(self: *const Self, resource_id: u64) bool {
            const result = self.hasAccess(resource_id, .read);
            // Postcondition: if the grant is inactive no access is ever granted.
            if (!self.active) std.debug.assert(!result);
            // Postcondition: write access implies read access -- check via hasAccess
            // directly to avoid mutual recursion with canWrite.
            if (self.hasAccess(resource_id, .write)) std.debug.assert(result);
            return result;
        }

        pub fn canWrite(self: *const Self, resource_id: u64) bool {
            const result = self.hasAccess(resource_id, .write);
            // Postcondition: if the grant is inactive no write access is granted.
            if (!self.active) std.debug.assert(!result);
            // Postcondition: write access must imply read access -- check via
            // hasAccess directly to avoid mutual recursion with canRead.
            if (result) std.debug.assert(self.hasAccess(resource_id, .read));
            return result;
        }

        pub fn canConsume(self: *const Self, resource_id: u64) bool {
            if (!self.active) return false;
            const index = self.findResourceIndex(resource_id) orelse return false;
            std.debug.assert(index < self.resource_count);
            return self.resources[index].consume;
        }

        pub fn requireRead(self: *const Self, resource_id: u64) GrantError!void {
            if (!self.active) return error.GrantInactive;
            if (!self.canRead(resource_id)) return error.AccessDenied;
            std.debug.assert(self.canRead(resource_id));
        }

        pub fn requireWrite(self: *const Self, resource_id: u64) GrantError!void {
            if (!self.active) return error.GrantInactive;
            if (!self.canWrite(resource_id)) return error.AccessDenied;
            std.debug.assert(self.canWrite(resource_id));
        }

        pub fn requireConsume(self: *const Self, resource_id: u64) GrantError!void {
            if (!self.active) return error.GrantInactive;
            if (!self.canConsume(resource_id)) return error.AccessDenied;
            std.debug.assert(self.canConsume(resource_id));
        }

        pub fn issueToken(
            self: *const Self,
            resource_id: u64,
            required_access: Access,
        ) GrantError!CapabilityToken {
            if (!self.active) return error.GrantInactive;
            if (!self.hasAccess(resource_id, required_access)) return error.AccessDenied;

            const token = CapabilityToken{
                .grant_id = self.id,
                .grant_epoch = self.epoch,
                .resource_id = resource_id,
                .access = required_access,
                .consume = self.canConsume(resource_id),
            };
            std.debug.assert(token.grant_id == self.id);
            std.debug.assert(token.grant_epoch == self.epoch);
            std.debug.assert(token.resource_id == resource_id);
            std.debug.assert(token.access == required_access);
            if (token.consume) std.debug.assert(self.canConsume(resource_id));
            return token;
        }

        pub fn issueConsumeToken(self: *const Self, resource_id: u64) GrantError!CapabilityToken {
            if (!self.active) return error.GrantInactive;
            if (!self.canConsume(resource_id)) return error.AccessDenied;

            const token = try self.issueToken(resource_id, .write);
            std.debug.assert(token.consume);
            return token;
        }

        pub fn validateToken(
            self: *const Self,
            token: CapabilityToken,
            required_access: Access,
        ) bool {
            if (!self.active) return false;
            if (token.grant_id != self.id) return false;
            if (token.grant_epoch != self.epoch) return false;
            if (!accessSatisfies(token.access, required_access)) return false;
            if (token.consume and !self.canConsume(token.resource_id)) return false;
            const has_required_access = self.hasAccess(token.resource_id, required_access);
            if (has_required_access) {
                std.debug.assert(accessSatisfies(token.access, required_access));
                if (token.consume) std.debug.assert(self.canConsume(token.resource_id));
            }
            return has_required_access;
        }

        pub fn validateConsumeToken(self: *const Self, token: CapabilityToken) bool {
            if (!self.validateToken(token, .write)) return false;
            if (!token.consume) return false;
            return self.canConsume(token.resource_id);
        }

        pub fn recordWrite(self: *Self, resource_id: u64, instance_id: u64) GrantError!void {
            if (!self.active) return error.GrantInactive;
            if (!self.canWrite(resource_id)) return error.AccessDenied;
            if (self.wasWritten(resource_id, instance_id)) return;
            if (self.write_count >= max_writes) return error.NoSpaceLeft;

            self.writes[self.write_count] = .{
                .resource_id = resource_id,
                .instance_id = instance_id,
            };
            self.write_count += 1;
            std.debug.assert(self.write_count <= max_writes);
            std.debug.assert(self.wasWritten(resource_id, instance_id));
        }

        pub fn wasWritten(self: *const Self, resource_id: u64, instance_id: u64) bool {
            if (!self.active) return false;
            std.debug.assert(self.write_count <= max_writes);

            var write_index: usize = 0;
            while (write_index < self.write_count) : (write_index += 1) {
                const write_record = self.writes[write_index];
                if (write_record.resource_id != resource_id) continue;
                if (write_record.instance_id == instance_id) return true;
            }
            return false;
        }

        pub fn writtenCount(self: *const Self) usize {
            std.debug.assert(self.write_count <= max_writes);
            return self.write_count;
        }

        fn grant(
            self: *Self,
            resource_id: u64,
            requested_access: Access,
            consume_requested: bool,
        ) GrantError!void {
            if (!self.active) return error.GrantInactive;
            std.debug.assert(self.resource_count <= max_resources);
            std.debug.assert(requested_access != .none);

            if (self.findResourceIndex(resource_id)) |index| {
                const current = self.resources[index];
                self.resources[index] = .{
                    .resource_id = current.resource_id,
                    .access = Access.combine(current.access, requested_access),
                    .consume = current.consume or consume_requested,
                };
                std.debug.assert(accessSatisfies(self.resources[index].access, requested_access));
                if (consume_requested) std.debug.assert(self.resources[index].consume);
                return;
            }

            if (self.resource_count >= max_resources) return error.NoSpaceLeft;
            self.resources[self.resource_count] = .{
                .resource_id = resource_id,
                .access = requested_access,
                .consume = consume_requested,
            };
            self.resource_count += 1;
            std.debug.assert(self.resource_count <= max_resources);
            std.debug.assert(self.findResourceIndex(resource_id) != null);
        }

        fn hasAccess(self: *const Self, resource_id: u64, required_access: Access) bool {
            if (!self.active) return false;
            std.debug.assert(self.resource_count <= max_resources);
            const index = self.findResourceIndex(resource_id) orelse return false;
            std.debug.assert(index < self.resource_count);
            const granted_access = self.resources[index].access;
            return accessSatisfies(granted_access, required_access);
        }

        fn findResourceIndex(self: *const Self, resource_id: u64) ?usize {
            std.debug.assert(self.resource_count <= max_resources);
            var resource_index: usize = 0;
            while (resource_index < self.resource_count) : (resource_index += 1) {
                if (self.resources[resource_index].resource_id == resource_id) {
                    return resource_index;
                }
            }
            return null;
        }
    };
}

fn accessSatisfies(granted: Access, required: Access) bool {
    const satisfies = switch (required) {
        .none => true,
        .read => granted.allowsRead(),
        .write => granted.allowsWrite(),
    };
    if (required == .write) std.debug.assert(satisfies == granted.allowsWrite());
    return satisfies;
}

test "access combine merges to strongest permission" {
    // Goal: verify access lattice merges toward stronger privilege.
    // Method: evaluate representative pair combinations.
    try std.testing.expectEqual(Access.none, Access.combine(.none, .none));
    try std.testing.expectEqual(Access.read, Access.combine(.none, .read));
    try std.testing.expectEqual(Access.write, Access.combine(.none, .write));
    try std.testing.expectEqual(Access.read, Access.combine(.read, .read));
    try std.testing.expectEqual(Access.write, Access.combine(.read, .write));
    try std.testing.expectEqual(Access.write, Access.combine(.write, .read));
}

test "grant permissions and requirements" {
    // Goal: verify read/write grants map to checks and requirements.
    // Method: incrementally grant capabilities and assert outcomes.
    var grant = Grant(8, 8).begin(1);
    try std.testing.expect(grant.isActive());
    try std.testing.expect(!grant.canRead(42));
    try std.testing.expect(!grant.canWrite(42));

    try grant.grantRead(42);
    try std.testing.expect(grant.canRead(42));
    try std.testing.expect(!grant.canWrite(42));
    try grant.requireRead(42);
    try std.testing.expectError(error.AccessDenied, grant.requireWrite(42));

    try grant.grantWrite(42);
    try std.testing.expect(grant.canWrite(42));
    try grant.requireWrite(42);
}

test "grant consume implies write and is queryable" {
    // Goal: verify consume grant includes write semantics.
    // Method: grant consume and evaluate consume/write checks.
    var grant = Grant(8, 8).begin(1);
    try std.testing.expect(!grant.canConsume(11));
    try grant.grantConsume(11);
    try std.testing.expect(grant.canConsume(11));
    try std.testing.expect(grant.canWrite(11));
    try grant.requireConsume(11);
}

test "grant resource capacity is bounded" {
    // Goal: verify resource grants respect fixed capacity.
    // Method: fill capacity and require `NoSpaceLeft` on overflow.
    var grant = Grant(1, 8).begin(1);
    try grant.grantRead(10);
    try std.testing.expectError(error.NoSpaceLeft, grant.grantRead(20));
}

test "grant write recording requires write capability" {
    // Goal: verify write recording is deduplicated and bounded.
    // Method: record writes, repeat one write, then exceed capacity.
    var grant = Grant(8, 2).begin(1);
    try grant.grantWrite(7);
    try grant.recordWrite(7, 100);
    try std.testing.expect(grant.wasWritten(7, 100));
    try std.testing.expectEqual(@as(usize, 1), grant.writtenCount());
    try grant.recordWrite(7, 100);
    try std.testing.expectEqual(@as(usize, 1), grant.writtenCount());
    try grant.recordWrite(7, 200);
    try std.testing.expectEqual(@as(usize, 2), grant.writtenCount());
    try std.testing.expectError(error.NoSpaceLeft, grant.recordWrite(7, 300));
}

test "grant capability token issue and validation" {
    // Goal: verify token issuance and validation rules.
    // Method: validate matching token, privilege mismatch, and forged token.
    var grant = Grant(8, 8).begin(99);
    try grant.grantWrite(55);

    const token = try grant.issueToken(55, .read);
    try std.testing.expect(grant.validateToken(token, .read));
    try std.testing.expect(!grant.validateToken(token, .write));
    try std.testing.expect(!grant.validateConsumeToken(token));

    const write_token = try grant.issueToken(55, .write);
    try std.testing.expect(grant.validateToken(write_token, .read));
    try std.testing.expect(grant.validateToken(write_token, .write));
    try std.testing.expect(!grant.validateConsumeToken(write_token));

    const forged = CapabilityToken{
        .grant_id = 1,
        .grant_epoch = 0,
        .resource_id = 55,
        .access = .write,
        .consume = false,
    };
    try std.testing.expect(!grant.validateToken(forged, .write));
}

test "grant consume token issue and validation" {
    // Goal: verify consume capability survives token issuance and validation.
    // Method: issue a consume token, compare against a plain write token, then
    // reset and prove the stale consume token no longer validates.
    var grant = Grant(8, 8).begin(15);
    try grant.grantConsume(8);

    const consume_token = try grant.issueConsumeToken(8);
    try std.testing.expect(grant.validateToken(consume_token, .write));
    try std.testing.expect(grant.validateConsumeToken(consume_token));

    const write_token = try grant.issueToken(8, .write);
    try std.testing.expect(write_token.consume);
    try std.testing.expect(grant.validateConsumeToken(write_token));

    grant.reset(15);
    try std.testing.expect(!grant.validateConsumeToken(consume_token));
}

test "grant reset invalidates stale token while active" {
    // Goal: verify `reset` is a lifecycle boundary even without a prior `end`.
    // Method: issue a token, reset the active grant, then prove stale token and
    // prior write history no longer validate.
    var grant = Grant(8, 8).begin(7);
    try grant.grantWrite(3);
    try grant.recordWrite(3, 33);

    const stale_token = try grant.issueToken(3, .write);
    try std.testing.expect(grant.validateToken(stale_token, .write));
    try std.testing.expect(grant.wasWritten(3, 33));

    grant.reset(7);
    try std.testing.expect(grant.isActive());
    try std.testing.expect(!grant.validateToken(stale_token, .write));
    try std.testing.expect(!grant.canRead(3));
    try std.testing.expect(!grant.canWrite(3));
    try std.testing.expect(!grant.wasWritten(3, 33));
    try std.testing.expectEqual(@as(usize, 0), grant.writtenCount());
}

test "grant inactive operations return GrantInactive" {
    // Goal: verify lifecycle state gates mutating and requiring APIs.
    // Method: end grant and call APIs that require active state.
    var grant = Grant(4, 4).begin(9);
    grant.end();

    try std.testing.expectError(error.GrantInactive, grant.grantRead(1));
    try std.testing.expectError(error.GrantInactive, grant.requireRead(1));
    try std.testing.expectError(error.GrantInactive, grant.issueToken(1, .read));
    try std.testing.expectError(error.GrantInactive, grant.recordWrite(1, 1));
}

test "grant end and reset lifecycle" {
    // Goal: verify end/reset clears state and invalidates stale tokens.
    // Method: grant/read/record, capture a token, end, reset, then regrant
    // the same resource and check the old token no longer validates.
    var grant = Grant(8, 8).begin(5);
    try grant.grantRead(1);
    try grant.grantWrite(1);
    try grant.recordWrite(1, 10);
    const stale_token = try grant.issueToken(1, .write);
    try std.testing.expect(grant.validateToken(stale_token, .write));
    try std.testing.expectEqual(@as(usize, 1), grant.writtenCount());

    grant.end();
    try std.testing.expect(!grant.isActive());
    try std.testing.expectError(error.GrantInactive, grant.grantRead(2));
    try std.testing.expectError(error.GrantInactive, grant.requireRead(1));
    try std.testing.expectEqual(@as(usize, 0), grant.writtenCount());

    grant.reset(6);
    try std.testing.expect(grant.isActive());
    try std.testing.expect(!grant.canRead(1));
    try std.testing.expectEqual(@as(usize, 0), grant.writtenCount());
    try grant.grantRead(1);
    try grant.requireRead(1);
    try std.testing.expectError(error.AccessDenied, grant.requireWrite(1));

    grant.end();
    grant.reset(5);
    try grant.grantWrite(1);
    try std.testing.expect(!grant.validateToken(stale_token, .write));
    try std.testing.expect(!grant.wasWritten(1, 10));
    try std.testing.expectEqual(@as(usize, 0), grant.writtenCount());
    try grant.recordWrite(1, 11);
    try std.testing.expect(grant.wasWritten(1, 11));
}
