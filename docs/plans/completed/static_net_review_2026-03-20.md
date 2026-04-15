# `static_net` review completion record - 2026-03-20

Scope closed: network-facing address, frame, and protocol utilities, and the
package-wide `static_testing` adoption pass.

## Completed outcomes

- landed a package-level `tests/integration/` suite that uses
  `testing.fuzz_runner`, `testing.corpus`, `testing.replay_runner`, and
  `testing.failure_bundle` for malformed frames, checksum mismatches,
  truncated decode, retained malformed-frame reproducers, and replay-backed
  protocol diagnostics;
- landed a second real downstream package migration onto `testing.model` for
  sequence-sensitive incremental decoder feed, close-input, corruption,
  truncation, noncanonical-length, and reset behavior;
- normalized the package benchmarks onto shared `bench.workflow`,
  `baseline.zon`, and `history.binlog` artifacts for full-frame encode/decode
  throughput and checksum-enabled incremental roundtrip hot paths;
- kept framing and protocol utilities transport-agnostic and package-local
  rather than pushing socket/process ownership down into `static_serial` or up
  into `static_net_native` / `static_io`.

## Final state

- `static_net` now serves as the reference downstream adopter for
  protocol-framing malformed-input replay/fuzz coverage, incremental
  `testing.model` decoder review, and shared protocol benchmark workflows.
- Examples are no longer the canonical proof for malformed frame handling or
  incremental decoder behavior; retained deterministic integration tests are.
- No package-blocking `static_testing` adoption gaps remain from this review
  pass. Future work should be logged as a new follow-up plan only when a real
  protocol bug class, benchmark signal, or boundary issue justifies more
  package work.

## Validation used during the review

- `zig build check`
- `zig build test --summary all`
- `zig build bench --summary all`
- `zig build docs-lint`

## Follow-up that stays active

- None. Open a new plan if a new protocol bug class, benchmark signal, or
  transport-boundary issue justifies more package work.
