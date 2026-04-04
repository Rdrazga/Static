# Sketch: `static_queues` as Modular "Programming Devices" (Static-First, Dynamic-Optional)

Date: 2026-03-01 (America/Denver)  
Status: Draft sketch (actionable design direction; implementation plans per item should live in `docs/plans/active/`)

## Goal

Design `static_queues` as a set of reusable, public "programming devices" where:

- Callers can use any subset of the surface area (fully modular).
- Callers can choose to wire designs at:
  - **compile-time (static)**: monomorphized/inlined; or
  - **runtime (dynamic)**: vtable-based type erasure and configuration-driven selection.
- Semantics remain consistent and explicit, especially around concurrency, boundedness, and error handling.

## Constraints (from `agents.md`)

- Safety and boundedness dominate: every loop has a bound; hot-path code does not allocate; invariants are asserted.
- Avoid "one clever abstraction" that erases semantics; keep contracts explicit and checkable.
- Operating errors use error unions; programmer errors crash (assert/unreachable/panic).
- Avoid `anyerror` at module boundaries; error sets are part of the public contract.

---

## Semantic Glossary (Library-Wide Contracts)

These semantics must be consistent across the package, regardless of implementation strategy.

### `trySend` / `tryRecv`

- Non-blocking operations.
- Return `error.WouldBlock` when the operation cannot complete immediately, including:
  - full/empty conditions; and
  - bounded contention retry exhaustion in lock-free designs.
- If the type supports close semantics, `trySend`/`tryRecv` additionally return `error.Closed`.

### Blocking operations (`send` / `recv` / timeout variants)

- Exist only when the type guarantees it supports blocking waits (capability-gated at comptime).
- Must accept cancellation (`CancelToken`) where supported by the ecosystem.
- Timeouts use `timeout_ns: u64` and return `error.Timeout` only for timed APIs.

### `len()`

`len()` is introspection, not a correctness primitive.

- It must always return a value in `[0, capacity]`.
- It may be approximate under concurrent mutation (especially lock-free MPMC/SPMC).
- Concrete types must publish:
  - `pub const len_semantics: LenSemantics = .exact | .approximate`.
- Generic code must not use `len()` to decide correctness (only telemetry/backpressure heuristics).

### Introspection constness

All introspection is logically const:

- `capacity(self: *const Self) usize`
- `len(self: *const Self) usize`
- `isEmpty(self: *const Self) bool`

If a type must lock to answer introspection, treat the lock as interior mutability (`@constCast` at the lock site).

---

## Static-First, Dynamic-Optional Architecture

### Concrete types keep correctness in the type system

Queue semantics are not interchangeable. Correctness depends on:

- Concurrency model (SPSC/MPSC/SPMC/MPMC, fanout, work-stealing, etc.)
- Blocking vs non-blocking behavior
- Close/disconnect semantics
- Introspection guarantees (`len_semantics`)

Therefore: keep distinct concrete types for distinct contracts. Do not force a single "Queue" struct.

### Compile-time "concepts" (duck-typed interfaces) for static composition

For comptime designs, define a small set of stable concepts and validate them with `@hasDecl` + `@compileError`.

The point of concepts is not to unify semantics; it is to:

- Make generic code auditable ("this function requires a `TryQueue`");
- Provide crisp error messages when a type does not satisfy a shape; and
- Enable conformance tests (see below).

#### Proposed concept families (minimum set)

These are intentionally small and strict so semantics do not get blurred.

**`TryQueue(T)` (non-blocking container contract)**

Required decls:

- `Element == T`
- `TrySendError` and `TryRecvError` (explicit error set types)
- `concurrency`, `is_lock_free`, `len_semantics`
- `supports_close == false`
- `supports_blocking_wait == false`

Required methods:

- `init(...)` / `deinit(...)` (exact signature varies; not part of the concept)
- `capacity(self: *const Self) usize`
- `len(self: *const Self) usize`
- `isEmpty(self: *const Self) bool`
- `trySend(self: *Self, value: T) TrySendError!void`
- `tryRecv(self: *Self) TryRecvError!T`

**`Channel(T)` (coordination contract)**

This concept is capability-gated by build options. If supported:

