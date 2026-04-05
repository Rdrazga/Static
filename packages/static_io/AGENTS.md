# `static_io` package guide
Start here when you need to review, validate, or extend `static_io`.

## Source of truth

- `README.md` for the package entry point and commands.
- `src/root.zig` for the exported surface.
- `tests/integration/root.zig` for the package-level deterministic regression
  surface.
- `benchmarks/` for canonical benchmark entry points and artifact names.
- `docs/plans/completed/static_io_followup_closed_2026-03-23.md` for the
  current closure posture.
- `docs/plans/completed/static_io_review_2026-03-20.md` for the review record.
- `docs/plans/active/workspace_operations.md` for workspace priority and
  sequencing.
- `docs/architecture.md` for package boundaries and dependency direction.

## Supported commands

- `zig build check`
- `zig build check -Denable_os_backends=true`
- `zig build test`
- `zig build test -Denable_os_backends=true`
- `zig build bench`
- `zig build examples`
- `zig build docs-lint`

## Working agreements

- Use the root `build.zig` as the supported validation surface.
- Keep `static_io` work tied to finishing and proving `static_testing` first;
  package work here should harden shared process, system, simulation, fuzz, and
  benchmark surfaces rather than drifting into unrelated feature work.
- Prefer shared `static_testing` workflows over package-local harness code:
  `testing.system`, `testing.process_driver`, `testing.sim`,
  `testing.fuzz_runner`, `testing.temporal`, `testing.failure_bundle`, and
  `bench.workflow`.
- Keep package-local helpers limited to I/O-runtime-specific setup or tracing.
  Generic harness patterns belong in `static_testing`.
- Keep the runtime boundary narrow: `static_io` owns runtime, buffer,
  completion, and backend contracts, not higher-level protocol or application
  behavior.
- Keep OS-specific backend coverage deterministic and bounded. Use
  `-Denable_os_backends=true` when validating the real backend paths.
- Keep benchmark artifacts on shared `baseline.zon` plus `history.binlog`; do
  not add package-local artifact formats.

## Package map

- `src/io/buffer_pool.zig`: bounded reusable buffers and exhaustion tracking.
- `src/io/runtime.zig`: runtime submission, polling, wait, timeout, cancel, and
  handle lifecycle.
- `src/io/fake_backend.zig`: deterministic fake backend for bounded tests and
  benchmarks.
- `src/io/threaded_backend.zig`: threaded backend adapter.
- `src/io/platform/`: host-specific backend implementations and selection.
- `tests/integration/`: package-level deterministic system, process, sim, fuzz,
  and OS-backend coverage.
- `tests/support/`: package-owned test executables or driver helpers.
- `benchmarks/`: canonical hot-path review workloads.
- `examples/`: bounded usage examples only.

## Change checklist

- Update `README.md`, `AGENTS.md`, and the completed review or closure record
  when package behavior or workflow changes.
- Extend `tests/integration/root.zig` when you add new first-class package
  integration coverage.
- Re-record benchmark baselines when workload sizes or semantics change.
- Update root `README.md`, root `AGENTS.md`, and `docs/architecture.md` when
  package guidance or repository navigation changes.
