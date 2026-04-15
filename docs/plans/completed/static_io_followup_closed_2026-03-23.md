# `static_io` follow-up plan

Scope: I/O runtime pieces, backends, and buffer-pool integration.

Status: review pass closed. Primary record:
`docs/plans/completed/static_io_review_2026-03-20.md`.

## Current posture

- The 2026-03-20 package review is complete and remains the source of truth for
  the detailed downstream `static_testing` adoption work.
- `static_io` is now the runtime-heavy reference adopter for `testing.system`,
  `testing.process_driver`, shared subsystem simulators, deterministic fuzzing,
  retained failure bundles, and shared benchmark workflows.
- No package-local review tasks remain open from that pass.

## Open follow-up triggers

- Open new work only if a real runtime or backend bug class appears.
- Add package-local follow-up only if a canonical runtime or buffer benchmark
  regression appears.
- Revisit the package boundary only if real downstream use exposes a mismatch
  in `testing.system`, `testing.process_driver`, or shared simulator
  ownership.
