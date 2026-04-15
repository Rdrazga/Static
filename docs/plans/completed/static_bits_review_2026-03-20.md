# `static_bits` review completion record - 2026-03-20

Scope closed: bit-level readers, writers, layouts, cursors, varint helpers,
and the package-wide `static_testing` adoption pass.

## Completed outcomes

- landed a package-level `tests/integration/` suite that uses
  `testing.fuzz_runner`, `testing.corpus`, `testing.replay_runner`, and
  `testing.failure_bundle` for malformed runtime bytes, cursor-boundary
  regressions, and retained malformed-varint reproducers;
- normalized the package benchmarks onto shared `bench.workflow`,
  `baseline.zon`, and `history.binlog` artifacts for cursor/endian and
  cursor-based varint roundtrip hot paths;
- kept compile-fail misuse checks package-local and explicit instead of forcing
  comptime-invalid shapes through `static_testing`;
- removed duplicated cursor position-validation invariants behind shared helper
  functions so byte/bit reader and writer ownership rules are documented in one
  place.

## Final state

- `static_bits` now serves as the reference foundation-layer downstream adopter
  for narrow malformed-input replay/fuzz coverage and shared benchmark review.
- Examples are no longer the canonical proof for runtime malformed decode or
  cursor-boundary behavior; retained deterministic integration tests are.
- No package-blocking `static_testing` adoption gaps remain from this review
  pass. Future work should be logged as a new follow-up plan only when a real
  codec or boundary bug class appears.

## Validation used during the review

- `zig build check`
- `zig build test --summary all`
- `zig build bench --summary all`
- `zig build docs-lint`

## Follow-up that stays active

- None. Open a new plan if a new malformed-runtime bug class or benchmark
  signal justifies more package work.
