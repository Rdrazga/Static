# Zig 0.16.0 Design Ideology Adoption Map

Date: 2026-04-14
Status: live working sketch
Owner: Codex

## Purpose

This sketch translates the most repo-relevant design ideas from the Zig
`0.16.0` release notes into a package-by-package review map for `static`.

The goal is not to chase language novelty for its own sake. The goal is to
identify which Zig `0.16.0` design pressures reinforce this repo's existing
values around explicit ownership, bounded behavior, deterministic testing,
clear ABI boundaries, and data-oriented design.

This sketch is the design input for the active review plan:

- `docs/plans/active/zig_0_16_0_design_alignment_review.md`

## Inputs

Primary upstream inputs:

- Zig `0.16.0` release notes:
  https://ziglang.org/download/0.16.0/release-notes.html
- `I/O as an Interface`:
  https://ziglang.org/download/0.16.0/release-notes.html#I/O-as-an-Interface
- `Environment Variables and Process Arguments Become Non-Global`:
  https://ziglang.org/download/0.16.0/release-notes.html#Environment-Variables-and-Process-Arguments-Become-Non-Global
- `Migration to "Unmanaged" Containers`:
  https://ziglang.org/download/0.16.0/release-notes.html#Migration-to-Unmanaged-Containers
- `Forbid Pointers in Packed Structs and Unions`:
  https://ziglang.org/download/0.16.0/release-notes.html#Forbid-Pointers-in-Packed-Structs-and-Unions
- `Allow Explicit Backing Integers on Packed Unions`:
  https://ziglang.org/download/0.16.0/release-notes.html#Allow-Explicit-Backing-Integers-on-Packed-Unions
- `Forbid Enum and Packed Types with Implicit Backing Types in Extern Contexts`:
  https://ziglang.org/download/0.16.0/release-notes.html#Forbid-Enum-and-Packed-Types-with-Implicit-Backing-Types-in-Extern-Contexts
- `Lazy Field Analysis`:
  https://ziglang.org/download/0.16.0/release-notes.html#Lazy-Field-Analysis
- `Zero-bit Tuple Fields No Longer Implicitly comptime`:
  https://ziglang.org/download/0.16.0/release-notes.html#Zero-bit-Tuple-Fields-No-Longer-Implicitly-comptime
- `Unit Test Timeouts`:
  https://ziglang.org/download/0.16.0/release-notes.html#Unit-Test-Timeouts
- `Current Directory API Renamed`:
  https://ziglang.org/download/0.16.0/release-notes.html#Current-Directory-API-Renamed

Repo-local inputs:

- `README.md`
- `AGENTS.md`
- `docs/architecture.md`
- `docs/plans/active/workspace_operations.md`

## Core design takeaways

### 1. Ambient state should be injected, not assumed

Zig `0.16.0` pushes environment variables, process arguments, and I/O handles
away from global ambient state and toward explicit handles and interfaces.

Repo fit:

- strong fit for deterministic testing and replay;
- strong fit for cross-platform host-boundary code;
- strong fit for keeping policy at the caller and behavior in the callee.

Likely review questions:

- does this API reach into process-global state deep in the call graph;
- should a clock, `Io`, env map, cwd handle, or process surface be passed in;
- does the package accidentally mix pure data transforms with host policy.

### 2. Allocator and container ownership should stay explicit

Zig `0.16.0` continues the shift toward unmanaged containers and caller-owned
allocation policy.

Repo fit:

- matches the repo's bounded-resource and zero-post-init-allocation goals;
- aligns with package consumers choosing budgets and allocators explicitly;
- reduces hidden lifetime and ownership coupling.

Likely review questions:

- does a type retain an allocator only for convenience;
- should a helper become unmanaged or caller-owned;
- are grow, reserve, clone, and reset paths explicit about memory policy.

### 3. Binary layout must be explicit at every ABI boundary

Zig `0.16.0` makes packed and extern layout rules stricter and more explicit.

Repo fit:

- directly relevant to wire formats, replay artifacts, binary storage,
  socket-address bridges, and ECS raw data staging;
- reinforces the repo's preference for clear contracts over inferred layout.

Likely review questions:

- do packed or extern-facing types declare explicit integer backing;
- are file, wire, or native-boundary payloads explicit about width and layout;
- are there accidental ABI dependencies on inferred enum or packed layout.

### 4. Packed data should remain bit-level and pointer-free

Zig `0.16.0` rejects pointers in packed structs and unions. That is also a
useful repo-level ideology even when the compiler no longer permits the most
dangerous cases.

