# `static_profile`

Profiling, tracing, and instrumentation helpers for bounded static systems.

## Current status

- The root workspace build is the supported entry point; package-local
  `zig build` is not supported.
- `static_profile` currently owns trace capture, counters, zones, hooks, and
  capability checks.
- Direct integration coverage now proves mixed-event export shape, hook
  ordering, repeated same-name counters, and bounded counter-buffer lifecycle
  behavior.
- The package follow-up is closed; retained export artifacts and benchmark
  work are trigger-only until a concrete consumer needs them.

## Main surfaces

- `src/root.zig` exports the package API.
- `src/profile/trace.zig` owns bounded trace capture and Chrome trace export
  for zone and counter events.
- `src/profile/counter.zig` owns counter event encoding and JSON export.
- `src/profile/hooks.zig` owns zero-dependency counter emission helpers for
  subsystems that should not import `static_profile`.
- `src/profile/zone.zig` owns the begin/end token type used to pair zone
  events.
- `src/profile/caps.zig` owns the build-option mirror used for capability
  gating.

## Validation

- `zig build test`
- `zig build examples`
- `zig build docs-lint`

## Key paths

- `tests/integration/root.zig` wires the package-level regression suite.
- `tests/integration/export_shape_correctness.zig` checks export ordering and
  trace shape.
- `tests/integration/hook_ordering_counter_lifecycle.zig` covers hook ordering
  and counter lifecycle behavior.
- `examples/chrome_trace_basic.zig` shows trace export.
- `examples/counter_basic.zig` shows counter emission and export.
- `examples/hooks_emit_basic.zig` shows zero-dependency hook usage.
- `docs/plans/completed/static_profile_followup_closed_2026-03-31.md` records
  the current closure posture and reopen triggers.

## Benchmark posture

- No benchmark workflow is currently admitted for `static_profile`.
- If instrumentation overhead becomes a real review target, keep the artifact
  contract explicit and record the decision in a plan before adding baselines.
