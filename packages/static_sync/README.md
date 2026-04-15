# `static_sync`

Synchronization, cancellation, and bounded coordination primitives for the
`static` workspace.

## Current status

- The root workspace build is the supported entry point; package-local
  `zig build` is not the supported validation path.
- The 2026-04-01 closure remains the broad baseline record, while the
  2026-04-11 hardening closure and the focused runtime/benchmark follow-up now
  live under `docs/plans/completed/`:
  `static_sync_benchmark_and_testing_hardening_closed_2026-04-11.md` and
  `static_sync_runtime_and_benchmark_followup_closed_2026-04-11.md`.
- Package coverage includes model, replay, fuzz, simulation, and host-thread
  smoke surfaces for `barrier`, `seqlock`, `cancel`, `event`, `condvar`,
  `semaphore`, `wait_queue`, and `once`.
- Package-owned `testing.model` coverage now includes barrier generation,
  seqlock token lifecycle, cancel registration lifecycle, semaphore permit
  progression, and a capability-gated wait_queue sequential contract surface.
- Package-owned simulation and temporal coverage now includes wait_queue wake
  protocols, condvar broadcast and timeout protocols, event set-reset handoff,
  semaphore post-before-timeout ordering, and cancel reset ordering.
- Fault-injection coverage now includes delayed-wake timeout/retry runtimes for
  event, semaphore, and wait_queue plus cancel-reset runtime reuse under
  partial wake progress.
- Canonical benchmarks cover the uncontended fast path and bounded contention
  handoff paths, with direct named root steps at
  `zig build static_sync_fast_paths` and
  `zig build static_sync_contention`, plus lifecycle owners at
  `zig build static_sync_cancel_lifecycle`,
  `zig build static_sync_barrier_phase`, and
  `zig build static_sync_barrier_wait`, and
  `zig build static_sync_once_and_grant`, plus attribution references at
  `zig build static_sync_benchmark_references`, seqlock and timeout-path owners at
  `zig build static_sync_seqlock` and
  `zig build static_sync_timeout_path`, plus a condvar owner at
  `zig build static_sync_condvar` when the workspace is built with
  `-Denable_os_backends=true`.
- Host-thread smoke remains smoke-only rather than a timing surface: each case
  now uses a bounded ready-to-wait handshake and must always unblock and join
  the worker on every exit path.
- Blocking contention benchmarks now use bounded watchdogs plus timed wait
  slices so host regressions fail with a stage-labelled timeout instead of
  hanging the review surface indefinitely, and the recorded benchmark
  environment tags now distinguish parking-backed waits from polling-fallback
  runs. Polling-fallback waits now use phased spin-plus-yield backoff rather
  than indefinite pure spin hints, and the watchdog now throttles clock
  sampling instead of checking time on every loop iteration.
- Single-permit semaphore wakeups now signal one parked waiter instead of
  broadcasting to all waiters, while parking-backed `Event.set()` now skips
  redundant wake work when already signaled without changing the default
  non-parking fast path.
- Replay and retained-failure coverage is now primitive-facing rather than
  harness-synthetic: the fuzz campaigns replay persisted artifacts on failure,
  and the retained bundle proof now exercises reduced misuse traces for
  cancellation registration-after-cancel plus zero-timeout pending waits.

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
- `zig build static_sync_fast_paths`
- `zig build static_sync_contention`
- `zig build static_sync_cancel_lifecycle`
- `zig build static_sync_barrier_phase`
- `zig build static_sync_barrier_wait`
- `zig build static_sync_once_and_grant`
- `zig build static_sync_benchmark_references`
- `zig build static_sync_seqlock`
- `zig build static_sync_timeout_path`
- `zig build static_sync_condvar`
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
  `tests/integration/model_seqlock_token_sequences.zig`,
  `tests/integration/model_cancel_lifecycle_sequences.zig`, and
  `tests/integration/model_event_or_semaphore_sequences.zig` cover the main
  package-owned model proofs, while
  `tests/integration/model_wait_queue_sequences.zig` adds a capability-gated
  wait_queue contract model when OS backends are enabled.
- `tests/integration/replay_fuzz_sync_primitives.zig`,
  `tests/integration/fuzz_persistence_sync.zig`, and
  `tests/integration/misuse_paths.zig` cover replay, fuzz, and misuse-path
  retention, including replay validation of persisted artifacts and canonical
  failure-bundle roundtrips for primitive-facing retained misuse cases.
- `tests/integration/sim_wait_protocols.zig`,
  `tests/integration/sim_event_protocols.zig`,
  `tests/integration/sim_semaphore_or_cancel_protocols.zig`, and
  `tests/integration/host_wait_smoke.zig` cover simulator, temporal, and
  host-thread wait/wake behavior.
- `tests/integration/timeout_fault_runtime.zig` and
  `tests/integration/cancel_reset_fault_runtime.zig` cover bounded hostile-host
  fault injection for delayed start, delayed wake, repeated timeout, cancel,
  reset, and retry sequences.
- `examples/` contains bounded usage examples for `barrier`, `cancel`,
  `event`, `grant`, `semaphore`, `wait_queue`, and `once`.
- `benchmarks/fast_paths.zig` and `benchmarks/contention_baselines.zig`
  define the existing canonical benchmark entry points available through
  `zig build static_sync_fast_paths` and
  `zig build static_sync_contention`.
- `benchmarks/cancel_lifecycle_baselines.zig`,
  `benchmarks/barrier_phase_baselines.zig`,
  `benchmarks/barrier_wait_baselines.zig`, and
  `benchmarks/once_and_grant_baselines.zig` extend the direct review surface
  for cancellation, barrier progression, and capability lifecycle work, with
  the cancel and once/grant owners now exposing isolated attribution cases
  alongside the earlier combined lifecycle cases and the barrier surface now
  separating phase-close microbenchmarks from real `arriveAndWait()` handoff work.
- `benchmarks/seqlock_baselines.zig`,
  `benchmarks/timeout_path_baselines.zig`, and
  `benchmarks/condvar_baselines.zig`, plus
  `benchmarks/benchmark_references.zig`, extend the review surface for
  seqlock read/write progression, zero-budget timeout contracts, condvar
  signal versus broadcast handoff behavior, finer seqlock read-versus-writer
  attribution, and cross-owner mutex and timeout-budget attribution references,
  with condvar remaining capability-gated behind OS-backend builds and the
  benchmark source itself now restored after the 2026-04-11 metadata-fix
  follow-up.

## Benchmark artifacts

- Benchmark outputs live under `.zig-cache/static_sync/benchmarks/<name>/`.
- Canonical review artifacts stay on shared `baseline.zon` plus
  `history.binlog`.
- Re-record baselines when the workload, primitive mix, or measured contract
  changes materially.
