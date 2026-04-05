# `static_sync`

Synchronization, cancellation, and bounded coordination primitives for the
`static` workspace.

## Current status

- The root workspace build is the supported entry point; package-local
  `zig build` is not the supported validation path.
- The package follow-up is closed as of 2026-04-01. The exported-surface proof
  map is complete and the package now reopens only for a concrete new bug class
  or boundary mismatch.
- Package coverage includes model, replay, fuzz, simulation, and host-thread
  smoke surfaces for `barrier`, `seqlock`, `cancel`, `event`, `condvar`,
  `semaphore`, `wait_queue`, and `once`.
- Canonical benchmarks cover the uncontended fast path and bounded contention
  handoff paths.

## Main surfaces

- `src/root.zig` exports the package API and primitive namespace map.
- `src/sync/backoff.zig`, `src/sync/padded_atomic.zig`, and
  `src/sync/seqlock.zig` own the sequencing and contention-sensitive
  primitives.
- `src/sync/once.zig`, `src/sync/cancel.zig`, `src/sync/event.zig`,
  `src/sync/semaphore.zig`, `src/sync/condvar.zig`, `src/sync/wait_queue.zig`,
  `src/sync/barrier.zig`, and `src/sync/grant.zig` own the coordination and
  capability surfaces.
- `src/sync/caps.zig` keeps capability declarations inline-test-only.
- `tests/integration/root.zig` wires the package-level deterministic
  regression suite.
- `benchmarks/` holds the canonical fast-path and contention review workloads.
- `examples/` holds bounded usage examples; examples are not the canonical
  regression surface.

## Validation

- `zig build check`
- `zig build test`
- `zig build harness`
- `zig build examples`
- `zig build bench`
- `zig build docs-lint`

Command intent:

- Keep `zig build test` as the primary pass/fail surface for regression and
  retention coverage.
- Keep `zig build harness` as the success-only smoke surface for the examples
  that are meant to stay non-failing.
- Treat `zig build bench` as review-only unless a benchmark workflow
  explicitly opts into gating.

## Key paths

- `tests/integration/model_barrier_phase_sequences.zig` and
  `tests/integration/model_seqlock_token_sequences.zig` cover the package-owned
  model proofs.
- `tests/integration/replay_fuzz_sync_primitives.zig`,
  `tests/integration/fuzz_persistence_sync.zig`, and
  `tests/integration/misuse_paths.zig` cover replay, fuzz, and misuse-path
  retention.
- `tests/integration/sim_wait_protocols.zig` and
  `tests/integration/host_wait_smoke.zig` cover simulator and host-thread
  wait/wake behavior.
- `examples/` contains bounded usage examples for `barrier`, `cancel`,
  `event`, `grant`, `semaphore`, `wait_queue`, and `once`.
- `benchmarks/fast_paths.zig` and `benchmarks/contention_baselines.zig`
  define the canonical benchmark entry points.

## Benchmark artifacts

- Benchmark outputs live under `.zig-cache/static_sync/benchmarks/<name>/`.
- Canonical review artifacts stay on shared `baseline.zon` plus
  `history.binlog`.
- Re-record baselines when the workload, primitive mix, or measured contract
  changes materially.
