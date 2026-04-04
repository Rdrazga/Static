# `static_testing` ordered-effect sequencer sketch

## Goal

Add a small bounded helper for reassembling out-of-order effects into a stable
expected sequence.

The TigerBeetle comparison surfaced this as a missing reusable utility. The
concept is generic even though TigerBeetle uses it for replies.

## Why this belongs in `static_testing`

- Protocol, transport, queue, and process-driver tests often need to verify a
  canonical ordered stream while effects may arrive out of order.
- Current `static_testing` primitives support traces and temporal assertions,
  but they do not yet provide one reusable bounded helper for holding,
  deduplicating, and releasing out-of-order effects.
- Downstream users should not have to rebuild this logic package by package.

## Proposed boundary

Add a helper that:

- accepts effects tagged by sequence number or monotonic ordinal;
- buffers out-of-order items up to a fixed capacity;
- rejects or ignores duplicates under explicit policy;
- exposes whether the next expected item is ready;
- releases ready items in order; and
- reports pending/free capacity for diagnostics.

## Candidate vocabulary

- `OrderedEffectSequencer(comptime T: type, comptime capacity: usize)`
- `insert(sequence_no: u64, effect: T) -> Result`
- `contains(sequence_no: u64) -> bool`
- `peekReady(next_expected: u64) -> ?T`
- `popReady(next_expected: *u64) -> ?T`
- `pendingCount() -> usize`
- `free() -> usize`

Potential insert result modes:

- accepted
- duplicate_ignored
- no_space
- stale

## Design posture

- Keep the helper generic and payload-agnostic.
- Do not bake protocol-specific header semantics into the library layer.
- Prefer deterministic explicit behavior on duplicates and stale items.
- Keep storage bounded and introspectable.

## Relationship to other `static_testing` surfaces

- This should complement traces and temporal checks, not replace them.
- It may later feed richer pending-reason reporting for repair/liveness
  execution.
- It should be usable from `testing.system`, `testing.process_driver`, or
  package-owned model/sim tests without pulling in swarm orchestration.

## Non-goals

- No reliable-transport implementation.
- No network simulator embedded into the helper.
- No persistent artifact format in the first version.
- No automatic shrinking or replay logic owned by the sequencer itself.

## Implementation slices

### Slice 1: bounded core helper

- fixed-capacity storage
- insert/contains/peek/pop/free APIs
- duplicate and stale handling
- unit tests for ordering, duplicate handling, and capacity pressure

### Slice 2: diagnostics

- small summary formatter or status view
- optional typed pending reason integration if the repair/liveness design uses
  it

### Slice 3: downstream proof

- move one real package scenario onto the helper, preferably a protocol or
  process-driver flow

## Early decision questions

- Should the helper own the next expected sequence, or should callers own it
  explicitly?
- Should duplicate handling be configurable, or fixed to one safe default in
  the first version?
- Is a min-heap, dense ring, or small sorted buffer the best bounded
  implementation for the expected use cases?
