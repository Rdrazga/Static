const testing = @import("static_testing");

const fuzz_runner = testing.testing.fuzz_runner;
const identity = testing.testing.identity;
const reducer_mod = testing.testing.reducer;
const seed_mod = testing.testing.seed;

pub fn SeedReducerContext(
    comptime TargetContext: type,
    comptime run_fn: *const fn (
        context: *const anyopaque,
        run_identity: identity.RunIdentity,
    ) error{}!fuzz_runner.FuzzExecution,
) type {
    return struct {
        target_context: *const TargetContext,
        config: fuzz_runner.FuzzConfig,

        pub fn buildReducer(self: *const @This()) reducer_mod.Reducer(seed_mod.Seed, error{}) {
            return .{
                .context = self,
                .measure_fn = @This().measure,
                .next_fn = @This().next,
                .is_interesting_fn = @This().isInteresting,
            };
        }

        fn measure(_: *const anyopaque, candidate: seed_mod.Seed) u64 {
            return candidate.value;
        }

        fn next(_: *const anyopaque, current: seed_mod.Seed, attempt_index: u32) error{}!?seed_mod.Seed {
            if (current.value == 0) return null;

            const shift = 1 + @as(u6, @intCast(@min(attempt_index, 62)));
            const candidate = current.value >> shift;
            if (candidate == current.value) return null;
            return seed_mod.Seed.init(candidate);
        }

        fn isInteresting(context_ptr: *const anyopaque, candidate: seed_mod.Seed) error{}!bool {
            const context: *const @This() = @ptrCast(@alignCast(context_ptr));
            const execution = try run_fn(
                context.target_context,
                makeReductionIdentity(context.config, candidate),
            );
            return !execution.check_result.passed;
        }
    };
}

fn makeReductionIdentity(
    config: fuzz_runner.FuzzConfig,
    candidate: seed_mod.Seed,
) identity.RunIdentity {
    return identity.makeRunIdentity(.{
        .package_name = config.package_name,
        .run_name = config.run_name,
        .seed = candidate,
        .artifact_version = .v1,
        .build_mode = config.build_mode,
        .case_index = 0,
        .run_index = 0,
    });
}