Repo fit:

- packed forms should carry flags, widths, offsets, handles-as-integers, or
  other plain data;
- semantic references and lifetimes should live in unpacked runtime types.

Likely review questions:

- does a packed type try to smuggle ownership or aliasing through raw layout;
- should a packed descriptor split into a bit-level header plus runtime view.

### 5. Metaprogramming should be explicit, not compiler-quirk-driven

The `Lazy Field Analysis` and tuple/comptime changes in Zig `0.16.0` reward
generic code that states its comptime dependencies precisely.

Repo fit:

- important anywhere the repo uses generic validators, compile-time metadata,
  root-surface export shaping, or generated storage layouts;
- matches the repo's preference for fail-fast contracts and traceable control
  flow.

Likely review questions:

- is this relying on incidental field analysis or tuple behavior;
- should a generic validator split metadata from runtime state more clearly;
- can a public generic boundary fail earlier and with a clearer message.

### 6. Test runtime bounds should be part of the contract

Zig `0.16.0` adds build-system unit-test timeouts, which is a good match for
this repo's bounded execution and deterministic harness posture.

Repo fit:

- strong fit for host-thread, host-process, I/O, queue, and sync tests;
- useful for distinguishing "correct but slow" from "hung or unbounded".

Likely review questions:

- which package tests can block, park, or wait on host resources;
- should the package own explicit timeout configuration in build steps;
- can shared `static_testing` harnesses expose bounded timeouts more directly.

### 7. Names should distinguish handles from paths and pure data from live resources

The `Current Directory API Renamed` note is part of a broader naming pressure:
distinguish paths, handles, descriptors, and live resources instead of
collapsing them into one overloaded noun.

Repo fit:

- strong fit for filesystem, process-driver, native socket, and runtime APIs;
- also useful for collections and ECS surfaces that distinguish borrowed views,
  owned storage, IDs, and handles.

Likely review questions:

- does a name blur a path string with an open handle;
- does a name hide whether a value is borrowed, owned, staged, or live;
- should `descriptor`, `handle`, `path`, `view`, or `config` be separated.

## Where each ideology most likely applies

### Ambient state injection and explicit `Io` boundaries

Highest-fit packages:

- `static_io`
- `static_testing`
- `static_sync`
- `static_scheduling`
- `static_net_native`

Secondary-fit packages:

- `static_net`
- `static_core`
- `static_serial`

Most likely changes:

- inject clocks, env, cwd, process, and `Io` surfaces instead of looking them
  up internally;
- keep parsing, framing, and retry policy separate from host effects;
- make host-dependent code easy to fake or replay through `static_testing`.

### Unmanaged or caller-owned allocation boundaries

Highest-fit packages:

- `static_memory`
- `static_collections`
- `static_ecs`
- `static_string`
- `static_spatial`

Secondary-fit packages:

- `static_profile`
- `static_queues`
- `static_scheduling`

Most likely changes:

- remove retained allocators from convenience wrappers where caller ownership
  is the more durable boundary;
- align constructor, reserve, clone, and reset APIs around explicit budgets and
  allocator choice;
- keep zero-post-init or bounded-allocation options visible in public APIs.

### Explicit packed, extern, wire, and replay layout

Highest-fit packages:

- `static_bits`
- `static_serial`
- `static_net`
- `static_net_native`
- `static_ecs`

Secondary-fit packages:

- `static_profile`
- `static_testing`

Most likely changes:

- make backing integers explicit on enums, packed unions, and layout-sensitive
  tag types;
- split raw byte layout types from richer runtime wrappers;
- tighten assertions around width, alignment, and layout assumptions.

### Packed-data discipline and pointer-free metadata

Highest-fit packages:

- `static_bits`
- `static_serial`
- `static_net`
- `static_ecs`

Secondary-fit packages:

- `static_profile`
- `static_spatial`

Most likely changes:

- replace pointer-carrying or lifetime-sensitive packed metadata with integer
  offsets, indices, or IDs;
- keep runtime aliasing and ownership in unpacked structures.

### Explicit comptime and generic-boundary cleanup

Highest-fit packages:

- `static_meta`
- `static_ecs`
- `static_collections`

Secondary-fit packages:

- `static_profile`
- `static_core`
- `static_testing`

Most likely changes:

- simplify generic validators so they fail from explicit comptime checks rather
  than downstream inference;
- split namespace-only helper types from storage-carrying types;
- reduce unintended field analysis and large dependency pull-in from type use.

