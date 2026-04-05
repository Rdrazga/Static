# `static_net` package guide
Start here when you need to review, validate, or extend `static_net`.

## Source of truth

- `README.md` for the package entry point and commands.
- `src/root.zig` for the exported surface.
- `tests/integration/root.zig` for the package-level deterministic regression
  surface.
- `benchmarks/` for canonical benchmark entry points and artifact names.
- `docs/plans/active/workspace_operations.md` for workspace priority and
  sequencing.
- `docs/architecture.md` for package boundaries and dependency direction.

## Supported commands

- `zig build check`
- `zig build test`
- `zig build examples`
- `zig build bench`
- `zig build docs-lint`

## Working agreements

- Use the root `build.zig` as the supported validation surface.
- Keep `static_net` focused on OS-free value types, parse/format contracts,
  and bounded frame codecs.
- Prefer shared `static_testing` workflows for malformed-frame replay/fuzz,
  incremental decoder modeling, and benchmark review.
- Keep package-local helpers limited to frame-specific setup or test support.
- Keep benchmark artifacts on shared `baseline.zon` plus `history.binlog`; do
  not add package-local artifact formats.

## Package map

- `src/root.zig`: package exports for addresses, endpoints, frame config, and
  decoder/encoder entry points.
- `src/net/address.zig`: IPv4 and IPv6 value types plus parse/format logic.
- `src/net/endpoint.zig`: `address + port` literals and formatting.
- `src/net/frame_config.zig`: bounded frame configuration, limits, and
  checksum mode.
- `src/net/frame_encode.zig`: frame encoding helpers.
- `src/net/frame_decode.zig`: frame decoding state machine and decode steps.
- `src/net/errors.zig`: parse, format, encode, and decode error vocabulary.
- `tests/integration/`: deterministic model and replay/fuzz coverage.
- `benchmarks/`: canonical encode/decode and checksum roundtrip workloads.
- `examples/`: bounded usage examples for address parsing and frame codecs.

## Change checklist

- Update `README.md`, `AGENTS.md`, and the relevant plan or reference doc when
  package behavior or workflow changes.
- Extend `tests/integration/root.zig` when you add new first-class package
  integration coverage.
- Re-record benchmark baselines when workload sizes or semantics change.
- Update root `README.md`, root `AGENTS.md`, and `docs/architecture.md` when
  package guidance or repository navigation changes.
