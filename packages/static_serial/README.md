# `static_serial`

Bounded serialization helpers for readers, writers, varints, checksums, and
frame views.

## Current status

- The root workspace build is the supported entry point; package-local
  `zig build` is not the supported validation path.
- `static_serial` is the downstream reference for transport-agnostic framing
  review on shared `static_testing` surfaces.
- Package coverage includes malformed-frame replay, checksum mismatch handling,
  truncated decode cases, and incremental framing/model behavior.
- Canonical benchmarks cover checksum-framed payload roundtrips and mixed
  endian structured message roundtrips.

## Main surfaces

- `src/root.zig` exports the package API.
- `src/serial/errors.zig` owns serialization error vocabulary.
- `src/serial/reader.zig` and `src/serial/writer.zig` own bounded decode and
  encode helpers.
- `src/serial/varint.zig` and `src/serial/zigzag.zig` own framed integer
  encodings.
- `src/serial/checksum.zig` owns checksum framing helpers.
- `src/serial/view.zig` owns borrowed frame views and decode-oriented access.
- `tests/integration/root.zig` wires the deterministic package regression
  surface.
- `benchmarks/` holds the canonical shared-workflow benchmark entry points.
- `examples/` holds usage samples for roundtrips, frame parsing, and mixed
  endian message handling.

## Validation

- `zig build check`
- `zig build test`
- `zig build examples`
- `zig build bench`
- `zig build docs-lint`

## Key paths

- `tests/integration/replay_fuzz_malformed_frames.zig` covers malformed frame
  replay and fuzz cases.
- `tests/integration/model_incremental_frames.zig` covers incremental framing
  and buffer-drain behavior.
- `tests/integration/frame_support.zig` holds shared integration helpers.
- `benchmarks/checksum_framed_payload_roundtrip.zig` is the checksum-framed
  payload baseline benchmark.
- `benchmarks/mixed_endian_message_roundtrip.zig` is the structured mixed
  endian message baseline benchmark.
- `benchmarks/support.zig` holds shared benchmark artifact helpers.
- `examples/parse_length_prefixed_frame.zig`,
  `examples/cursor_endian_varint_message.zig`,
  `examples/checksum_frame.zig`,
  `examples/reader_writer_endian.zig`, and
  `examples/varint_roundtrip.zig` show the supported usage patterns.

## Benchmark artifacts

- Benchmark outputs live under `.zig-cache/static_serial/benchmarks/<name>/`.
- Canonical review artifacts stay on shared `baseline.zon` plus
  `history.binlog`.
- Re-record baselines when framing shape, payload size, or decode semantics
  change materially.
