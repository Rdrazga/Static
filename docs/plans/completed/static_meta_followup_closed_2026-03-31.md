# `static_meta` follow-up plan

Scope: compile-time type IDs, registries, and metadata helpers.

Status: follow-up closed on 2026-03-31. The bounded runtime registry model
slice is landed, and no concrete package-local debt remains from the 2026-03-24
sweep.

## Current posture

- `static_meta` keeps pure comptime invariants on direct tests and uses
  `testing.model` only for the small runtime registry path.
- The package boundary remains intentionally narrow, with no current need for
  replay, simulation, or benchmark expansion.
- No concrete unfinished package-local follow-up remains from the current
  sweep.

## Open follow-up triggers

- Reopen only if downstream runtime usage makes registry mutation or lookup
  materially broader.
- Add retained invalid-metadata replay only if real reproducers start showing
  up in review.
- Add benchmark work only if runtime registry lookup or registration becomes a
  proven hot path.
