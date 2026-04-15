# `static_net` follow-up plan

Scope: network-facing address, frame, and protocol utilities.

Status: review pass closed. Primary record:
`docs/plans/completed/static_net_review_2026-03-20.md`.

## Current posture

- The 2026-03-20 package review is complete and remains the source of truth for
  malformed-frame replay/fuzz, incremental decoder model coverage, and shared
  benchmark adoption.
- `static_net` is now the reference downstream adopter for transport-agnostic
  protocol-framing review on shared `static_testing` surfaces.
- No package-local review tasks remain open from that pass.

## Open follow-up triggers

- Open new work only if a real protocol bug class appears.
- Add package-local follow-up only if a canonical protocol benchmark signal
  appears.
- Revisit the boundary only if `static_net` and `static_net_native` ownership
  starts to drift.
