# `static_serial` follow-up plan

Scope: binary framing, readers, writers, and wire-format helpers.

Status: review pass closed. Primary record:
`docs/plans/completed/static_serial_review_2026-03-20.md`.

## Current posture

- The 2026-03-20 package review is complete and remains the source of truth for
  parser and codec malformed-input replay, incremental `testing.model`
  coverage, and shared serialization benchmark adoption.
- `static_serial` is now the reference downstream adopter for transport-agnostic
  framing review on shared `static_testing` surfaces.
- No package-local review tasks remain open from that pass.

## Open follow-up triggers

- Open new work only if a real framing or codec bug class appears.
- Add package-local follow-up only if a canonical serialization benchmark
  signal appears.
- Revisit the boundary only if framing ownership starts to drift into socket,
  process, or runtime concerns.
