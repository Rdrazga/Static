# `static_net_native`

OS-native socket-address adapters for the `static` workspace.

## Current status

- The root workspace build is the supported entry point; package-local `zig
  build` is not the validation contract.
- `static_net_native` owns the native translation layer between `static_net`
  endpoint values and platform socket-address layouts.
- The package currently covers common endpoint conversion helpers, POSIX,
  Linux, and Windows adapters, deterministic integration coverage, a bounded
  loopback system test, replayable sockaddr fuzz coverage, a roundtrip example,
  and a canonical sockaddr roundtrip benchmark.

## Main surfaces

- `src/root.zig` exports the package API and re-exports `Endpoint`.
- `src/net_native/common.zig` owns shared endpoint conversion helpers.
- `src/net_native/windows.zig` owns Windows socket-address layouts and local
  or peer endpoint queries.
- `src/net_native/linux.zig` owns Linux socket-address layouts and local
  endpoint queries.
- `src/net_native/posix.zig` owns POSIX socket-address layouts and local or
  peer endpoint queries.
- `tests/integration/root.zig` wires the package-level deterministic
  integration suite.
- `tests/integration/system_loopback_endpoints.zig` proves loopback local and
  peer endpoint agreement under `testing.system`.
- `tests/integration/replay_fuzz_sockaddr_storage.zig` covers replayable
  sockaddr storage invariants and retained invalid-family bundles.
- `examples/endpoint_sockaddr_roundtrip.zig` shows the platform-specific
  roundtrip path.
- `benchmarks/endpoint_sockaddr_roundtrip.zig` owns the canonical roundtrip
  benchmark workload.

## Validation

- `zig build check`
- `zig build test`
- `zig build examples`
- `zig build bench`
- `zig build docs-lint`

## Key paths

- `src/root.zig`
- `src/net_native/common.zig`
- `src/net_native/windows.zig`
- `src/net_native/linux.zig`
- `src/net_native/posix.zig`
- `tests/integration/root.zig`
- `tests/integration/system_loopback_endpoints.zig`
- `tests/integration/replay_fuzz_sockaddr_storage.zig`
- `examples/endpoint_sockaddr_roundtrip.zig`
- `benchmarks/endpoint_sockaddr_roundtrip.zig`
- `benchmarks/support.zig`

## Benchmark artifacts

- Benchmark outputs live under
  `.zig-cache/static_net_native/benchmarks/<name>/`.
- Canonical review artifacts stay on shared `baseline.zon` plus
  `history.binlog`.
- Re-record baselines when the sockaddr roundtrip workload or its platform
  mix changes materially.
