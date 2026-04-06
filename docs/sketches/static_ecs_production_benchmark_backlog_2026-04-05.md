# `static_ecs` production benchmark backlog

Scope: record the remaining benchmark stories that would make `static_ecs`
more observable internally and more comparable against production-grade ECS
implementations.

## Current admitted benchmark owners

- `query_iteration_baselines`: dense versus fragmented query iteration.
- `structural_churn_baselines`: initial versus live-entity scalar and bundle
  mutation.
- `command_buffer_staged_apply_baselines`: spawn-only, insert-only, and mixed
  stage-plus-apply throughput.
- `micro_hotpaths_baselines`: primitive hot-path microbenchmarks.
- `query_scale_baselines`: entity-count and archetype-count query scaling.
- `frame_pass_baselines`: frame-like sequential ECS pass mixes.

## Valuable next benchmark groups

### Entity lifecycle throughput

- Empty `spawn()` throughput versus `spawnBundle()` throughput at bundle widths
  `1`, `2`, `4`, `8`, and `16`.
- `despawn()` throughput for dense worlds, fragmented worlds, and worlds with
  many retained empty chunks.
- Entity-id reuse pressure after repeated spawn/despawn waves.
- Spawn throughput when every insert lands in one hot archetype versus when
  archetype creation churn is required.
- Spawn throughput when chunk growth is hot-cache versus after cold-start world
  construction.

### Structural mutation cost

- `insert()` and `remove()` width sweeps across `1`, `2`, `4`, `8`, and `16`
  component changes on already-live entities.
- `insertBundle()` and `removeBundle()` width sweeps across the same shapes.
- Structural churn on one hot archetype versus many cold archetypes.
- Repeated tag toggles versus repeated data-component toggles.
- Mutation cost with one large component column mixed into otherwise small
  bundles.
- Mutation cost when source and destination archetypes both already exist
  versus when one side must be created on the fly.
- Mutation cost under near-full chunks versus half-full chunks.

### Query behavior and scaling

- Dense required-read scans across `1k`, `4k`, `16k`, `64k`, and `256k`
  entities.
- Sparse-match query startup where many archetypes are scanned but few match.
- Zero-match query startup to isolate matcher and iterator setup overhead.
- Optional-heavy query scans versus required-only scans over the same world.
- Exclude-heavy tag filtering over dense and fragmented worlds.
- Query throughput as matching archetype count increases from `1` to `64`.
- Query throughput as component-universe width grows while the query itself
  stays small.
- Chunk-batch size sensitivity if the view surface later exposes alternative
  batching shapes.

### Frame-like system mixes

- Sequential `1`, `2`, `4`, `8`, and `16` pass runs over the same dense world.
- Pass mixes that separate read-only systems from write-heavy systems.
- Frame runs where each pass hits the same entities versus disjoint filtered
  subsets.
- Frame runs where earlier passes introduce structural mutation and later
  passes query the new archetypes.
- Status-effect or tag-heavy frame runs with many excludes and optionals.
- Broad-phase style frame runs with one movement pass plus one culling or
  visibility pass over a large fragmented world.
- Editor-like runs that mix structural edits, targeted queries, and despawns
  in one frame.

### Command-buffer behavior

- Stage-only throughput separate from apply-only throughput across command mix
  ratios.
- Command-buffer apply under payload-byte pressure with narrow versus wide
  bundles.
- Many tiny commands versus fewer wide bundle commands at equal total payload
  bytes.
- Apply behavior when most commands target the same archetype versus many
  archetypes.
- Apply behavior with large remove-heavy waves to expose empty-chunk retention
  effects.
- Repeated frame cadence benchmarks: stage commands, apply, clear, and repeat.

### Memory and cache shape

- Column-width sweeps with tiny POD components, medium components, and large
  cache-line-crossing components.
- One very large cold component mixed with several hot small components.
- World shape sweeps over `chunk_rows_max` to capture fill-rate and locality
  tradeoffs.
- Empty-chunk retention sweeps over `empty_chunk_retained_max`.
- Command-buffer payload-bound sweeps over `command_buffer_payload_bytes_max`.
- Archetype-key and sparse-metadata scaling as archetype count grows.

### Latency and distribution observability

- Record `p95` and `p99` alongside mean and median for structural workloads.
- Cold-start versus warmed-cache comparisons for query and mutation paths.
- Long-run drift checks over repeated benchmark rounds to catch allocator or
  branch-predictor warmup effects.
- Outlier-focused benchmarks that intentionally include archetype creation,
  first-chunk allocation, and first-command-buffer growth events.

### Cross-device and portability matrix

- Same benchmark owners on desktop x86_64, laptop x86_64, ARM64 desktop, and
  mobile-class ARM cores when available.
- Debug, `ReleaseSafe`, and `ReleaseFast` compile-mode comparisons for selected
  hot paths.
- Small-stack environments to expose large temporary regressions if they
  return.
- Different allocator backings if the workspace later supports benchmarkable
  allocator selection.

### Cross-ECS comparability stories

- A fixed dense transform/velocity update frame shared with other ECS
  implementations.
- A fragmented status-effect frame with optionals and excludes shared with
  other ECS implementations.
- A structural churn wave with spawn, insert, remove, and despawn shared with
  other ECS implementations.
- A deferred-mutation frame that compares immediate APIs against command-buffer
  or staged mutation APIs.
- A benchmark ruleset that fixes component sizes, entity counts, archetype
  counts, warmup, and reporting so results stay comparable.

## Reporting and workflow requirements for future owners

- Keep every future owner on `static_testing.bench.workflow`.
- Keep deterministic semantic preflight ahead of timing.
- Record explicit environment notes and compatibility tags.
- Prefer owner-local baseline files plus bounded history sidecars over ad hoc
  artifacts.
- Keep cases small enough to remain review-friendly unless the owner is
  intentionally a long-running comparison suite.
- If a benchmark models systems, keep it explicit whether it measures
  sequential ECS passes or a future scheduler-owned API.
