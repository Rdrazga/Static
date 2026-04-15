# `static_testing` artifact formats and storage completion

Feature source:
`docs/sketches/archive/static_testing_artifact_format_strategy_2026-03-18.md`

## Goal

Close `static_testing` around one shared artifact policy:
bounded documents use `ZON`, append-only streams use shared binary framing, and
workflow layers decide which artifacts to emit.

## Completed outcome

- `packages/static_testing/src/artifact/document.zig` is the shared bounded
  document helper and `packages/static_testing/src/artifact/record_log.zig` is
  the shared append-only binary record-log helper.
- Benchmark baselines now use canonical `baseline.zon`.
- Benchmark histories, retained exploration records, retained swarm campaign
  records, and retained trace streams now use shared binary record framing.
- Failure bundles use canonical `manifest.zon`, `trace.zon`,
  `violations.zon`, and optional `trace_events.binlog`.
- Model retention uses `actions.bin` plus optional typed `actions.zon`.
- Artifact emission remains caller-selected through the higher-level workflow
  surfaces in `failure_bundle`, `model`, `system`, `swarm_runner`, and
  `bench.workflow`.

## Final boundary decision

- Keep compatibility only where it is already intentionally retained:
  baseline v2-v3 and benchmark history v1-v3.
- Keep unsupported newer versions fail-closed on retained bundle, replay,
  trace, exploration, and swarm record surfaces.
- Keep format conversion/export helpers out of scope.

## Validation

- `zig build test`

