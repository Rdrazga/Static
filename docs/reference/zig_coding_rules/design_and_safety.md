# Design And Safety Rules

Use this document for implementation design, core code shape, invariants,
memory rules, and error handling decisions.

## Design philosophy

### Simplicity and elegance

Simplicity is not a concession. It is the mechanism by which we satisfy
safety, performance, and developer experience simultaneously.

The "simplest" answer does not mean the simplest implementation. It means the
simplest way to reach the best end state with the least necessary complexity
while remaining readable.

### Zero technical debt

Always work to do it right the first time. Refactors are time intensive, and
creating the best initial solution leads to less work in the future.

When a showstopper is found -- a potential memcpy latency spike or an
exponential algorithm -- fix it immediately rather than deferring it.

## Safety coding rules

Foundation: [NASA's Power of Ten -- Rules for Developing Safety Critical Code]

### Control flow

- Use only very simple, explicit control flow.
- No recursion. All bounded executions must remain bounded.
- Use abstractions only when they clearly model the domain without hidden
  footguns.
- Consider whether an `if` also needs an `else` so the negative space is
  handled or asserted.
- State invariants positively. Prefer `if (index < length)` over
  `if (index >= length)`.

### Limits and bounds

- Put a limit on everything, and make the limit overridable at the API surface
  when needed.
- All loops and queues must have a fixed upper bound.
- Detect violations as early as possible.
- When a loop must not terminate, assert that explicitly.

### Types

- Use explicitly-sized types such as `u32` and `u64`.
- Prefer `usize` only for slice indexing and API boundaries, and only when
  necessary.

### Assertions

Assertions detect programmer errors. The correct response to corrupted program
state is to crash immediately.

- Assert all function arguments, return values, preconditions, postconditions,
  and invariants.
- Target at least two assertions per function.
- Build pair assertions: assert important properties from more than one path.
- Prefer `assert(a); assert(b);` over `assert(a and b);`.
- Use single-line implication checks such as `if (a) assert(b);`.
- Assert compile-time constants when they encode subtle design invariants.
- Assert both the valid and invalid boundary conditions.
- Use assertions to encode your mental model, then use tests and fuzzing to
  verify it.

### Memory

- For safety-critical code, memory should be statically allocated at startup.
- No dynamic allocation or free-and-reallocate after initialization in hot or
  safety-critical paths.
- Put a memory budget on every subsystem.
- Hot-path and data-plane code must not allocate.
- Prefer, in order:
  - static or fixed-capacity buffers;
  - caller-provided scratch buffers;
  - arena or region allocation for phase-scoped lifetimes;
  - pools or slabs for bounded stable objects;
  - general-purpose allocation only at boundaries, with justification.
- Treat `error.OutOfMemory` as an operating error. Propagate, degrade, or fail
  explicitly.

### Scope and variables

- Declare variables at the smallest possible scope.
- Introduce variables only when needed and keep checks close to use sites.

### Function size and shape

Normal limit: 70 lines per function.

- Good function shape is the inverse of an hourglass: few parameters, simple
  return type, meaty logic in between.
- Push branching up and loops down.
- Keep state manipulation centralized in the parent function.
- Prefer pure leaf helpers that compute results instead of mutating shared
  state directly.

### Compiler discipline

- Treat all compiler warnings at the strictest setting as errors.

## Error handling

All errors must be handled.

### Error categories

| | Programmer errors | Operating errors |
|---|---|---|
| Nature | Bug. Invariant violated. | Environmental condition. |
| Zig mechanism | `assert()`, `unreachable`, `@panic()` | Error unions and error sets |
| Response | Crash immediately. | Propagate, handle, or degrade. |

- Never use error unions for programmer errors.
- Never use assertions for operating errors.

### Decision tree for operating errors

1. Can this function make a meaningful recovery decision?
   - Yes: handle locally and assert postconditions.
   - No: continue.
2. Is this a public API or module boundary?
   - Yes: use explicit, named error sets and document each error.
   - No: use `try` to propagate.

### Preferred patterns

1. `try` propagation is the default.
2. `errdefer` is required for cleanup on error paths.
3. `catch` is reserved for explicit recovery points.

### Banned patterns

- Bare `catch {}`.
- `catch unreachable` without proof.
- `catch @panic(...)` for operating errors.
- `anyerror` at API boundaries.

### Error handling in tests

- Test error paths, not only happy paths.
- When simulation exists, inject boundary failures and verify recovery or
  degradation.
