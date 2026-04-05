# `static_net`

OS-free networking value types and bounded frame codecs for the `static`
workspace.

## Current status

- The root workspace build is the supported entry point; package-local `zig
  build` is not supported.
- `static_net` focuses on deterministic parse, format, encode, and decode
  contracts rather than sockets or transport ownership.
- Package coverage includes direct examples, deterministic integration tests,
  malformed-frame replay/fuzz coverage, and shared benchmark review workflows.

## Main surfaces

- `src/root.zig` exports the package API.
- `src/net/address.zig` owns IPv4 and IPv6 value types plus strict parse and
  format behavior.
- `src/net/endpoint.zig` owns `address + port` literal handling.
- `src/net/frame_config.zig` owns frame bounds, checksum mode, and protocol
  limits.
- `src/net/frame_encode.zig` and `src/net/frame_decode.zig` own the bounded
  frame codec paths.
- `tests/integration/root.zig` wires the deterministic integration suite.
- `benchmarks/` owns the canonical encode/decode and checksum roundtrip
  workloads.

## Validation

- `zig build check`
- `zig build test`
- `zig build examples`
- `zig build bench`
- `zig build docs-lint`

## Key paths

- `tests/integration/frame_support.zig` holds the shared bounded frame-test
  helpers.
- `tests/integration/model_incremental_decoder.zig` covers incremental decoder
  state-machine behavior.
- `tests/integration/replay_fuzz_frames.zig` covers retained malformed-frame
  replay/fuzz cases and failure-bundle metadata.
- `examples/address_parse_format_basic.zig` demonstrates address literals.
- `examples/frame_codec_incremental_basic.zig` demonstrates incremental frame
  decode usage.
- `examples/frame_checksum_roundtrip_basic.zig` demonstrates checksum-enabled
  roundtrips.
- `benchmarks/support.zig` writes benchmark artifacts under
  `.zig-cache/static_net/benchmarks/<name>/` using shared `baseline.zon` plus
  `history.binlog`.

## Benchmark artifacts

- Canonical benchmark output stays on `baseline.zon` plus `history.binlog`.
- Re-record baselines when the frame shape, payload bounds, or checksum
  behavior changes materially.
