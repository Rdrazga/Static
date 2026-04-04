# `static_testing` - VOPR-like deterministic simulator framework (sketch)

## Goal

Provide a reusable library for building deterministic, single-threaded simulators ("VOPRs") that:
- run real production code against simulated environments (time/network/storage/etc.),
- advance simulated time faster than wall-clock (no sleeps, no OS waits),
- are observable (structured events, traces, reproducible failure reports),
- support long-horizon and continuous runs (millions+ of steps) with explicit bounds,
- provide first-class fault injection + fuzz/swarm testing helpers.

This sketch is intentionally biased toward **modularity**: `static_testing` should supply the
engine + building blocks, while each package/app supplies a thin "scenario harness" that
composes those blocks.

## Why TigerBeetle VOPR is the reference pattern

TigerBeetle's VOPR demonstrates a practical shape for deterministic simulation testing:
- all randomness comes from a seedable PRNG and is reproduced via a seed,
- the simulator runs single-threaded but models concurrency via scheduled events,
- time is simulated and can advance without waiting,
- failures are actionable (seed/options + short logs),
- swarm testing is used to explore many configurations (some variants disabled, others weighted),
- the harness can run in different modes (lite/perf/swarm) with bounded tick budgets.

`static_testing` should make it cheap to build a TigerBeetle-style harness for *any* static_* package
without copy-pasting a bespoke simulator.

## Design principles (AGENTS.md aligned)

- Safety-first: enforce invariants and bounds aggressively; fail fast on protocol corruption.
- Determinism is a contract: no hidden sources of entropy; all "randomness" is PRNG-driven.
- Explicit bounds: maximum ticks, maximum events, maximum allocations, maximum queue sizes.
- Simplicity: small composable modules; avoid "framework magic" that hides control flow.
- Production integration: prefer dependency injection via small interfaces over rewriting code.

## Non-negotiable constraints (2026-03-05)

- Use Zig `std` implementations for host/runtime surfaces wherever possible (`std.time`, `std.fs`,
  `std.io`, `std.process`, `std.heap`, `std.PriorityQueue`, `std.Random`).
- Keep deterministic simulation logic explicit in `static_testing`; do not depend on wall-clock
  behavior for simulator correctness.
- Avoid custom wrappers around `std` unless there is clear added value (determinism, boundedness,
  or a required adapter for production-code injection).
- Separate control-plane and data-plane concerns:
  - Control-plane (CLI, report persistence, long-run orchestration) should use `std` directly.
  - Data-plane (simulated time/network/storage faults) should remain deterministic and bounded.

## TigerBeetle parity baseline

The TigerBeetle VOPR parity audit is documented in:

- `docs/sketches/static_testing_tigerbeetle_vopr_parity_map.md`

That document is the source of truth for:
- which TigerBeetle VOPR features should be copied directly,
- which should be adapted into generic `static_testing` APIs,
- which are TigerBeetle-specific and should remain harness-level code.

## Proposed structure (package layout)

Add a new package:

`packages/static_testing/src/root.zig`
- exports `sim`, `time`, `fuzz`, `fault`, `observe`, `runner`, and common helpers.

Core modules (package-agnostic, reusable):
- `testing/sim.zig`: engine core (PRNG, event queue, tick loop).
- `testing/time.zig`: simulated clock, durations, timers.
- `testing/runner.zig`: multi-seed / long-horizon execution helpers (CI-friendly).
- `testing/observe.zig`: observer interface + default observers (log/trace/null).
- `testing/fault.zig`: fault injector + fail points + schedules.
- `testing/fuzz.zig`: deterministic distributions + swarm config helpers.

Environment building blocks (opt-in, reusable but not forced):
- `testing/env/network.zig`: packet simulator (drop/delay/reorder/partition).
- `testing/env/storage.zig`: deterministic "disk" (latency, errors, corruption, crash).
- `testing/env/io_backend.zig`: a simulated backend that can satisfy `static_io.backend` contracts.
- `testing/env/os.zig`: capability model (what the simulated "OS" supports).

The engine should not depend on any specific production subsystem; env modules can.

## Core concept: single-threaded engine, scheduled concurrency

### `Sim` responsibilities

`Sim` owns:
- `seed: u64` (repro data)
- `prng: PRNG` (deterministic)
- `now_tick: u64` and/or `now_ns: u64` (simulated time)
- an **event scheduler** (bounded queue of due work)
- a **tick loop** with explicit budgets
- fault injector state
- observer hooks

`Sim` does *not* own production state directly. The harness owns production state and calls it
from scheduled events.

### Event scheduling primitives

Minimum required primitives:
- schedule "run this callback now" (same tick)
- schedule "run after N ticks"
- schedule "run at tick T"
- cancel scheduled work (best-effort, bounded)

Implementation candidates:
- reuse `static_scheduling.timer_wheel.TimerWheel(T)` for tick-based scheduling, or
- use a bounded min-heap priority queue for arbitrary timestamps.

Decision bias:
- timer wheel is simpler and deterministic for tick-based models (aligns with "tick speed").
- use a heap only if sub-tick precision or huge time ranges make wheel impractical.

### "Tick speed" and time warping

Expose two orthogonal knobs:
- `tick_ns`: how many simulated nanoseconds one tick represents
- `max_ticks`: hard bound on run length

Then `Sim` can:
- run "as fast as CPU" while advancing simulated time,
- optionally "skip ahead" to the next scheduled event tick when idle.

