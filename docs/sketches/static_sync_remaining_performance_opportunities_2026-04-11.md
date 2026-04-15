# `static_sync` Remaining Performance Opportunities

Date: 2026-04-11
Status: live working sketch
Owner: Codex

## Purpose

This sketch captures the highest-value remaining performance opportunities in
`static_sync` after the benchmark hardening and runtime follow-up work landed.
It is intentionally narrower than the earlier hotspot investigation:

1. focus on code paths that still have a credible improvement story;
2. state the contract and proof risks before implementation; and
3. define how to measure a win without weakening the package's hostile-runtime
   guarantees.

The current top items are:

1. `wait_queue` cancellation without timeout-budget poll slicing; and
2. a bounded free-slot index for `CancelRegistration.register()`.

## Inputs

Relevant completed work and evidence:

- `docs/plans/completed/static_sync_benchmark_and_testing_hardening_closed_2026-04-11.md`
- `docs/plans/completed/static_sync_runtime_and_benchmark_followup_closed_2026-04-11.md`
- `docs/sketches/static_sync_benchmark_hotspot_investigation_2026-04-11.md`

Code paths inspected for this sketch:

- `packages/static_sync/src/sync/wait_queue.zig`
- `packages/static_sync/src/sync/cancel.zig`
- `packages/static_sync/src/sync/backoff.zig`

Most relevant benchmark evidence already gathered:

- `cancel_register_4` improved from roughly `249.6 ns/op` to roughly
  `17.6 ns/op` after the current load-before-CAS filter landed, but the
  registration path still linearly scans the fixed table.
- `wait_queue` remains correct under timeout and cancellation proof, but its
  cancellation-aware timed-wait path still slices timeout budgets into
  `cancel_poll_ns = 1 ms` windows.

## Opportunity 1: `wait_queue` Cancellation Without Poll Slicing

### Current design

`waitValue()` in `packages/static_sync/src/sync/wait_queue.zig` currently
supports cancellation in two ways:

- before sleeping, it checks `token.throwIfCancelled()`;
- during timed waits, it limits each futex sleep to `min(remaining_ns,
  cancel_poll_ns)` so cancellation can be re-observed promptly.

That design is simple, bounded, and already covered by model/sim/fault tests.
It also means a cancelable timed wait does not actually sleep for its full
remaining timeout budget. Instead it wakes periodically to recheck the cancel
token.

### Why this is still a performance concern

This path is still paying for correctness with polling:

- extra wakeups when timeouts are long;
- extra timeout bookkeeping on every slice; and
- higher scheduler noise than a truly wake-driven cancel path.

This is not a correctness problem. It is a cost-shape problem under hostile or
busy hosts, especially when many waits are simultaneously cancellable.

### Main hypotheses

- H1 high confidence: the current timeout-slicing path adds avoidable CPU and
  scheduler overhead for long-lived cancelable waits.
- H2 medium confidence: a callback-driven cancel wake can preserve current
  semantics while materially reducing slice-driven wakeups.
- H3 medium confidence: the hardest part is not the wake itself, but keeping
  race ordering correct between value change, timeout expiry, and cancellation.

### Candidate design directions

#### Direction A: register a cancel wake callback around the futex wait

Use `CancelRegistration` to wake the waiting futex location directly when the
 token fires, then let `waitValue()` distinguish among:

- observed value change;
- explicit cancellation; and
- real timeout expiration.

Expected result:

- lower CPU churn during long cancelable waits;
- lower cancellation latency than `1 ms` poll slices; and
- cleaner tail behavior for cancel-heavy runtime scenarios.

Main risks:

- the callback must not wake unrelated waiters incorrectly;
- registration and unregister must remain bounded and race-safe when the wait
  ends through timeout or value change;
- wake-before-sleep and cancel-during-registration races must stay explicit and
  replayable.

#### Direction B: keep the current design, but make poll slicing adaptive

Instead of a flat `1 ms` slice, grow the slice with the remaining timeout
budget or host capability. For example:

- short waits keep small slices;
- longer waits use fewer, larger slices until the tail phase.

Expected result:

- smaller change surface than callback-driven wake;
- lower overhead for long waits;
- weaker latency improvement than Direction A.

Main risks:

- still fundamentally polling;
- more heuristics in a primitive that is currently easy to reason about;
- harder to prove "best" settings across hosts.

### What has to be proved before changing code

Any implementation must preserve all current contracts:

- `Cancelled` remains explicit and cooperative rather than implicit wake
  interpretation.
- spurious wake tolerance remains caller-visible and loop-safe.
- timeout zero and near-zero semantics remain exact.
- wait completion due to value change must not be misreported as `Cancelled`.
- a cancel callback must not outlive bounded unregister/teardown logic.

### Proof plan

1. Add attribution benchmarks before changing semantics:
   - `wait_queue_timed_wait_cancel_polling_long`;
   - `wait_queue_timed_wait_cancel_immediate`;
   - `wait_queue_timed_wait_timeout_long_no_cancel`;
   - `wait_queue_timed_wait_value_change_before_cancel`.
2. Extend primitive-facing replay/fuzz to retain wake-order traces for:
   - cancel before sleep;
   - cancel during sleep;
   - value change racing cancel;
   - timeout racing cancel.
3. Add a small model or sim owner that treats cancel wake, value wake, and
   timeout as independent bounded events and checks final classification.
4. Only then prototype Direction A. If proof complexity explodes, fall back to
   Direction B and document why.

### Recommendation

