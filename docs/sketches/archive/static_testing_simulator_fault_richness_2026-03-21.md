# `static_testing` simulator fault richness sketch

## Goal

Expand the deterministic subsystem simulator family so `static_testing` can
model richer network, storage, and time behavior without every downstream user
building a local VOPR-only simulator layer.

This sketch is intentionally broader than the current first simulator pass. The
current modules prove the composition model; this sketch identifies the next
reusable power that is missing.

## Current gap

The current simulator set is good for:

- delayed message delivery;
- delayed storage success/failure completions;
- retry scheduling; and
- deterministic event-loop setup.

It is still too narrow for many realistic failure studies because it does not
yet provide:

- targeted link faults and richer partition strategies;
- congestion or clogging models;
- packet record/replay;
- storage corruption and crash-time durability faults;
- repairability-aware fault distributions; or
- drift-capable simulated time.

## Design posture

- Keep simulator policies explicit and bounded.
- Prefer a small set of strong reusable models over many shallow one-off
  environment helpers.
- Avoid mutating simple existing helpers into confusing catch-all modules if a
  richer simulator deserves a new type.
- Separate "completion helper" surfaces from "durability simulator" surfaces
  when their semantics materially differ.

## Network follow-on design

### Keep

- `testing.sim.network_link` as the simple bounded delivery helper for light
  scenarios.

### Add

- richer partition modes beyond `connected` and `drop_all`
- optional asymmetric partitions
- per-link targeted fault hooks
- path clogging / congestion periods
- packet record/replay for retained diagnosis
- optional small message summary counters

### Likely shape

- either evolve `network_link` carefully with explicit optional policy structs,
  or add a new richer `packet_network`-style simulator and keep
  `network_link` as the minimal surface.

Bias:

- keep `network_link` simple;
- add a richer network simulator if more than one new fault family lands.

## Storage follow-on design

### Keep

- `testing.sim.storage_lane` as the simple async completion helper for retry
  and bounded operation-flow tests.

### Add

- separate read/write latency knobs
- corruption on read and write
- crash-time corruption or dropped-pending-write behavior
- optional misdirected-write style faults
- recoverability-aware fault policies so simulated storage does not mostly
  generate impossible or worthless worlds

### Likely shape

- add a new bounded storage durability simulator rather than forcing all of
  this into `storage_lane`.

## Time follow-on design

### Keep

- `testing.sim.clock` as the simple monotonic logical clock.

### Add

- optional bounded offset/drift profiles
- the ability to expose monotonic and realtime views separately when a
  scenario needs both
- deterministic skew families suitable for leases, heartbeat timeouts, and
  retry policy testing

### Likely shape

- keep the default clock simple and add an opt-in richer time source surface,
  not a mandatory drift model for all fixture users.

## Shared fault-policy guidance

- Prefer explicit config structs or enums over callback-heavy policy trees.
- If multiple simulators need planned external fault schedules, keep using a
  shared deterministic fault-script surface only where it still reads clearly.
- Add repairability-aware fault policies only where the simulator can explain
  why a generated world is still intended to be recoverable.

## Non-goals

- No full OS or runtime emulator.
- No open-ended environment plugin system.
- No hidden wall-clock behavior in simulated state transitions.
- No unbounded network capture or storage tracing.

## Implementation slices

### Slice 1: richer network

- choose whether to extend `network_link` or add a richer sibling module
- land per-link targeted fault policy
- land at least one richer partition strategy
- land optional packet record/replay

### Slice 2: storage durability

- add a new bounded storage durability simulator
- support latency, corruption, and crash behavior
- add one repairability-aware fault policy

### Slice 3: time drift

- add one opt-in drift/offset profile family
- validate with one clock-sensitive downstream scenario

## Early decision questions

- Is the right boundary one richer simulator per domain, or a minimal helper
  plus a richer advanced sibling?
- Which simulator should own packet or operation record/replay retention?
- Should repairability-aware storage policies be simulator-owned or scenario-
  owned with helper generation?
