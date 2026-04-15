# `static_hash` algorithm portfolio research plan

Scope: determine which missing algorithm families should be added to
`static_hash`, which should be rejected, and which require a separate surface.

## Goal

Turn the portfolio sketch into a concrete implementation decision set with
bounded prototypes, validation commands, and explicit add/reject outcomes.

## Inputs

- `docs/sketches/static_hash_algorithm_portfolio_additions_2026-03-17.md`
- `docs/sketches/static_hash_dod_gpu_report_2026-03-17.md`
- `docs/sketches/static_ecs_package_sketch_2026-04-02.md`
- `docs/plans/completed/static_hash_followup_closed_2026-04-01.md`
- current benchmark harnesses under `packages/static_hash/benchmarks/`

## Scope guardrails

- Keep root-surface cleanup, telemetry posture, and other package-boundary debt
  on the closed follow-up record unless this research accepts a candidate that
  needs a new implementation plan; this research plan stays limited to
  algorithm-portfolio decisions.

## Ordered SMART tasks

1. `Requirement freeze`
   Write one requirement note that defines portability, determinism, stability,
   target-feature policy, persistence policy, and API-shape expectations for a
   new hash algorithm.
   Current smallest bounded slice: write the add/reject gate directly into this
   plan from the current sketch inputs before ranking any candidate family,
   under `zig build docs-lint`.
   Done when Phase 0 has a written add/reject gate that later candidate passes
   can score against under `zig build docs-lint`.
2. `Benchmark scenario matrix`
   Extend the benchmark plan with the exact candidate-selection scenarios:
   many-short-key, large-buffer, seeded table-hash, and
   architecture-sensitive runs.
   Current smallest bounded slice: name the first scenario matrix rows and the
   existing benchmark comparison targets before proposing a new executable,
   under `zig build docs-lint`.
   ECS / DoD follow-on:
   - include short fixed-schema signature keys and repeated archetype or table
     key rows alongside generic many-short-key cases;
   - include repeated homogeneous-record hashing rows so the package can tell
     whether a generic batch primitive is justified in `static_hash` or should
     remain an adapter concern in `static_ecs`.
   Done when each scenario has a workload name, comparison target, and
   `zig build bench` validation path.
3. `Portable candidate ranking`
   Evaluate and rank portable candidates, starting with the `rapidhash` class,
   against the requirement note and benchmark matrix.
   Done when each portable family is marked `prototype`, `defer`, or `reject`
   with written rationale.
4. `Keyed hardware-aware ranking`
   Evaluate `aHash` / `gxhash`-class candidates for in-memory keyed workloads
   and decide whether the correct surface belongs in `static_hash` or in a
   separate opt-in boundary.
   ECS / DoD follow-on: keep ECS-specific schema adapters, archetype-key
   wrappers, and world-local table hashing out of `static_hash` unless a
   reusable generic batch primitive proves broadly valuable outside ECS.
   Done when each candidate family has a package-boundary outcome and a
   deterministic-seed policy for tests and replay.
5. `Crypto and accelerator boundary decision`
   Evaluate `BLAKE3`, Merkle or tree-hash follow-on needs, and any GPU-oriented
   hashing direction.
   Done when each family is marked `belongs here`, `belongs in sibling
   package`, or `reject for now`, with rationale.
6. `Decision ledger`
   Record add / defer / reject outcomes for every candidate family and open
   follow-on implementation plans only for accepted additions.
   Done when Phase 4 ends with zero accepted candidates lacking a dedicated
   follow-on plan.

## Phases

### Phase 0 - requirement freeze

Exit condition:

- one-page decision note on what a new algorithm must guarantee to join the
  package;
- explicit rule for when a surface is "portable/stable" versus
  "in-memory/target-feature specific".

Validation:

- `zig build docs-lint`

### Phase 1 - portable candidate pass

Tasks:

- benchmark and evaluate a `rapidhash`-class candidate against `wyhash` and
  `xxhash3`;
- check vector availability, stability policy, and seeded semantics;
- decide whether it is worth a prototype.

Exit condition:

- accept, defer, or reject the candidate family with written rationale.

Validation:

- `zig build bench`
- `zig build docs-lint`

### Phase 2 - keyed in-memory candidate pass

Tasks:

- evaluate `aHash`/`gxhash`-class designs for map-heavy, DoS-aware workloads;
- decide whether the correct surface is inside `static_hash` or as a separate
  opt-in module;
- define deterministic-seed behavior for tests and replay.

Exit condition:

- explicit surface split decision and prototype recommendation.

Validation:

- `zig build bench`
- `zig build docs-lint`

### Phase 3 - crypto / tree / accelerator pass

Tasks:

- evaluate `BLAKE3` as a crypto/content-addressing addition;
- decide whether tree-hash/GPU-oriented work belongs here or in a sibling
  package;
- identify any Merkle-tree or batch-hash API that should be designed first.

Exit condition:

- explicit package-boundary decision for crypto and accelerator hashing.

Validation:

- `zig build bench`
- `zig build docs-lint`

### Phase 4 - implementation follow-through

Tasks:

- open one implementation plan per accepted candidate family;
- keep rejected candidates documented so the question does not reopen without
  new evidence.

Exit condition:

- follow-on plans exist only for accepted additions.

Validation:

- `zig build docs-lint`

## Current recommendation

- Start with portable candidates first.
- Do not add an AES-oriented or GPU-oriented surface until the package boundary
  is explicitly split between deterministic portable hashing and
  in-memory/accelerator hashing.
- Keep ECS-specific table-key and archetype-signature adapters in `static_ecs`
  unless benchmark evidence justifies a generic batch-hashing primitive in
  `static_hash` itself.
