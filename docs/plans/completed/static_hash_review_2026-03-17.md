# `static_hash` review completion record - 2026-03-17

Scope closed: stable hashing, checksums, fingerprints, structural hashing, and
the first package-wide `static_testing` adoption pass.

## Completed outcomes

- classified and justified the std-wrapper surface;
- normalized the stateful wrapper APIs for `wyhash`, `xxhash3`, `siphash`, and
  `crc32`;
- added deterministic replay-backed integration campaigns for byte hashing,
  structural hashing, and `combine`;
- added reduced-failure persistence via replay artifacts and failure bundles;
- added benchmark coverage for byte hashing, fingerprints, structural hashing,
  combiners, and bounded quality sampling;
- added compile-time contract checks for unsupported `hash_any` / `stable`
  surfaces;
- established direct std/crypto differential checks and lower-bound benchmark
  comparisons.

## Final state

- Wrapper overhead is effectively at parity with the direct Zig std/crypto
  baselines for all measured surfaces except a modest sampled `siphash`
  overhead that remains worth rechecking in a longer run.
- The package now has stable package-level validation through
  `static_testing`-backed replay/fuzz coverage plus root benchmark integration.
- Remaining questions are no longer review blockers. They are portfolio and
  future-surface questions captured separately in
  `docs/plans/active/packages/static_hash_algorithm_portfolio_research.md`.

## Validation used during the review

- `zig build test`
- `zig build check`
- `zig build bench`
- `zig build docs-lint`

## Follow-up that stays active

- `docs/plans/active/packages/static_hash_algorithm_portfolio_research.md`
  remains active for future add/defer/reject decisions on new algorithm
  families.
