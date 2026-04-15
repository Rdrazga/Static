# Zig 0.16.0 design alignment review plan

Scope: review every `static_*` package against the Zig `0.16.0` design
takeaways captured in
`docs/sketches/zig_0_16_0_design_ideology_adoption_map_2026-04-14.md`, then
open only the bounded implementation slices that materially improve package
ownership, API clarity, binary-boundary explicitness, and deterministic
runtime behavior.

## Review focus

- Ambient state injection for env, args, cwd, clocks, process surfaces, and
  `Io` handles.
- Caller-owned allocation policy and unmanaged container alignment where that
  improves bounded behavior.
- Explicit packed, extern, wire, replay, and native layout contracts.
- Pointer-free packed metadata and clearer separation between raw bits and live
  runtime references.
- Explicit comptime and generic-boundary validation instead of incidental
  compiler behavior.
- Timeout-bounded host-dependent tests and build-step truthfulness.
- Public naming that distinguishes handles, paths, descriptors, views, IDs,
  configs, and owned storage.

## Package review ledger

Pending package set:

- `static_bits`
- `static_collections`
- `static_core`
- `static_ecs`
- `static_hash`
- `static_io`
- `static_math`
- `static_memory`
- `static_meta`
- `static_net`
- `static_net_native`
- `static_profile`
- `static_queues`
- `static_rng`
- `static_scheduling`
- `static_serial`
- `static_simd`
- `static_spatial`
- `static_string`
- `static_sync`
- `static_testing`

Review output required for every package:

- the highest-fit Zig `0.16.0` ideology items for that package;
- `no change`, `doc-only`, or `implementation slice needed`;
- the strongest concrete refactor or API-design candidates;
- the validation command for any reopened implementation work.

## Ordered SMART tasks

1. `Shared review rubric`
   Lock the package-review rubric and review order around the sketch so every
   package is judged against the same ownership, ABI, testing, and naming
   lenses.
   Done when:
   - this plan remains linked from `workspace_operations.md`;
   - the supporting sketch stays in `docs/sketches/`; and
   - the review output contract is stable enough to reuse across all packages.
   Validation:
   - `zig build docs-lint`
2. `Host and runtime boundary review`
   Review the packages with the strongest host-state, I/O, timing, and native
   resource exposure first:
   `static_io`, `static_testing`, `static_sync`, `static_net_native`,
   `static_serial`, and `static_net`.
   Done when:
   - each package has a recorded review outcome;
   - any package needing real code change has a bounded active package or
     feature plan before implementation starts; and
   - review-only packages are not reopened without a concrete mismatch.
   Validation:
   - `zig build docs-lint`
3. `Ownership and storage boundary review`
   Review the packages where allocator retention, storage ownership, or packed
   metadata are the likely highest-value surfaces:
   `static_memory`, `static_collections`, `static_ecs`, `static_profile`,
   `static_spatial`, and `static_string`.
   Done when:
   - each package records whether unmanaged or caller-owned alignment work is
     needed;
   - layout-sensitive packages explicitly note any ABI or packed-type follow-up;
   - any implementation work is promoted into a bounded active plan with its
     validation command.
   Validation:
   - `zig build docs-lint`
4. `Foundation and generic-boundary review`
   Review the packages where explicit comptime contracts, pure-data posture, or
   low-change confirmation are the main questions:
   `static_core`, `static_bits`, `static_hash`, `static_meta`, `static_rng`,
   `static_math`, and `static_simd`.
   Done when:
   - each package records a concrete outcome instead of an implied `probably
     fine` status;
   - low-change packages still record why no refactor is needed now; and
   - any real follow-up opens a bounded plan instead of becoming a vague note.
   Validation:
   - `zig build docs-lint`
5. `Coordination and queue review`
   Review the packages where timeout policy, host interaction, and ownership
   language intersect around waiting, buffering, or scheduling:
   `static_queues` and `static_scheduling`.
   Done when:
   - the package outcomes are recorded;
   - any shared cross-package mismatch is named explicitly before escalation;
   - validation commands are defined for any reopened implementation slice.
   Validation:
   - `zig build docs-lint`
6. `Cross-package refactor grouping`
   Consolidate recurring findings into a small number of concrete cross-package
   themes rather than a large unbounded backlog.
   Done when:
   - repeated issues are grouped under named themes such as
     `ambient_state_injection`, `allocator_ownership_alignment`,
     `explicit_binary_layout`, `packed_metadata_cleanup`,
     `comptime_boundary_cleanup`, `timeout_truthfulness`, or
     `resource_naming_alignment`;
   - each theme names the affected packages; and
   - only themes with real implementation value remain active.
   Validation:
   - `zig build docs-lint`
7. `Implementation sequencing`
   Open and sequence the real implementation slices discovered by the review
   without violating the repo rule that `docs/plans/active/` stays sparse.
   Done when:
   - every approved implementation slice has a bounded plan with explicit
     `done when` conditions and a validation command;
   - packages with no immediate change stay out of `docs/plans/active/packages/`;
   - `workspace_operations.md` reflects the real in-flight queue instead of
     speculative follow-up.
   Validation:
   - `zig build docs-lint`
8. `Review closure`
   Close this workspace-level review only after all packages have an explicit
   outcome and the remaining work has been reduced to concrete implementation
   plans or completed no-change decisions.
   Done when:
   - the package review ledger is complete;
   - the final cross-package themes are either implemented, actively planned,
     or explicitly rejected with rationale; and
   - the closure record moves to `docs/plans/completed/`.
   Validation:
   - `zig build docs-lint`

## Review order

1. `static_io`
2. `static_testing`
3. `static_sync`
4. `static_net_native`
5. `static_serial`
6. `static_net`
7. `static_memory`
8. `static_collections`
9. `static_ecs`
10. `static_meta`
11. `static_scheduling`
12. `static_queues`
13. `static_profile`
14. `static_string`
15. `static_bits`
16. `static_core`
17. `static_rng`
18. `static_spatial`
19. `static_hash`
20. `static_math`
21. `static_simd`

## Review discipline

- Do not force a refactor just because Zig `0.16.0` made a design direction
  more visible.
- Prefer package-local fixes first.
- Escalate to cross-package API work only when more than one package shows the
  same boundary mismatch.
- Keep implementation plans bounded and validation-first.
- Update package docs and repo docs in the same slice when a public boundary
  changes.

## Ideal state

- The workspace has an explicit review result for every package.
- Only packages with real, bounded improvement work stay active.
- Shared patterns around ownership, ABI, timeout policy, and naming become
  clearer without broad speculative churn.