- `supports_close == true`
- `supports_blocking_wait == true`
- `TrySendError` and `TryRecvError` include `error.Closed`
- `SendError` and `RecvError` are explicit error sets
- `close(self: *Self) void`
- `send(self: *Self, value: T, cancel: ?CancelToken) SendError!void`
- `recv(self: *Self, cancel: ?CancelToken) RecvError!T`
- Optional timed variants with `timeout_ns: u64` returning `error.Timeout`

**`RegisteredFanoutRing(T)`**

Fanout rings add consumer registration and per-consumer receive state:

- `ConsumerId`
- `addConsumer(self: *Self) error{NoSpaceLeft}!ConsumerId`
- `removeConsumer(self: *Self, consumer_id: ConsumerId) void`
- `trySend(self: *Self, value: T) TrySendError!void`
- `tryRecv(self: *Self, consumer_id: ConsumerId) TryRecvError!T`
- `pending(self: *Self, consumer_id: ConsumerId) usize`

**`WorkStealingDeque(T)`**

Work-stealing deques are not `TryQueue`-shaped. Required methods are:

- `pushBottom(self: *Self, value: T) PushError!void`
- `popBottom(self: *Self) PopError!T`
- `stealTop(self: *Self) StealError!T`

### Runtime adapters (vtables) as a separate, explicit layer

Runtime polymorphism is useful for:

- runtime configuration-based selection;
- heterogeneous collections; and
- plugin-like boundaries.

But type-erasure must not hide correctness differences. Rules:

1. No mega-vtable. Split by semantics.
2. No "method exists but returns `error.Unsupported`" contracts.
3. No `anyerror` in adapter APIs.
4. Adapters do not own the underlying object; they are a view.

To keep error handling explicit, runtime adapters must be family-specific and parameterized by explicit error sets:

- `AnyTryQueue(T, comptime queue_concurrency: Concurrency, comptime TrySendError: type, comptime TryRecvError: type)`
- `AnyChannel(T, comptime TrySendError: type, comptime TryRecvError: type, comptime SendError: type, comptime RecvError: type)`
- `AnyRegisteredFanoutRing(T, comptime TrySendError: type, comptime TryRecvError: type)`

This ensures the vtable function types remain a strict contract.

---

## Capabilities and Contract Metadata (Required Decls)

To guarantee consistent semantics, each public type should publish metadata for its concept family.

Common metadata (all families):

- `pub const Element = T`
- `pub const concurrency: Concurrency` (enum)
- `pub const is_lock_free: bool`

`TryQueue` family metadata:

- `pub const supports_close = false`
- `pub const supports_blocking_wait = false`
- `pub const len_semantics: LenSemantics`
- `pub const TrySendError: type` (e.g. `error{WouldBlock}`)
- `pub const TryRecvError: type`

`Channel` family metadata:

- `pub const supports_close = true`
- `pub const supports_blocking_wait: bool`
- `pub const TrySendError: type` (must include `error.Closed`)
- `pub const TryRecvError: type` (must include `error.Closed`)
- `pub const SendError: type` and `pub const RecvError: type` (timeout variants when present)

`RegisteredFanoutRing` family metadata:

- `pub const ConsumerId: type`
- `pub const TrySendError: type`
- `pub const TryRecvError: type`

`WorkStealingDeque` family metadata:

- explicit operation error set decls for owner push/pop and thief steal

Do not force unrelated families into one metadata shape; metadata must remain machine-checkable and truthful.

---

## Error Handling Policy (Unifies the API Surface)

### Constructor/destructor errors

- `init(...)` returns an explicit error set, typically re-exported as `pub const Error = ...`.
- `deinit(...)` is infallible.
- `OutOfMemory` must be treated as an operating error (never asserted).

### Operational errors

Prefer these stable error names across the package:

- `error.WouldBlock` for non-blocking backpressure/empty/full/limited progress.
- `error.Closed` for close/disconnect semantics.
- `error.Timeout` for timed waits.
- `error.Cancelled` when cancellation is supported by the call.
- `error.NoSpaceLeft` for consumer registration tables, fixed-slot registries, etc.

Do not introduce new error names unless they provide new actionable meaning to callers.

---

## Testing Strategy: Conformance Tests + Algorithm-Specific Stress

The strongest guarantee of "consistent semantics" is a shared conformance suite that runs against every implementation that claims a concept.

### Conformance test harness

