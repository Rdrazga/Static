# `static_net_native` package guide
Start here when you need to review, validate, or extend `static_net_native`.

## Source of truth

- `README.md` for the package entry point and commands.
- `src/root.zig` for the exported surface.
- `tests/integration/root.zig` for the package-level deterministic regression
  surface.
- `benchmarks/` for the canonical sockaddr roundtrip review workload and
  artifact names.
- `docs/architecture.md` for package boundaries and dependency direction.
- `docs/plans/active/workspace_operations.md` for workspace priority and
  sequencing.

## Supported commands

- `zig build check`
- `zig build test`
- `zig build examples`
- `zig build bench`
- `zig build docs-lint`

Command intent:

- Use the root `build.zig` as the supported validation surface.
- Keep `zig build test` focused on deterministic package integration and
  replay coverage.
- Keep `zig build examples` as the bounded usage/demo surface.
- Keep `zig build bench` review-only unless a benchmark workflow explicitly
  opts into gating.

## Working agreements

- Keep `static_net_native` as the OS-native adapter layer only; endpoint value
  semantics stay in `static_net`.
- Keep syscall types and socket-address layouts package-local.
- Prefer shared `static_testing` workflows for replay, fuzz, and system
  coverage instead of ad hoc harnesses.
- Keep OS-specific behavior explicit and bounded across `windows`, `linux`,
  and `posix`.
- Keep benchmark artifacts on the shared `baseline.zon` plus `history.binlog`
  convention under `.zig-cache/static_net_native/benchmarks/`.

## Package map

- `src/root.zig`: package export surface and `Endpoint` re-export.
- `src/net_native/common.zig`: endpoint conversion helpers shared by all
  native adapters.
- `src/net_native/windows.zig`: Windows socket-address adapters and local or
  peer endpoint queries.
- `src/net_native/linux.zig`: Linux socket-address adapters and local endpoint
  queries.
- `src/net_native/posix.zig`: POSIX socket-address adapters and local or peer
  endpoint queries.
- `tests/integration/`: replay/fuzz and `testing.system` coverage for native
  sockaddr handling.
- `examples/`: bounded roundtrip example usage.
- `benchmarks/`: canonical sockaddr roundtrip benchmark entry point and
  shared reporting helpers.

## Change checklist

- Update `README.md`, `AGENTS.md`, and the relevant plan or architecture note
  when package behavior or workflow changes.
- Extend `tests/integration/root.zig` when you add new first-class package
  integration coverage.
- Update `benchmarks/` and the shared benchmark artifact contract when the
  roundtrip workload changes materially.
- Update root `README.md`, root `AGENTS.md`, and `docs/architecture.md` when
  package guidance or repository navigation changes.
