# `static_ecs` allocator strategy review

Scope: decide whether `static_ecs` is already using the right allocator
boundary, and add the benchmark surface needed to justify any future internal
allocator-shape change.

## Review focus

- The current code largely stays allocator-agnostic: `World`, `ArchetypeStore`,
  `Chunk`, `EntityPool`, and `CommandBuffer` all take a caller-provided
  `std.mem.Allocator` and thread `static_memory.budget.Budget` where bounded
  accounting matters.
- That boundary is probably correct, but the package still lacks an admitted
  benchmark surface for allocator choice and allocation-heavy setup paths.
- The main open question is not "should ECS own a slab or arena internally by
  default?" It is "which allocation-sensitive paths deserve explicit
  observability, and is any `static_memory` allocator recommendation strong
  enough to document?"

## Current state

- `Chunk` already uses one aligned backing allocation per live chunk and reuses
  empty chunks under config control.
- `CommandBuffer` preallocates bounded `Vec` storage and clears without
  deallocating, which is already a sensible persistent-buffer shape.
- The convenience typed bundle helpers in `world.zig` still allocate transient
  encoded scratch per call, but the direct encoded-bundle and command-buffer
  routes avoid that overhead.
- Existing ECS benchmarks emphasize structural/query throughput, not allocator
  choice.

## Approved direction

- Keep the package allocator-agnostic unless benchmark evidence shows a strong
  reason to recommend or internalize a `static_memory` strategy.
- Add allocation-shape benchmarks or experiments before changing package
  allocator ownership.
- Treat typed bundle scratch allocation as a benchmarkable decision, not an
  automatic bug.

## Ordered SMART tasks

1. `Allocation surface inventory`
   Record the long-lived versus transient allocation sites in `static_ecs` and
   decide which ones are package-owned policy versus caller-owned allocator
   choice.
   Done when:
   - the plan names the key sites (`Chunk`, archetype metadata, entity
     locations, `CommandBuffer`, typed bundle scratch);
   - the plan records which sites should stay allocator-agnostic by default.
   Validation:
   - `zig build docs-lint`
2. `Allocation benchmark admission`
   Add at least one bounded benchmark owner or experiment slice that compares
   allocator-sensitive ECS setup/control-plane behavior.
   Preferred first candidates:
   - world init/deinit under different caller allocator shapes;
   - command-buffer init/setup versus steady-state stage/apply;
   - typed bundle helper cost versus direct encoded-bundle route.
   Done when:
   - the workload is specific enough to distinguish allocator cost from ECS
     logic cost;
   - the accepted owner is wired into `zig build bench`, or the plan records
     why the comparison should remain local-only.
   Validation:
   - `zig build bench`
3. `Allocator guidance decision`
   Decide whether package docs should recommend any `static_memory` allocator
   pattern for ECS-heavy workloads.
   Done when:
   - the package docs either name an evidence-backed allocator recommendation
     for relevant workloads or explicitly state that allocator choice remains a
     caller policy with no package-level recommendation yet;
   - the plan records any deferred follow-up experiments.
   Validation:
   - `zig build docs-lint`

## Ideal state

- `static_ecs` keeps a truthful allocator boundary.
- Downstream users can see whether allocator choice materially changes ECS
  setup/control-plane performance.
- Any future move toward slab/pool-backed ECS allocation is driven by measured
  evidence rather than by guesswork.
