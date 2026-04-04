# `static_testing` TigerBeetle VOPR design review

## Snapshot

- Review date: `2026-03-22`
- Local TigerBeetle snapshot: `.tmp/tigerbeetle`
- Core files inspected:
  - `.tmp/tigerbeetle/src/vopr.zig`
  - `.tmp/tigerbeetle/src/testing/packet_simulator.zig`
  - `.tmp/tigerbeetle/src/testing/storage.zig`
  - `.tmp/tigerbeetle/src/testing/time.zig`
  - `.tmp/tigerbeetle/src/testing/reply_sequence.zig`
- Current `static_testing` files compared:
  - `packages/static_testing/src/testing/swarm_runner.zig`
  - `packages/static_testing/src/testing/system.zig`
  - `packages/static_testing/src/testing/liveness.zig`
  - `packages/static_testing/src/testing/sim/network_link.zig`
  - `packages/static_testing/src/testing/sim/storage_durability.zig`
  - `packages/static_testing/src/testing/sim/clock.zig`
  - `packages/static_testing/src/testing/ordered_effect.zig`

## Why this review still matters

TigerBeetle VOPR remains a useful reference because it is a serious
deterministic fault-heavy review harness with long-run campaign pressure. The
point of this review is not feature parity for its own sake. The point is to
check whether `static_testing`, as a Zig library for unknown users, still lacks
any reusable core capability that TigerBeetle proves is worth having.

This review now uses the tightened `static_testing` boundary:

- leave repo- and application-specific policy to callers by default;
- keep most long-run triage policy caller-owned unless the repo itself needs a
  shared contract;
- do not keep active work that exists only to collect more adopters or more
  scenarios; and
- prefer bounded lower-level primitives over a larger framework surface when
  callers can compose the missing policy themselves.

## Capability comparison

### Areas where `static_testing` is now strong

- Seed handling, replay, retained artifacts, provenance, and failure-bundle
  design are broader and more library-friendly than TigerBeetle's
  system-specific harness surfaces.
- `testing.system` and `testing.process_driver` give `static_testing` a more
  reusable composition layer than VOPR's single-system orientation.
- `testing.liveness` plus the `testing.system` bridge now cover the generic
  safety-to-repair execution pattern that was previously missing.
- `testing.sim.network_link` and `testing.sim.storage_durability` now provide
  enough bounded fault power to cover transport and durable-state studies
  without forcing application-specific simulation into the shared library.
- `testing.ordered_effect` now closes the ordered-effect gap that TigerBeetle's
  `ReplySequence` had highlighted.

### Areas where `static_testing` is intentionally narrower

- VOPR can bake in stronger campaign-retention and triage policy because
  TigerBeetle owns the whole system under test.
- `static_testing` now intentionally stops short of shared retained simulator
  persistence, aggressive scenario growth, and caller-specific long-run
  heuristics.
- VOPR can let its swarm and repair paths be more opinionated because its repo
  owns the workload, storage semantics, and correctness model.

That narrowing is deliberate, not a gap by itself.

## Design ideology comparison

### TigerBeetle VOPR

- tightly integrated with one system design;
- free to encode repo-specific failure policy;
- optimized for one high-value distributed target; and
- willing to carry stronger built-in orchestration and triage assumptions.

### `static_testing`

- library-first rather than system-first;
- bounded, caller-owned policy by default;
- explicit artifact and replay contracts instead of one built-in workflow;
- lower-level escape hatches are acceptable and expected; and
- active repo work should stop at reusable core contracts, not convenience
  policy that callers can implement themselves.

The result is that `static_testing` should not chase VOPR feature parity once a
missing idea becomes caller-owned policy rather than shared library boundary.

## Final decision on remaining reusable gaps

With the tightened boundary, most of the earlier VOPR-inspired gaps are now
either closed or intentionally caller-owned.

### Closed or sufficiently addressed

- Safety-to-repair/liveness execution:
  landed through `testing.liveness`, pending reasons, retained metadata, and
  the `testing.system` bridge.
- Rich network fault simulation:
  landed far enough for the shared boundary through partitions, route faults,
  congestion windows, backlog pressure, and caller-owned replay.
- Rich storage fault simulation:
  landed far enough for the shared boundary through crash/recover, corruption,
  misdirected writes, acknowledged-without-store faults, stabilization, and
  caller-owned replay.
- Drift-capable simulated time:
  landed through `testing.sim.clock.RealtimeView`.
- Ordered-effect reassembly:
  landed through `testing.ordered_effect`.

### Intentionally caller-owned or out of scope

- shared retained simulator artifact formats beyond caller-owned replay;
- additional `testing.system` hardening that depends on collecting more
  downstream adopters;
- “prove it in more scenarios” work for provenance, system, or repair/liveness
  surfaces;
- snapshot helpers, strategy/shrinking, and coverage-guided interop as active
  library work; and
- long-run triage/reporting preferences that callers can implement around
  stable swarm records and retained bundles.

## Remaining repo-owned question

One substantive VOPR-adjacent question still looks worth keeping on the active
repo queue:

### Swarm long-run policy

The open question is not whether `static_testing` can run long campaigns. It
already can. The question is whether the library itself should own more of the
bounded campaign-review policy around:

- clustering many similar failures into fewer review buckets;
- retaining only the most useful failures under a bounded artifact budget;
- seed prioritization or seed-promotion heuristics across variants; and
- merged deterministic summaries across resumed or sharded runs.

This still may or may not belong in the library:

- it is valuable if the repo itself needs one canonical bounded campaign-review
  contract;
- it is not valuable if it collapses into review preference that callers can
  post-process from `swarm_campaign.binlog`, retained bundles, and provenance
  sidecars.

So the remaining active decision is narrow:

- keep swarm execution deterministic and bounded;
- keep artifact policy caller-owned;
- only add more long-run campaign heuristics if the repo needs a shared
  contract, not because VOPR has one.

## Report summary

Compared to TigerBeetle VOPR, `static_testing` is now in a good place for its
actual job:

- broader as a reusable library;
- intentionally less opinionated in caller workflow policy;
- no longer missing any obvious core reusable primitive except possibly a
  stronger swarm campaign-review contract; and
- correctly refusing to absorb work that belongs to callers, repo-specific
  scripts, or future concrete package pressure.

That means the final design stance is:

- keep `static_testing` focused on bounded reusable contracts;
- leave scenario count, workflow taste, and most campaign triage policy to
  callers; and
- treat TigerBeetle VOPR as a design reference, not a parity checklist.
