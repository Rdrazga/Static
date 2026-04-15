# `static_ecs` bundle portability and command-buffer follow-up

Scope: close the validated encoded-bundle portability, command-buffer staging
rollback, stack-shape hardening, and direct encoded-bundle contract reopen for
the world-local typed ECS package.

Status: follow-up closed on 2026-04-05. The validated bug classes are fixed,
the direct encoded-bundle boundary is now explicit, and the package owns direct
deterministic proof for the touched surfaces.

## Validated issue scope

- `src/ecs/bundle_codec.zig` previously depended on caller byte-slice base
  alignment because it reinterpreted `[]u8` storage through `@alignCast` for
  both headers and typed payloads.
- `src/ecs/command_buffer.zig` previously appended encoded payload bytes before
  proving command-metadata admission, so `error.NoSpaceLeft` from
  `appendCommand()` could strand payload usage until `clear()` or a later
  successful `apply()`.
- `src/ecs/world.zig` and `src/ecs/command_buffer.zig` previously materialized
  stack scratch buffers sized by total encoded bundle bytes.
- The public direct encoded-bundle surface previously documented malformed-byte
  rejection without stating that component payload bytes still require
  same-process bit-valid staging rather than general value validation.

## Implemented fixes

- `src/ecs/bundle_codec.zig` now encodes and decodes entry headers and payload
  bytes through explicit byte copies instead of typed pointer reinterprets, so
  direct encoded-bundle validation no longer depends on caller byte-slice base
  alignment.
- `src/ecs/command_buffer.zig` now prechecks command capacity, rolls payload
  bytes back on bundle-staging failure, and directly encodes bundles into the
  reserved payload buffer instead of staging through stack-sized
  `[encoded_len]u8` temporaries.
- `src/ecs/world.zig` now uses allocator-backed encoded bundle scratch for the
  public typed `spawnBundle()` / `insertBundle()` helpers instead of
  stack-sized encoded temporaries.
- `packages/static_ecs/tests/integration/encoded_bundle_runtime.zig` now proves
  that the public encoded-bundle world surface accepts misaligned well-formed
  slices and still rejects malformed byte shape through stable operating
  errors.
- `src/ecs/command_buffer.zig` now directly proves that failed spawn-bundle and
  insert-bundle staging leave payload usage and pending-spawn accounting
  unchanged.
- `src/ecs/world.zig` now directly exercises one large-but-bounded typed bundle
  path after the stack-shape rewrite.
- `packages/static_ecs/README.md`, `packages/static_ecs/AGENTS.md`, root
  `README.md`, root `AGENTS.md`, and `docs/architecture.md` now describe the
  direct encoded-bundle route as structural validation over arbitrary caller
  slice alignment with payload bytes kept on an explicit same-process bit-valid
  staging boundary.

## Proof posture

- The package now owns direct deterministic proof for:
  - misaligned direct encoded-bundle world admission;
  - misaligned bundle-codec read/write roundtrip;
  - failed bundle staging rollback in `CommandBuffer`;
  - large-but-bounded typed bundle admission after the staging rewrite.
- The existing malformed-bundle, direct-world admission, swap-reindex, and
  `testing.model` command-buffer sequence proofs remain in place.

## Current posture

- `static_ecs` remains the same world-local typed-first package slice: no
  runtime-erased queries, import/export, persistence, replication, or spatial
  adapters were added in this follow-up.
- The direct encoded-bundle route remains public, but its truthful boundary is
  now explicit:
  - structural byte shape is validated through stable operating errors;
  - caller byte-slice alignment is no longer part of the contract;
  - component payload bytes remain same-process bit-valid staging input rather
    than a general persisted/untrusted value-validation surface.

## Reopen triggers

- Reopen if another encoded-bundle helper reintroduces alignment-sensitive
  typed pointer casts over caller-provided byte slices.
- Reopen if a future bundle-staging path can again consume payload capacity
  before proving command admission and escape without rollback.
- Reopen if public bundle helpers reintroduce stack scratch proportional to
  encoded bundle bytes.
- Reopen if the direct encoded-bundle docs again imply general payload-value
  validation without an implementation that proves it.