This is the highest-value remaining `static_sync` performance idea, but it
should be treated as a design change rather than a micro-optimization. The
proof surface is large enough that new attribution benches and race-focused
replay cases should land first.

### Experiment update

The first direct prototype was intentionally tried and rejected on the same
day. That version installed a `CancelRegistration` wake callback around the
futex wait and removed the timeout-slice polling when registration succeeded.
It looked attractive on paper, but it exposed a lost-wake race:

- cancellation can fire after the token check but before the futex actually
  parks;
- the callback wake is then lost; and
- the waiter can sleep until the full timeout budget expires.

That prototype was backed out instead of being left in-tree. The next viable
design must close the lost-wake window explicitly rather than just "wake on
cancel".

## Opportunity 2: Bounded Free-Slot Index for `CancelRegistration`

### Current design

`CancelRegistration.register()` in `packages/static_sync/src/sync/cancel.zig`
still finds a slot by walking the fixed `registrations[16]` array from index
`0` upward. The current implementation already skips obvious contention better
than the older version because it loads first and only attempts `cmpxchgStrong`
on zero-valued slots.

That change removed the worst pointless failed exchanges, which is why
`cancel_register_4` dropped sharply in the latest benchmarks.

### Why this is still a performance concern

The path is still linear and still favors the lowest slots:

- repeated churn concentrates cache traffic near the front of the table;
- registration cost still scales with earliest free-slot position; and
- the fixed capacity means the remaining work is pure control-plane overhead,
  not allocator cost.

### Main hypotheses

- H1 high confidence: a bounded free-slot index can reduce registration-path
  cost further, especially under churn.
- H2 medium confidence: a free-slot bitmap is the cleanest bounded design for a
  fixed 16-entry table.
- H3 high confidence: slot order is currently entangled with proof and direct
  test assumptions, so the design cannot silently change ordering behavior.

### Candidate design directions

#### Direction A: atomic free-slot bitmap

Track available slots in a `u16` bitmap:

- `1` bit means slot available;
- registration claims a bit with atomic fetch/update;
- unregister or cancellation fanout returns the bit.

Expected result:

- near-constant slot acquisition cost;
- less repeated probing of occupied slots;
- less cache churn on the registration table itself.

Main risks:

- a plain "first set bit" policy may still bias low slots;
- a rotating or randomized bit choice changes slot order, which may break
  package-owned proof if that order is currently treated as observable;
- keeping bitmap and slot storage consistent across cancel/unregister races must
  be proved carefully.

#### Direction B: hierarchical hint plus local verification

Keep the current array, but add a bounded occupancy summary or coarse hint
structure that narrows the search region without changing final slot policy.

Expected result:

- smaller semantic delta than a full bitmap;
- less cost than scanning every slot from zero each time;
- likely weaker gain than Direction A.

Main risks:

- added state without fully removing the linear scan;
- can become an awkward middle ground if later work still needs the bitmap.

### Contract risk that must be resolved first

Recent experiments already showed that changing registration slot selection can
break package-owned tests and model assumptions. Before implementing either
direction, the package needs an explicit answer to this question:

Is registration slot order an implementation detail, or part of the observable
behavior that callers and proof surfaces rely on?

If order is not a contract:

- update the tests and model owners to prove semantic outcomes rather than
  table position.

If order is a contract:

- prefer a design that preserves lowest-slot allocation while still reducing
  repeated failed probes.

### What has to be proved before changing code

Any implementation must preserve:

- bounded fixed-capacity behavior with no allocation;
- explicit `WouldBlock` when the table is full;
- exactly-once callback fire on cancellation;
- bounded unregister even when cancellation is already in flight; and
- `reset()` only after registration state is cleanly quiesced.

### Proof plan

1. Add registration-shape benchmarks before changing code:
   - `cancel_register_first_slot`;
   - `cancel_register_mid_slot`;
   - `cancel_register_last_slot`;
   - `cancel_register_full_table_would_block`;
   - `cancel_register_unregister_churn_16`.
2. Audit current tests and models for slot-order coupling, then separate:
   - semantic contracts that must remain;
   - incidental slot-position expectations that can be relaxed.
3. Prototype Direction A behind a local implementation branch and rerun:
   - `zig build test`;
   - `zig build harness`;
   - `zig build static_sync_cancel_lifecycle`.
4. If order coupling turns out to be intentional, switch to Direction B or a
   bitmap design that still returns the lowest available bit.

### Recommendation

This is the safer and smaller of the two remaining opportunities, but only if
the order contract is resolved first. The next useful work here is benchmark
and proof preparation, not immediate primitive surgery.

### Experiment update

This item was partially prototyped first because it was the lower-risk change.
The implementation direction that preserves lowest-slot allocation is still the
right starting point, but the follow-up run was interrupted by host-side Zig
build instability on this machine before a trustworthy benchmark verdict could
be recorded. Treat it as still unresolved rather than implicitly accepted.

## Priority Order

1. `wait_queue` cancellation without poll slicing
2. `CancelRegistration` bounded free-slot index

Reasoning:

- `wait_queue` has the larger remaining runtime-shape payoff, especially on
  hostile hosts or under many simultaneous cancelable waits.
- `cancel` registration is more localized and likely easier to optimize, but it
  already improved substantially, so the expected delta is smaller.

## Exit Criteria For This Sketch

Move this sketch out of the live folder when one of these happens:

- an active plan takes ownership of the implementation work; or
- benchmarking and proof work show that the remaining gains are too small to
  justify the added semantic complexity.