Add reusable test drivers under `packages/static_queues/src/testing/` that can test any type meeting a concept:

- `try_queue_conformance.zig`: validates `trySend`/`tryRecv` semantics (full/empty, wrap, capacity bounds).
- `channel_conformance.zig`: validates `close` and blocking/cancellation/timeout semantics.
- `registered_fanout_ring_conformance.zig`: validates registration lifecycle, per-consumer ordering, and producer backpressure.
- `work_stealing_deque_conformance.zig`: validates owner/thief semantics and empty/full boundaries.
- `len_conformance.zig`: validates `[0, capacity]` and correct `len_semantics` for types that expose `len()`.

These tests are deterministic and boundary-focused (capacity 1/2/3/..., off-by-one edges).

### Lock-free stress tests

For lock-free implementations, add multi-thread stress tests with deterministic seeds and explicit bounds:

- N producers/M consumers; verify:
  - no duplicates;
  - no out-of-range values;
  - bounded retries always terminate;
  - item conservation under successful operations.

When stress tests need to run for a long time, bound them by:

- `iterations_max`, and/or
- `time_budget_ms_max`,

so CI does not regress.

---

## Proposed Package Re-Organization (Incremental, Non-Breaking)

Keep the existing public imports stable by re-exporting from `packages/static_queues/src/root.zig`.

Phase 1 structure (staging folders inside `static_queues` while boundaries are finalized):

- `packages/static_queues/src/queues/core/`  
  Non-blocking queue/data-structure implementations (`SpscQueue`, `MpscQueue`, `RingBuffer`, etc.).
- `packages/static_queues/src/queues/coordination/`  
  Blocking/close/cancellation coordination primitives (`Channel`, potential blocking SPSC variant).
- `packages/static_queues/src/queues/messaging/`  
  Registered fanout/event devices (`Broadcast`, `Disruptor`, `InboxOutbox` as currently scoped).
- `packages/static_queues/src/queues/deques/`  
  Work-stealing/deque family.
- `packages/static_queues/src/concepts/`  
  Compile-time validators and shared generic helpers.
- `packages/static_queues/src/adapters/`  
  Type-erased runtime wrappers (`Any*`).
- `packages/static_queues/src/testing/`  
  Conformance test drivers and shared test infrastructure.

Phase 2 (optional, decision-gated): move `coordination` and/or `messaging` families to dedicated packages only after dependency layering is made acyclic.

---

# Action Plan (Individually Landable Items)

Each item below is "done" only when:

- it has bounded loops and explicit limits;
- it has high assertion density (Debug/ReleaseSafe);
- it has conformance tests where applicable;
- `zig build test` passes.

## Item -1: Taxonomy decision gate + staging folders (blocks package moves)

### Change

Before metadata/concepts work, decide short-term boundaries and create staging folders under `packages/static_queues/src/queues/`:

- `core/`
- `coordination/`
- `messaging/`
- `deques/`

During this step, keep old import paths stable through re-exports/shims from `packages/static_queues/src/root.zig`.

### Decision gate outcomes

- Path A (short-term): keep all families in `static_queues`, split by internal folders now.
- Path B (later): move `coordination` and/or `messaging` to dedicated packages once dependency layering is acyclic.

## Item 0: Contract metadata normalization (enforces consistency)

### Change

Add required metadata decls by concept family (`TryQueue`, `Channel`, `RegisteredFanoutRing`, `WorkStealingDeque`) instead of a single universal shape.

### Why this is next

This is the foundation for:

- concept validation,
- conformance tests, and
- vtable adapter safety.

### Non-breaking constraint

This should be additive only. If a type cannot support a capability (e.g. close), it still publishes the const as `false`.

## Item 1: Add `concepts/` compile-time validators (comptime-first reuse)

### Add

Under `packages/static_queues/src/concepts/`:

- `try_queue.zig`: `requireTryQueue(Q, T)`
- `channel.zig`: `requireChannel(C, T)`
- `registered_fanout_ring.zig`: `requireRegisteredFanoutRing(F, T)`
- `work_stealing_deque.zig`: `requireWorkStealingDeque(D, T)`

### Design rule

Prefer multiple small concepts over one mega concept.

## Item 2: Add conformance test harness (guarantees semantics)

### Add

Under `packages/static_queues/src/testing/`:

