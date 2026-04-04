# Zig Coding Rules

## Design Goals

Priorities (in order):
1: Safety
2: Performance
3: Dev Experience
4: Maintainability
5: Extensibility

---

## 2. Design Philosophy

### 2.1 Simplicity and Elegance

Simplicity is not a concession. It is the mechanism by which we satisfy safety, performance, and developer experience simultaneously -- the "super idea" that solves multiple axes at once.

The "simplest" answer does not mean the simplest way to implement, it means the simplest way to implement the best end result. The final end result needs to be in the most "ideal" state it can be with the least amount of complexity to make it work when possible, while remaining readable.

### 2.2 Zero Technical Debt

Always work to do it right the first time, refactors are time intensive, and creating the best solution intially leads to less work in the future.

When a showstopper is found -- a potential memcpy latency spike, an exponential algorithm -- it is fixed immediately, not deferred. Make steady, measurable progress to constantly improve

---

## 3. Safety Coding Rules

Foundation: [NASA's Power of Ten -- Rules for Developing Safety Critical Code]

### 3.1 Control Flow

- Use **only very simple, explicit control flow**. No recursion -- all executions that should be bounded must be bounded. Recurssion degrades readability and understandability, as well as creates potential hard to reason over bugs.
- Use **only excellent clean abstractions**, and only when they best model the domain. Good abstractions themselves are built upon these rules, as close to zero cost as possible, maintain clear control flow, and avoid introducing hidden footguns.
- Consider whether a single `if` also needs a matching `else` to ensure both positive and negative spaces are handled or asserted.
- **State invariants positively.** When working with lengths and indexes, prefer:

  ```zig
  if (index < length) {
      // Invariant holds.
  } else {
      // Invariant violated.
  }
  ```

  Over the negated form:

  ```zig
  if (index >= length) {
      // It's not true that the invariant holds.
  }
  ```

### 3.2 Limits and Bounds
- **Put a limit on everything.** In reality, everything has a limit. This limit should be overridable if needed on the API surface, and should be well thought out.
- All loops and all queues must have a fixed upper bound. This prevents infinite loops and tail latency spikes.
- Follow the principle: violations detected sooner are cheaper. Where a loop must not terminate (e.g. an event loop), assert that explicitly. Use Zig asserts and release safe.

### 3.3 Types
- Use explicitly-sized types: `u32`, `u64`, etc.
- Prefer `usize` only for slice indexing and API boundaries, and only when absolutely needed.

### 3.4 Assertions
Assertions detect **programmer errors**. Unlike operating errors (expected, must be handled), assertion failures are unexpected. The only correct response to corrupt code is to crash. Assertions downgrade catastrophic correctness bugs into liveness bugs. Assertions are a force multiplier for discovering bugs via fuzzing.

- **Assert all function arguments and return values, pre/postconditions and invariants.** A function must not operate blindly on data it has not checked. Target a minimum density of **two assertions per function**.
- **Work to build "Pair Assertions"** For every property, find at least two different code paths to assert it. Example: assert data validity before writing to disk *and* immediately after reading from disk.
- On occasion, use a blatantly true assertion as stronger documentation where the condition is critical and surprising -- prefer this over a comment alone.
- **Split compound assertions:** prefer `assert(a); assert(b);` over `assert(a and b);`. Simpler to read, more precise on failure.
- Use single-line `if` to assert implications: `if (a) assert(b);`.
- **Assert compile-time constants** to document and enforce subtle invariants, type sizes, and design integrity -- before the program even executes.
- **Assert both positive and negative space.** Assert what you *do* expect AND what you *do not* expect. Bugs cluster at the valid/invalid boundary.
- Assertions are a safety net, not a substitute for understanding. The process:
  1. Build a precise mental model of the code.
  2. Encode that model as assertions.
  3. Write code and comments to explain and justify the model to reviewers.
  4. Use fuzzing/simulation testing as the final line of defense.

### 3.5 Memory
- For safety critical code, memory must be **statically allocated at startup**. No dynamic allocation (or free-and-reallocate) after initialization. This avoids unpredictable performance, use-after-free, and -- as a second-order effect -- produces simpler, more efficient designs that are easier to reason about.
- **Put a memory budget on every subsystem.** A back-of-envelope estimate is acceptable initially, but boundedness is a design requirement.
- **Hot-path/data-plane code does not allocate.** Allocation belongs in initialization, configuration loading, or request/setup phases.
- Prefer the cheapest strategy that fits the lifetime (ordered by preference):
  - Static / fixed-capacity buffers
  - Caller-provided scratch buffers
  - Arena/region allocation for phase-scoped lifetimes
  - Pools/slabs for bounded numbers of objects requiring stable pointers
  - General-purpose allocation only at boundaries (requires justification)
- Treat `error.OutOfMemory` as an operating error. Do not assert on OOM. Handle by propagating, degrading, or failing the operation explicitly.

### 3.6 Scope and Variables
- Declare variables at the **smallest possible scope**. Minimize the number of variables in scope to reduce misuse probability.
- **Don't introduce variables before they are needed. Don't leave them around where they are not.** Calculate or check variables close to where they are used. This reduces POCPOU (place-of-check to place-of-use) bugs.

### 3.7 Function Size
Normal Limit: **70 lines per function**.

Rules of thumb for splitting:
- Good function shape is the inverse of an hourglass: few parameters, simple return type, meaty logic in between.
- **Centralize control flow.** Keep all `switch`/`if` in the parent function; move non-branching logic to helpers. ["Push `if`s up and `for`s down."](https://matklad.github.io/2023/11/15/push-ifs-up-and-fors-down.html)
- **Centralize state manipulation.** Let the parent keep state in local variables; use helpers to compute what needs to change, not to apply changes directly. Keep leaf functions pure.

### 3.8 Compiler Discipline
- Treat **all compiler warnings** at the strictest setting as errors, from day one.

### 3.10 Error Handling

**All errors must be handled.**
Zig's error system enforces that error unions are consumed. The rules below define strategy.

#### 3.10.1 The Two Error Categories
| | Programmer Errors | Operating Errors |
|---|---|---|
| **Nature** | Bug. Invariant violated. Should never happen. | Environmental condition. Will happen. |
| **Zig mechanism** | `assert()`, `unreachable`, `@panic()` | Error unions (`!T`), error sets |
| **Response** | Crash immediately. | Propagate, handle, or degrade. |

**MUST:** Never use error unions for programmer errors. Never use assertions for operating errors.

#### 3.10.2 Decision Tree for Operating Errors
For every `catch` site:

```
1. Can this function make a meaningful recovery decision?
   Yes -> Handle locally (catch + recovery logic) and assert postconditions.
   No  -> Go to 2.

2. Is this a public API / module boundary?
   Yes -> Use explicit, named error sets and document each error.
   No  -> Use `try` to propagate. Inferred error sets are fine.
```

#### 3.10.3 Preferred Patterns (Ordered by Preference)
1. `try` propagation is the default.
2. `errdefer` is required for cleanup on error paths.
3. `catch` is reserved for recovery points with explicit handling.

#### 3.10.4 Banned Patterns
- Bare `catch {}` (swallow and ignore).
- `catch unreachable` without proof.
- `catch @panic(...)` for operating errors.
- `anyerror` at API boundaries.

#### 3.10.5 Error Set Design
- Internal functions: inferred error sets are acceptable.
- Public/module-boundary functions: explicit, named error sets are the failure contract.

#### 3.10.6 Error Handling in Tests
Test error paths, not just happy paths. Where simulation exists, inject errors at boundaries and verify recovery/degradation.

---

## 4. Performance
### 4.1 Think Early
Think about performance from the outset. **The best time to solve performance -- and get 1000x wins -- is in the design phase**, precisely when we cannot measure or profile. After implementation, fixes are harder and gains smaller. Have mechanical sympathy. Work with the grain.

### 4.2 Back-of-the-Envelope Sketches
**Sketch against the four resources and their two characteristics:**

| Resource | Bandwidth | Latency |
|----------|-----------|---------|
| Network  | ...       | ...     |
| Disk     | ...       | ...     |
| Memory   | ...       | ...     |
| CPU      | ...       | ...     |
(Add GPU when appropriate)

Sketches are cheap. Use them to land within 90% of the global maximum.

### 4.3 Optimization Order
Optimize for the slowest resources first: network > disk > memory > CPU. Compensate for frequency of usage -- a memory cache miss repeated many times may cost as much as a disk fsync.

### 4.4 Control Plane vs. Data Plane
Maintain a clear delineation. Batching across this boundary enables high assertion density without sacrificing performance.

### 4.5 Batching
Amortize network, disk, memory, and CPU costs by batching accesses. Let the CPU sprint -- give it large, predictable chunks of work. Don't force it to context-switch on every event.

### 4.6 Explicitness Over Compiler Trust
Be explicit. Minimize dependence on the compiler doing the right thing. Extract hot loops into standalone functions with primitive arguments (no `self`). This lets the compiler cache fields in registers without proving aliasing, and lets humans spot redundant computations. This is also important for future inline assembly optimizations.

Example pattern:
```zig
fn hot_loop(base_ptr: [*]u8, count: u32, stride: u32) void {
    // Standalone: no self, primitive args, easy to reason about.
}
```

---

## 5. Developer Experience
### 5.1 Naming
#### General Principles
- **Get the nouns and verbs right.** Great names capture what a thing is or does and provide a crisp mental model. Take time to find the perfect name.
- Do not abbreviate names unless the variable is a primitive integer in a sort or matrix context.
- Use proper capitalization for acronyms: `VSRState`, not `VsrState`.
- For everything else, follow the [Zig style guide](https://ziglang.org/documentation/master/#style-guide).

#### Units, Qualifiers, and Ordering
- Add units or qualifiers to variable names. Put them **last**, sorted by **descending significance**: `latency_ms_max` (not `max_latency_ms`). This groups related variables (`latency_ms_min`, `latency_ms_max`) and aligns them visually.
- Infuse names with meaning. `gpa: Allocator` and `arena: Allocator` tell the reader whether `deinit` is needed, where `allocator: Allocator` does not.

#### Function and Callback Naming
- When a function calls a helper or callback, prefix the helper name with the calling function: `read_sector()` -> `read_sector_callback()`.
- Callbacks go **last** in parameter lists, mirroring control flow (they are invoked last).

#### Struct and File Ordering
Order matters for readability. Files are read top-down; put important things near the top. IE: `main` goes first.

For structs, the order is: **fields -> types -> methods**.
```zig
time: Time,
process_id: ProcessID,

const ProcessID = struct { cluster: u128, replica: u8 };
const Tracer = @This(); // Concludes the types section.

pub fn init(gpa: std.mem.Allocator, time: Time) !Tracer {
    ...
}
```

#### Name Clarity
- Don't overload names with context-dependent meanings. Example: "two-phase commit transfers" confused with the consensus protocol term. Renamed to "pending transfers" with "post" and "void" actions.
- Think about how names will be used **outside code** -- in docs, conversations, section headers. Noun descriptors (`replica.pipeline`) compose more clearly than present participles (`replica.preparing`).

#### Named Arguments
Use Zig's `options: struct` pattern when arguments can be mixed up. A function taking two `u64` parameters must use an options struct. If an argument can be `null`, name it so that the meaning of `null` at the call site is clear.

Singleton dependencies with unique types (allocator, tracer) should be threaded through constructors positionally, from most general to most specific.

### 5.2 Comments and Rationale
- **Always say why.** Explain the rationale for every decision. This increases understanding, encourages adherence, and shares evaluation criteria.
- **Also say how.** For tests, write a description at the top explaining the goal and methodology, so readers can get up to speed or skip sections without diving in.
- Comments are sentences: space after `//`, capital letter, full stop (or colon when introducing what follows). Comments are well-written prose, not margin scribbles. 
- Code alone is not documentation.
- Comments must be self-contained. Do not write comments that require external documents (plans/ADRs) to understand. Docs may reference code by file path; code must stand alone.
- Comments should avoid "claims" of completeness, performance, optimality, or similar. IE A comment should describe how and why a thing works the way it does, not that it "is the most optimal"

### 5.3 Commit Messages
**Write descriptive commit messages** that inform the reader. PR descriptions are not stored in the git repository and are invisible in `git blame` -- they are not a replacement.
**Commit often.** A logical commit is one coherent change that compiles and passes fast tests.

### 5.4 Explicit Options at Call Sites

**Pass options explicitly to library functions. Do not rely on defaults.**

```zig
// Prefer:
@prefetch(a, .{ .cache = .data, .rw = .read, .locality = 3 });

// Over:
@prefetch(a, .{});
```

This avoids latent bugs if a library changes its defaults.

### 5.5 Cache Invalidation
- Don't duplicate variables or alias them. Reduces probability of state desynchronization.
- If a function argument should not be copied and is > 16 bytes, pass as `*const`. Catches accidental stack copies.
- **Construct large structs in-place** via out-pointer during initialization. In-place initialization enables pointer stability and immovable types while eliminating intermediate copy-move allocations.

  In-place initialization is viral -- if any field initializes in-place, the whole container should.

  **Prefer:**
  ```zig
  fn init(target: *LargeStruct) !void {
      target.* = .{
          // in-place initialization
      };
  }

  fn main() !void {
      var target: LargeStruct = undefined;
      try target.init();
  }
  ```

  **Over:**
  ```zig
  fn init() !LargeStruct {
      return LargeStruct{
          // moving the initialized object
      };
  }
  ```

- **Use simpler return types** to reduce dimensionality at the call site. `void` > `bool` > `u64` > `?u64` > `!u64`. Less branching propagates less complexity through the call chain.
- Ensure functions run to completion without suspending, so precondition assertions hold throughout the function's lifetime.

### 5.6 Buffer Bleeds
Guard against -- buffer underflows where padding is not zeroed. This can leak sensitive information and violate deterministic guarantees.

### 5.7 Resource Lifecycle
Use newlines to **group resource allocation and deallocation**: blank line before allocation, blank line after the corresponding `defer`. This makes leaks easier to spot visually.

### 5.8 Off-By-One Errors
The usual suspects: casual interactions between `index`, `count`, and `size`. These are primitive integer types but should be treated as distinct:
- `index` -> `count`: add 1 (0-based -> 1-based)
- `count` -> `size`: multiply by unit size

Include units and qualifiers in variable names to make these conversions explicit.

**Show intent with division:** use `@divExact()`, `@divFloor()`, or `div_ceil()` to demonstrate you've considered rounding scenarios.

### 5.10 Tooling
A small, standardized toolbox beats an array of specialized instruments. The primary tool is **Zig** -- for production code and for scripts.

Write `scripts/*.zig` instead of `scripts/*.sh`. This makes scripts cross-platform, portable, type-safe, and more likely to succeed for every team member.

---

## 6. Project Structure

The project structure should be navigable by inspection. Prefer simple, predictable paths.

Default layout:

```text
project/
|-- AGENTS.md
|-- build.zig
|-- build.zig.zon
|-- src/
|   |-- main.zig
|   |-- root.zig
|   |-- testing/           # Shared test infrastructure.
|   `-- ...
|-- tests/
|   |-- integration/
|   `-- vopr/
|-- scripts/
`-- docs/
    |-- plans/active/
    |-- plans/completed/
    |-- decisions/
    `-- sketches/
```

Rules:
- Plan out structure before implementation, determine a structure to avoid refactoring.
- `build.zig` is not a dumping ground. Complex automation belongs in `scripts/*.zig` or similar.
- No `utils.zig` / `helpers.zig`. Name by purpose.
- Test infrastructure belongs in `src/testing/`. Test cases belong in `tests/`.

---
## 7. Planning & Design Process
Non-trivial work MUST be planned before coding. Non-trivial work should NEVER be avoided or stubbed, it should be brought up for planning and block further work.

Recommended doc structure:
- `docs/plans/active/` for implementation plans.
- `docs/plans/completed/` for completed plans.
- `docs/decisions/` for ADRs extracted from plans when a decision will outlive the implementation.
- `docs/sketches/` for back-of-envelope calculations.

Rules:
- Plans are the primary working artifact.
- ADRs/plans reference code by file path. Code comments remain self-contained.

---

## 8. Testing
Tests must test exhaustively -- not only with valid data, but with invalid data, and as valid data becomes invalid.

Tiered testing:
- Unit tests: inline `test` blocks in `src/` (fast loop).
- Integration tests: `tests/integration/` (build loop).
- Compile-time tests: `comptime` assertions and `@compileError` for invariants.
- Fuzz/property tests: deterministic seeds, boundary-focused (parsers/codecs/config).

---

## 9. Documentation
Documentation is layered:
- Tier 0: `AGENTS.md` (commands, key paths, current work pointer).
- Tier 1: in-code (`//!` module docs, `///` public APIs). - This should generate a majority of the code documentation.
- Tier 2: `docs/architecture.md` for system-level view.
- Tier 3: `docs/reference/` for stable specs (wire formats, error codes).

---