Key requirement: skipping must be deterministic and observable (observer gets notified).

## Production-code integration strategy

The hard problem is: production code typically calls OS time, OS IO, and uses real threads.
`static_testing` should solve this by making production code depend on *interfaces*.

### Recommended injection points

1. **Time**
   - production accepts a `Time` interface with `now()`, `deadline()`, and timer scheduling.
2. **IO**
   - production accepts an `IO` interface or a `static_io.Runtime` with a backend that can be simulated.
3. **Randomness**
   - production accepts a PRNG interface; the simulator provides a deterministic stream.
4. **Scheduling**
   - production uses `static_scheduling` abstractions (executor/poller/timer wheel) that can have a sim backend.

`static_testing` should supply adapters that make this convenient, but it should not attempt
to transparently replace `std.time` or `std.Thread` at link time.

### `std`-first integration policy

- **Time (host):** use `std.time` for wall-clock budgets, telemetry timestamps, and runner timeouts.
- **Time (sim):** keep a deterministic simulated clock (`tick`-advanced), exposed through a narrow
  interface; this is not a wrapper over wall-clock `std.time.Instant`.
- **IO (host):** use `std.fs` and `std.io` for report/log artifacts and orchestration plumbing.
- **IO (sim):** keep deterministic simulated device/network/storage backends with explicit fault
  models; optionally expose `std.io.Reader`/`Writer` compatible facades where practical.
- **PRNG:** default to deterministic `std.Random`-backed generation seeded from explicit `u64`;
  keep the PRNG pluggable so packages can opt into `static_rng` if needed.
- **Threading:** simulator core remains single-threaded; host orchestration may use `std.Thread`
  when needed for parallel seed runners.

## Observability model

### Observer interface

Provide a small, explicit observer interface; examples:
- `onStart(seed, options_hash)`
- `onTick(now_tick, now_ns)`
- `onEvent(event_kind, metadata)`
- `onFault(point, action)`
- `onInvariantFailure(reason)`
- `onFinish(stats)`

Offer standard observers:
- `NullObserver`: fastest, zero overhead.
- `LogObserver`: prints short or full logs (TigerBeetle-style mode switch).
- `TraceObserver`: emits `static_profile` events and can write Chrome traces.

### Failure report payload

When a run fails, return a deterministic report containing:
- seed
- options/config snapshot (or a stable hash + readable dump)
- last N events (ring buffer)
- stats (ticks executed, events scheduled, dropped packets, injected faults)

This should be cheap to produce and easy to replay.

## Fault injection model

### Fail points

Define fail points as explicit identifiers:
- comptime string name hashed to `u64`, or
- an enum in the harness (preferred for refactors and compiler checking).

Example conceptual API:
- `fault.shouldFail(.disk_read) bool`
- `fault.failOr(.disk_read, error.Timeout) T` (helpers returning vocabulary-compatible errors)

### Fault schedules (deterministic)

Support multiple fault strategies, all deterministic under PRNG:
- `probability`: fail with ratio `p`
- `burst`: fail for N operations then stable for M operations
- `after_n`: fail the Nth time a point is hit
- `window`: fail only within tick range [a..b]

All strategies must be bounded and require explicit configuration.

## Fuzz + swarm testing helpers

`static_testing.fuzz` should provide reusable deterministic distributions:
- exponential-ish integer distributions (hot/cold ID sets)
- random enum weights ("swarm testing": disable some variants, weight the rest)
- seed parsing helpers (decimal, and optionally 40-char hex commit hashes)

Also provide runner helpers:
- `runManySeeds(seeds_max, per_seed_ticks_max, ...)`
- periodic progress printing with deterministic cadence (e.g. every N seeds)
- stop-on-first-failure vs continue-and-collect

## Long-horizon / continuous runs

Provide two execution modes:

1. **Zig test mode** (fast, bounded)
   - used inside `test {}` blocks
   - hard bounds: ticks/events/time budget; returns `error.Timeout` or asserts on invariants

2. **Runner mode** (CI / local endurance)
   - a `zig build` step or standalone executable that can:
     - run for many seeds, or for a wall-clock budget,
     - save failing seeds + reports to disk,
     - optionally bisect/shrink later (future).

The library should not force one mode; it should make both easy.

## Concrete first consumer candidates (to validate design)

Pick a first user that already benefits from deterministic simulation:
- `static_io`: simulate IO completions/timeouts without OS backends.
- `static_queues`: replace brittle lock-free stress tests with a deterministic scheduler + model checking of invariants.
- `static_scheduling`: test timer wheel and executor behavior under simulated time and injected cancellations.

The first consumer should drive API shape (avoid over-design).

## Open questions / decisions to make early

- Do we standardize on tick-based time (wheel), or allow mixed tick + ns scheduling (heap)?
- Do we lock to one deterministic `std.Random` algorithm/version in `static_testing` to guarantee
  cross-version reproducibility?
- How do we represent "simulated environment capabilities" (OS/network/disk) without duplicating `static_core.options`?
- What is the minimal observer interface that still makes failures actionable?

## Suggested next step (implementation planning)

Write a small "Hello simulator" pilot:
- deterministic PRNG + timer wheel + observer + runner,
- one simulated subsystem (network or io backend),
- one production component under test (start with something already modular like `static_scheduling.timer_wheel`).

The pilot should establish:
- the event scheduling model,
- the failure-report format,
- the bounds discipline.
