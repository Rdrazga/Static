# `static_string`

Bounded string, ASCII, UTF-8, and deterministic interning utilities for the
`static` workspace.

## Current status

- The root workspace build is the supported entry point; package-local
  `zig build` is not supported.
- The package stays centered on bounded text storage, explicit encoding
  validation, and deterministic symbol interning.
- `tests/integration/` owns malformed-text replay/fuzz coverage and
  sequence-sensitive intern-pool modeling.
- `benchmarks/` owns the canonical text-validation and interning review
  workloads under the shared benchmark artifact contract.
- The current package posture is closed from the 2026-03-21 review and the
  2026-03-23 follow-up record.

## Main surfaces

- `src/root.zig` exports the package API and package-level encoding helpers.
- `src/string/bounded_buffer.zig` owns the fixed-capacity append buffer
  contract.
- `src/string/utf8.zig` owns explicit UTF-8 validation behavior.
- `src/string/ascii.zig` owns ASCII-focused helpers and normalization.
- `src/string/intern_pool.zig` owns deterministic bounded interning, symbols,
  and lookup behavior.
- `tests/integration/root.zig` wires the package-level deterministic
  regression suite.
- `benchmarks/` holds the canonical shared-workflow benchmark entry points.
- `examples/` holds bounded usage examples for the exported surfaces.

## Validation

- `zig build check`
- `zig build test`
- `zig build bench`
- `zig build examples`
- `zig build docs-lint`

## Key paths

- `tests/integration/replay_fuzz_malformed_text.zig` covers malformed UTF-8,
  ASCII normalization, bounded-buffer behavior, and retained replay bundles.
- `tests/integration/model_intern_pool_sequences.zig` covers sequence-sensitive
  intern, resolve, contains, and reset behavior.
- `benchmarks/text_validation_normalize.zig` and
  `benchmarks/intern_pool_duplicate_lookup.zig` define the canonical benchmark
  review workloads.
- `benchmarks/support.zig` holds the shared benchmark helper code.
- `examples/ascii_normalize_basic.zig`,
  `examples/bounded_buffer_basic.zig`,
  `examples/intern_pool_basic.zig`, and
  `examples/utf8_validate_basic.zig` show the supported usage paths.
- `docs/plans/completed/static_string_review_2026-03-21.md` records the review
  outcomes.
- `docs/plans/completed/static_string_followup_closed_2026-03-23.md` records
  the closure posture and reopen triggers.

## Benchmark artifacts

- Benchmark outputs live under `.zig-cache/static_string/benchmarks/<name>/`.
- Canonical review artifacts stay on shared `baseline.zon` plus
  `history.binlog`.
- Re-record baselines when workload shape, validation semantics, or symbol
  density change materially.
