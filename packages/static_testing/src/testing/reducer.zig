//! Deterministic fixed-point reduction helpers.
//!
//! The reducer driver is intentionally generic and bounded:
//! - the caller defines the candidate type;
//! - the caller defines the monotonic size metric; and
//! - the caller decides whether a candidate remains "interesting".

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const core = @import("static_core");

/// Budget validation errors for reduction runs.
pub const ReductionBudgetError = error{
    InvalidInput,
};

/// Hard bounds for one deterministic reduction session.
pub const ReductionBudget = struct {
    max_attempts: u32,
    max_successes: u32,
};

/// Final reduction status.
pub const ReduceStep = enum(u8) {
    fixed_point = 1,
    budget_exhausted = 2,
};

/// Generic fixed-point reduction result.
pub fn ReductionResult(comptime Candidate: type) type {
    return struct {
        candidate: Candidate,
        step: ReduceStep,
        attempts_total: u32,
        successes_total: u32,
    };
}

/// Generic reducer callback contract.
///
/// Candidates are passed by value through the callback surface. For large
/// candidate structs, prefer using a pointer or handle type as `Candidate`
/// (for example, `*const LargeCandidate`) so the reducer does not introduce
/// repeated large copies into the control plane.
pub fn Reducer(comptime Candidate: type, comptime ReduceError: type) type {
    return struct {
        context: *const anyopaque,
        measure_fn: *const fn (context: *const anyopaque, candidate: Candidate) u64,
        next_fn: *const fn (
            context: *const anyopaque,
            current: Candidate,
            attempt_index: u32,
        ) ReduceError!?Candidate,
        is_interesting_fn: *const fn (
            context: *const anyopaque,
            candidate: Candidate,
        ) ReduceError!bool,

        pub fn measure(self: @This(), candidate: Candidate) u64 {
            return self.measure_fn(self.context, candidate);
        }

        pub fn next(
            self: @This(),
            current: Candidate,
            attempt_index: u32,
        ) ReduceError!?Candidate {
            return self.next_fn(self.context, current, attempt_index);
        }

        pub fn isInteresting(self: @This(), candidate: Candidate) ReduceError!bool {
            return self.is_interesting_fn(self.context, candidate);
        }
    };
}

comptime {
    core.errors.assertVocabularySubset(ReductionBudgetError);
    assert(std.meta.fields(ReduceStep).len == 2);
}

/// Run a deterministic reducer until it reaches a fixed point or a budget limit.
pub fn reduceUntilFixedPoint(
    comptime Candidate: type,
    comptime ReduceError: type,
    reducer: Reducer(Candidate, ReduceError),
    initial_candidate: Candidate,
    budget: ReductionBudget,
) (ReductionBudgetError || ReduceError)!ReductionResult(Candidate) {
    try validateBudget(budget);

    var candidate = initial_candidate;
    var candidate_measure = reducer.measure(candidate);
    var attempts_total: u32 = 0;
    var successes_total: u32 = 0;

    while (attempts_total < budget.max_attempts and successes_total < budget.max_successes) {
        const next_candidate = try reducer.next(candidate, attempts_total);
        attempts_total += 1;

        if (next_candidate) |candidate_next| {
            const measure_next = reducer.measure(candidate_next);
            assert(measure_next < candidate_measure);

            if (try reducer.isInteresting(candidate_next)) {
                candidate = candidate_next;
                candidate_measure = measure_next;
                successes_total += 1;
            }
        } else {
            return .{
                .candidate = candidate,
                .step = .fixed_point,
                .attempts_total = attempts_total,
                .successes_total = successes_total,
            };
        }
    }

    return .{
        .candidate = candidate,
        .step = .budget_exhausted,
        .attempts_total = attempts_total,
        .successes_total = successes_total,
    };
}

fn validateBudget(budget: ReductionBudget) ReductionBudgetError!void {
    if (budget.max_attempts == 0) return error.InvalidInput;
    if (budget.max_successes == 0) return error.InvalidInput;
}

test "reducer step enum contains only reachable terminal states" {
    try testing.expectEqual(@as(usize, 2), std.meta.fields(ReduceStep).len);
    try testing.expectEqual(ReduceStep.fixed_point, @as(ReduceStep, .fixed_point));
    try testing.expectEqual(ReduceStep.budget_exhausted, @as(ReduceStep, .budget_exhausted));
}

test "reduceUntilFixedPoint reaches a fixed point under a monotonic reducer" {
    const Context = struct {
        fn measure(_: *const anyopaque, candidate: u32) u64 {
            return candidate;
        }

        fn next(_: *const anyopaque, current: u32, _: u32) error{}!?u32 {
            if (current <= 1) return null;
            return @divFloor(current, 2);
        }

        fn isInteresting(_: *const anyopaque, _: u32) error{}!bool {
            return true;
        }
    };

    const result = try reduceUntilFixedPoint(u32, error{}, .{
        .context = undefined,
        .measure_fn = Context.measure,
        .next_fn = Context.next,
        .is_interesting_fn = Context.isInteresting,
    }, 64, .{
        .max_attempts = 16,
        .max_successes = 16,
    });

    try testing.expectEqual(@as(u32, 1), result.candidate);
    try testing.expectEqual(ReduceStep.fixed_point, result.step);
    try testing.expectEqual(@as(u32, 6), result.successes_total);
}

test "reduceUntilFixedPoint stops when the reduction budget is exhausted" {
    const Context = struct {
        fn measure(_: *const anyopaque, candidate: u32) u64 {
            return candidate;
        }

        fn next(_: *const anyopaque, current: u32, _: u32) error{}!?u32 {
            return current - 1;
        }

        fn isInteresting(_: *const anyopaque, _: u32) error{}!bool {
            return true;
        }
    };

    const result = try reduceUntilFixedPoint(u32, error{}, .{
        .context = undefined,
        .measure_fn = Context.measure,
        .next_fn = Context.next,
        .is_interesting_fn = Context.isInteresting,
    }, 10, .{
        .max_attempts = 8,
        .max_successes = 2,
    });

    try testing.expectEqual(@as(u32, 8), result.candidate);
    try testing.expectEqual(ReduceStep.budget_exhausted, result.step);
    try testing.expectEqual(@as(u32, 2), result.successes_total);
}

test "reduceUntilFixedPoint rejects zero budgets" {
    const Context = struct {
        fn measure(_: *const anyopaque, candidate: u32) u64 {
            return candidate;
        }

        fn next(_: *const anyopaque, current: u32, _: u32) error{}!?u32 {
            return current - 1;
        }

        fn isInteresting(_: *const anyopaque, _: u32) error{}!bool {
            return true;
        }
    };

    try testing.expectError(
        error.InvalidInput,
        reduceUntilFixedPoint(u32, error{}, .{
            .context = undefined,
            .measure_fn = Context.measure,
            .next_fn = Context.next,
            .is_interesting_fn = Context.isInteresting,
        }, 5, .{
            .max_attempts = 0,
            .max_successes = 1,
        }),
    );
}
