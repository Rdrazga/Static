# `static_bits` follow-up plan

Scope: bit-level readers, writers, layouts, cursors, and varint helpers.

Status: review pass closed. Primary record:
`docs/plans/completed/static_bits_review_2026-03-20.md`.

## Current posture

- The 2026-03-20 package review is complete and remains the source of truth for
  the detailed cleanup and adoption work.
- `static_bits` is now the foundation-layer reference for malformed-input
  replay/fuzz coverage plus shared cursor and varint benchmark workflows.
- No package-local review tasks remain open from that pass.

## Open follow-up triggers

- Open new work only if a real malformed-runtime bug class appears.
- Add package-local follow-up only if a new canonical cursor or varint
  benchmark signal appears.
- Revisit the package boundary only if `static_testing` changes in a way that
  affects malformed-runtime replay, retained failures, or benchmark review.
