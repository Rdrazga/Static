# `static_hash` follow-up plan

Scope: stable hashing, checksums, and fingerprint primitives.

Status: follow-up closed on 2026-04-01. The sequence-harness extraction
decision, root-surface contract review, and quality-sample telemetry decision
are all recorded, so package-boundary follow-up is complete. The algorithm
portfolio research stays active as its own separate plan.

## Current posture

- Sequence-harness extraction outcome: keep local. The reusable generic runner,
  action recording, and reduction mechanics already live in
  `static_testing.testing.model`; the remaining `model_streaming_hashers.zig`
  scaffolding is specific to the streaming-hasher family, seeded hasher setup,
  finalize/verify ordering, and bounded digest comparison.
- Root-surface contract outcome: keep the algorithm modules, keep the narrow
  convenience type aliases (`HashBudget`, `HashBudgetError`, `Seed`, and
  `Pair64`), and keep the existing top-level helper functions for `hashAny*`,
  `hashTuple*`, `fingerprint*`, `combine*`, and `stable*`. The root already
  serves as the supported downstream entry point, and the current re-export set
  is tested directly against the owning modules. Do not add more convenience
  exports without a new explicit review.
- Quality-sample telemetry outcome: keep `benchmarks/quality_samples.zig` as
  bounded direct telemetry under `zig build bench` while it remains a spot
  check with no durable pass/fail thresholds. Promote it onto canonical
  baseline/history review only if downstream review needs longitudinal quality
  comparisons or gating on those metrics.

## Open follow-up triggers

- Reopen only if the root surface starts growing new convenience aliases or
  helper exports without an explicit contract review.
- Revisit the telemetry decision only if quality sampling needs durable review
  history or gates instead of one-shot bounded reporting.
- Keep algorithm-family expansion isolated to
  `docs/plans/active/packages/static_hash_algorithm_portfolio_research.md`
  unless a dedicated accepted-candidate implementation plan is opened.