- deterministic conformance tests for each concept family (`TryQueue`, `Channel`, `RegisteredFanoutRing`, `WorkStealingDeque`).

### Apply

In each queue file's existing `test` blocks (or a central test runner), call the conformance drivers for that type.

This is the practical "guarantee": every queue that claims it is a `TryQueue` must pass the same suite.

## Item 3: Add runtime type-erasure adapters (`Any*` vtables) (runtime wiring)

### Add

Under `packages/static_queues/src/adapters/`:

- `any_try_queue.zig`: `AnyTryQueue(T, queue_concurrency, TrySendError, TryRecvError)`
- `any_channel.zig`: `AnyChannel(T, TrySendError, TryRecvError, SendError, RecvError)`
- `any_registered_fanout_ring.zig`: `AnyRegisteredFanoutRing(T, TrySendError, TryRecvError)`

### Contract rules

- Adapters are views (no ownership).
- Adapters only exist for concept-validated shapes.
- Error sets are explicit type parameters (no `anyerror`).
- Adapters do not erase family/concurrency contracts.

### Capability gating

If channel adapters are included, they must be capability-gated the same way `Channel` is:

- `AnyChannel` exists only when blocking support is enabled; otherwise the decls do not exist.

## Item 4: Add `LockFreeMpscQueue(T)` (bounded; no allocation after init)

### Add

A new concrete queue type. Do not change `MpscQueue` semantics.

### Algorithm

Prefer the existing sequence-number ring protocol family (reuses established invariants and helpers) specialized for MPSC.

### Boundedness

- `cas_retries_max` and bounded backoff.
- Failure to make progress returns `error.WouldBlock`.

## Item 5: Add `ChaseLevDeque(T)` (bounded lock-free work-stealing)

### Add

A new concrete deque type. Do not change `WorkStealingDeque` semantics.

### Semantics metadata

`len_semantics` is likely `.approximate` under contention; that must be declared and tested.

## Item 6: Add capability-gated blocking SPSC primitive (name decision required)

### Add

Add one type that builds on `SpscQueue` for the data-plane and uses OS wait primitives only for waiting.

### Decision gate

- If semantics match `Channel` (close + cancellation + timeout), use `SpscChannel(T)` under `coordination`.
- If semantics are queue-only with wait support, use `BlockingSpscQueue(T)` and keep it in the queue family.

## Item 7: Documentation and accuracy pass (ongoing)

### Update

- Module docs: "choose this when..." sections for overlapping devices (e.g. `Broadcast` vs `Disruptor`).
- `docs/sketches/reviews/static_queues.md`: ensure it matches current implementation reality.

## Item 8 (Optional): Deprecation/migration cleanup (e.g. `PriorityQueue`)

If some structures belong more naturally in another package, do not break callers:

- Re-export from the old location for at least one cycle.
- Mark the old entry as deprecated in docs (and optionally via `@compileError` only after a deprecation window).
- If `PriorityQueue` migrates, ensure replacement preserves required operations (`tryPush`/`tryPop` plus update/remove behavior) before deprecating old entry points.

---

## Rollout Order (Minimize Risk)

1. Item -1 (taxonomy decision gate + staging folders)
2. Item 0 (family metadata normalization)
3. Item 1 (concept validators)
4. Item 2 (conformance test harness)
5. Item 3 (runtime adapters)
6. Items 4-6 (new lock-free/blocked devices)
7. Item 7 (doc accuracy) continuously

---

## Review Checklist (Enforces `agents.md`)

Use this checklist for every new queue/device and for every adapter/concept addition:

- Control flow: no recursion; loops have explicit upper bounds; backoff/retry loops are bounded by config.
- Bounds/limits: capacities validated; indices validated; integer overflow guarded (`add/mul` checked); timeouts validated.
- Assertions: at least two meaningful assertions per public function (pre/postconditions and invariants); split compound assertions.
- Error handling: no swallowed errors; operating errors are propagated/handled; no `anyerror` at module boundaries.
- Memory: no allocation on hot paths; deinit releases budgets and buffers; no hidden reallocation.
- Semantics: `len_semantics` declared correctly; `len()` bounded to `[0, capacity]`; `TrySendError`/`TryRecvError` declared and correct.
- Tests: conformance tests applied; boundary cases covered; stress tests bounded and deterministic where applicable.
