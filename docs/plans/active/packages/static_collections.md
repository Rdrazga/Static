# `static_collections` active plan

Scope: fixed-capacity and allocation-aware collection types, reopened only for
generic ECS-readiness follow-up that still belongs below a future
`static_ecs` package.

## Review focus

- The package boundary is already narrowed and the main root-surface follow-up
  is closed under `docs/plans/completed/static_collections_followup_closed_2026-04-03.md`.
- The ECS readiness review found one remaining generic question that is now
  concrete rather than hypothetical: whether packed swap-remove should expose
  relocation metadata as an additive generic helper, or whether that policy
  should remain entirely ECS-owned.
- The right end state is not "make `DenseArray` slightly nicer for ECS". The
  right end state is "either admit one truthful generic packed-storage helper
  that helps multiple callers, or reject extraction cleanly and keep the
  reverse-map policy in higher layers."
- Keep the package generic. Do not add archetype, chunk, entity-row, world, or
  query-view semantics here.

## Current state

- `Handle`, `IndexPool`, `SparseSet`, `Vec`, and the map families are already
  retained as reusable substrate for a future `static_ecs` package.
- `DenseArray` is now explicitly documented as a packed, index-addressed array
  with O(1) swap-remove and positional-index invalidation.
- `DenseArray.swapRemove()` currently returns only the removed value. That
  keeps the API simple, but it means callers that maintain a reverse map must
  derive relocation details manually after each removal.
- The package follow-up record already defers packed-storage benchmarks until a
  concrete ECS-adjacent hot path justifies admitting one.

## Current decision note

Default recommendation: reject generic relocation-helper extraction unless a
candidate shape clearly improves the generic packed-array contract for more than
one caller family.

Current candidate outcomes:

- `relocation indices only`
  Current recommendation: reject.
  Reason:
  - this still forces many callers to do a second read to discover which value
    moved;
  - it adds permanent API surface without clearly reducing bug risk outside ECS
    reverse-map bookkeeping.
- `relocation indices plus moved element value`
  Current recommendation: accept only if at least one non-ECS packed-storage
  caller or one package-local proof shows the same ambiguity reduction matters
  outside `static_ecs`.
  Reason:
  - this is the first candidate that could plausibly improve the generic
    packed-storage contract rather than just exporting ECS bookkeeping.
- `explicit rejection with relocation kept caller-owned`
  Current recommendation: preferred outcome unless the stronger helper above
  clears the multi-caller genericity bar.
  Reason:
  - `DenseArray` is still truthful and complete as a packed array without
    relocation metadata;
  - keeping relocation policy in higher layers avoids freezing a weak helper
    just because ECS has a concrete use case.

## Approval status

Approved direction for the current queue:

- approve task 1 as real implementation work: close the boundary decision with
  an explicit accepted or rejected outcome;
- approve task 2 only if task 1 overturns the current default and names one
  stronger generic helper shape;
- otherwise keep relocation bookkeeping in `static_ecs` and treat that as the
  approved durable outcome rather than as a temporary missing feature.

## Ordered SMART tasks

1. `Packed-removal boundary decision`
   Record whether relocation metadata for packed swap-remove is generic enough
   to belong in `DenseArray`, or whether it should remain ECS-owned in a future
   `static_ecs` chunk store.
   Add or reject using this gate:
   - accept only if the helper improves at least the generic packed-array
     contract itself rather than only an ECS reverse-map workflow;
   - reject if the helper would only move bookkeeping from ECS callers into a
     collection API without reducing ambiguity or bug risk for non-ECS callers;
   - reject any shape that requires `DenseArray` to know about handles,
     entities, rows, chunks, or side indexes.
   Current smallest bounded slice:
   - refine the default decision note above only if new evidence overturns it;
   - compare the exact candidate shapes before accepting one:
     - relocation indices only;
     - relocation indices plus moved element value;
     - explicit rejection with relocation kept caller-owned.
   Done when the plan records one explicit outcome:
   - reject generic relocation metadata and keep the exact reverse-map helper in
     `static_ecs`; or
   - accept one additive packed-storage helper with no ECS vocabulary.
   Validation:
   - `zig build docs-lint`
2. `DenseArray relocation helper slice`
   If task 1 accepts a generic helper, add one additive relocation-aware
   removal surface while keeping `DenseArray` index-addressed and generic.
   Current preferred acceptance constraints:
   - keep `swapRemove(index)` unchanged;
   - add at most one additive helper;
   - pin the exact semantics for the no-move tail case;
   - pin whether the helper returns only relocation indices or also returns the
     moved element value, based on task 1's boundary decision.
   Done when:
   - the accepted additive API exists in `dense_array.zig`;
   - doc comments explain when relocation metadata is absent versus present;
   - direct tests prove the no-move tail case, the moved-tail case, and that
     the helper does not change `swapRemove()` semantics.
   Validation:
   - `zig build test`
   - `zig build docs-lint`
3. `Proof ownership and benchmark admission decision`
   Tighten the package-owned proof surface for the accepted outcome and decide
   whether packed-storage churn now has enough generic value for a first shared
   benchmark owner.
   Outcome:
   - if task 2 lands, add one direct package-owned integration proof that
     mirrors the reverse-map caller pattern without importing ECS terms;
   - if task 2 is rejected, record why packed relocation remains ECS-owned and
     keep the benchmark deferred;
   - admit a benchmark only if another non-ECS packed-storage caller or review
     need appears alongside the ECS-driven use case.
   Done when proof ownership and benchmark posture are both recorded in this
   plan and the matching tests or docs exist.
   Validation:
   - `zig build test`
   - `zig build docs-lint`

## Testing fit

- Keep direct integration tests as the primary proof surface for packed-storage
  relocation contracts.
- Reuse `static_testing.testing.model` only if the accepted helper grows into a
  mutation-sequence surface more complex than one-step remove-and-relocate
  fixtures.

## Work order

1. Decide whether the helper is truly generic.
2. Implement the additive API only if the answer is yes.
3. Tighten proof ownership and benchmark posture after the API decision lands.

## Ideal state

- `static_collections` remains free of ECS vocabulary.
- Generic packed-storage callers either get one truthful relocation helper or a
  documented rejection that keeps relocation policy in higher layers.
- The package avoids the worst middle ground: a helper that still forces every
  caller to infer the real moved-item state while paying permanent API surface
  cost.
- A future `static_ecs` package can build chunk storage on the package without
  needing ad hoc contract reinterpretation.