### Timeout-bounded tests and runtime validation

Highest-fit packages:

- `static_testing`
- `static_sync`
- `static_io`
- `static_scheduling`
- `static_net_native`

Secondary-fit packages:

- `static_queues`
- `static_net`

Most likely changes:

- add or tighten build-step timeout policy for blocking or host-dependent test
  owners;
- prefer explicit timeout wiring over implicit sleeps or open-ended polling;
- treat timeout metadata as part of test truthfulness, not only CI hygiene.

### Handle, path, descriptor, and ownership naming clarity

Highest-fit packages:

- `static_io`
- `static_testing`
- `static_net_native`
- `static_sync`

Secondary-fit packages:

- `static_ecs`
- `static_memory`
- `static_queues`

Most likely changes:

- rename APIs that currently blur path strings with open handles;
- distinguish borrowed views from owned storage and staged data from live
  resources;
- keep public names aligned with the real lifetime and mutation model.

## Package-by-package first-pass review map

### Foundation packages

- `static_core`: review config, timeout, env, and process-adjacent vocabulary
  for explicit ambient-state boundaries and stronger naming around handles
  versus plain data.
- `static_bits`: review packed types, bitfield helpers, and layout-sensitive
  APIs for explicit backing widths and pointer-free metadata.
- `static_hash`: review whether any convenience surfaces retain allocator or
  scratch policy implicitly; otherwise this package is likely a lower-change
  package.
- `static_meta`: review all generic validators and compile-time registries for
  explicit comptime assumptions and minimal dependency pull-in.
- `static_rng`: review host entropy boundaries versus deterministic engines and
  keep ambient randomness or time out of pure generator APIs.
- `static_string`: review pool and bounded-string ownership surfaces for
  caller-owned allocation policy and explicit no-allocation modes.

### Data and storage packages

- `static_memory`: high-priority review for allocator retention, caller-owned
  policy, reset semantics, and naming that separates storage handles from
  configuration.
- `static_collections`: high-priority review for unmanaged alignment, explicit
  memory-policy APIs, and generic boundary clarity.
- `static_ecs`: high-priority review for explicit bundle/layout contracts,
  packed metadata discipline, and clearer owned-versus-borrowed API naming.
- `static_profile`: review export and trace layout types for explicit binary
  shape and packed metadata discipline.
- `static_spatial`: review builder and storage ownership boundaries plus any
  packed metadata or index layout types.

### Runtime and coordination packages

- `static_sync`: high-priority review for timeout-bounded tests, explicit clock
  and wait policy injection, and clearer handle or token naming.
- `static_queues`: review caller-owned memory policy, wait or timeout surface
  explicitness, and naming around borrowed versus live queue state.
- `static_scheduling`: high-priority review for explicit time and host policy
  injection plus bounded timeout truthfulness in tests and benchmarks.
- `static_io`: highest-priority review for `Io` boundary clarity, path versus
  handle naming, and removal of any lingering ambient host-state lookups.
- `static_testing`: highest-priority review for explicit env, cwd, clock, and
  process injection, plus package-wide timeout policy adoption for blocking
  workflows.

### Wire, native, and external-boundary packages

- `static_serial`: high-priority review for explicit binary layout and unpacked
  runtime wrappers around raw frame metadata.
- `static_net`: high-priority review for wire layout, packed metadata, and
  timeout-bounded host-touching tests.
- `static_net_native`: highest-priority review for native handle naming,
  explicit resource ownership, and ABI-shape clarity at OS boundaries.

### Compute-heavy packages

- `static_math`: likely lower-change; review for unnecessary allocator or host
  policy coupling and keep this package mostly pure-data and pure-function.
- `static_simd`: likely lower-change; review for target-awareness notes and any
  accidental layout assumptions at vector or binary boundaries.

## Highest-value first review order

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

## Non-goals

- force every package to look like `std`;
- rewrite stable APIs purely for naming aesthetics;
- reopen lower-value packages when the review concludes the current boundary is
  already aligned;
- broaden the active queue with speculative package plans before a concrete
  mismatch is identified.

## Ideal state

- Packages that touch host state, time, files, sockets, or processes accept
  those surfaces explicitly.
- Packages that manage storage keep allocator and budget ownership visible to
  callers.
- Packages that cross binary or native boundaries make layout explicit in the
  type system.
- Generic packages fail early from explicit comptime contracts rather than
  relying on older inference behavior.
- Host-dependent tests use bounded timeout policy as part of their design, not
  only as a CI afterthought.
