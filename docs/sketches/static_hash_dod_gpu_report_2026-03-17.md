# `static_hash` DoD and GPU report - 2026-03-17

## Executive summary

`static_hash` is strong on deterministic scalar and slice-based hashing, but it
is not yet strongly data-oriented in the sense used by high-throughput ECS,
analytics, batched hash-table, or GPU-resident workloads.

The package should keep two distinct surfaces:

1. a deterministic portable surface for stable semantics and replayable tests;
2. an explicit in-memory / DoS-aware / accelerator-oriented surface for
   architecture-specific and batch-oriented hashing.

For GPU work, the package should not try to port the current generic
`hash_any`/`stableHashAny` model directly. GPU hashing wants batched,
fixed-schema, tree-friendly, or device-resident APIs.

## Where `static_hash` already uses data-oriented structure well

- Byte-oriented entrypoints such as `wyhash`, `xxhash3`, `crc32`, `crc32c`, and
  `fingerprint64` already operate on contiguous byte slices with no allocation.
- `combine` is pure, scalar, and easy to inline into tight loops.
- The benchmark suite already measures representative sizes and payload classes,
  which is the right basis for a DoD-oriented follow-up.

## Where `static_hash` is not yet strongly DoD-oriented

### `hash_any`

`packages/static_hash/src/hash/hash_any.zig:1` is optimized for semantic
correctness and broad type coverage, not for bulk or columnar throughput.

Current limitations:

- recursive per-value dispatch;
- AoS-friendly, not SoA-friendly;
- no `hashMany` / `hashBatch` surface for fixed-size homogeneous elements;
- no lane-wise or block-wise hashing API for large arrays of records.

### `stable`

`packages/static_hash/src/hash/stable.zig:1` is intentionally canonical and
cross-architecture stable. That makes it useful, but it also means:

- explicit tags and length prefixes dominate the design;
- it is row-oriented and reflection-heavy;
- it is not shaped for SIMD or GPU batching;
- it has no schema-compiled fast path for repeated homogeneous records.

### `Fingerprint64V1`

`packages/static_hash/src/hash/fingerprint.zig:74` is a stable streaming
surface, but it is scalar and byte-loop driven.

That is acceptable for a stable versioned format, but it is not the right shape
for a modern batch-hashing or wide-lane path.

### `combine`

`packages/static_hash/src/hash/combine.zig:1` is useful and fast for scalar
composition, but it is missing:

- fold-many helpers for slices of `u64`;
- batch combiners for SoA or lane-packed inputs;
- explicit vectorized or block-combine APIs for many-key pipelines.

## Should there be two surfaces?

Yes.

Trying to force the same API to serve both deterministic portable hashing and
maximum-throughput in-memory hashing will weaken both.

### Surface A - deterministic portable

Keep here:

- `stable`
- `hash_any`
- `fingerprint`
- current portable wrappers

Properties:

- deterministic seeds;
- stable or at least well-documented output policy;
- suitable for tests, replay, persistence, and cross-machine comparison.

### Surface B - in-memory / DoS-aware / accelerator-oriented

Add only as an explicit split surface.

Properties:

- architecture-specific implementations allowed;
- keyed/randomized defaults allowed;
- outputs not promised as persistent or cross-version stable;
- batch and SoA APIs preferred over reflective generic APIs.

Candidate content:

- AES-accelerated keyed hashers;
- map-oriented fast hashers;
- batch `hashMany` / `fingerprintMany` / `combineMany` APIs.

## Where a rewrite or new implementation is justified

- If we want a true DoD-oriented batch surface, wrapping existing scalar APIs is
  not enough. We will need new entrypoints that hash many elements per call.
- If we want an AES-oriented in-memory hasher, a thin wrapper is fine at first,
  but a repo-native batching layer may still be required to get full value from
  it.
- If we want GPU hashing, we need a separate batch/tree/schema-oriented design,
  not a direct rewrite of `hash_any`.

## GPU hashing: what actually changes

GPU hashing is attractive only when at least one of these is true:

- the data is already on GPU;
- there are many independent hashes to compute in parallel;
- the hash itself is tree-parallel or batch-friendly; or
- the hash is part of a GPU-resident pipeline such as Merkle trees, zk proof
  systems, GPU databases, or GPU-resident indexing.

GPU hashing is usually a poor fit when:

- messages are small and originate on the CPU;
- latency for one hash matters more than aggregate throughput;
- the workload is irregular and branch-heavy;
- transfer overhead dominates the computation.

## Real GPU use cases

- Merkle tree construction and proof generation
- zero-knowledge / proof-system hash workloads
- batched cryptographic hashing in GPU kernels
- GPU-resident databases and key-value indexes
- deduplication or chunk fingerprinting inside GPU-first pipelines

## Existing GPU-friendly directions

### Cryptographic GPU hashing

- NVIDIA `cuPQC-Hash` provides device-side GPU implementations of SHA-2,
  SHA-3, SHAKE, and Poseidon2, plus Merkle-tree operations. That is strong
  evidence that GPU hashing is most compelling for large batched crypto and
  proof workloads, not small generic host-side hashes.
- `BLAKE3` is explicitly tree-based and highly parallelizable across SIMD lanes
  and threads. That makes it a much better conceptual starting point for future
  accelerator work than scalar hashers like `wyhash` or `fnv1a`.
- `ParallelHash` exists specifically to exploit processor parallelism for long
  inputs and is a standards-based reference point for tree-hash design.

### GPU hash indexes and tables

- GPHash shows the right design principles for GPU-resident indexing:
  warp-cooperative execution, coalesced memory access, lock-free operations,
  and GPU-conscious table layout.
- That is fundamentally different from the current `static_hash` API model,
  which is function-oriented and CPU-scalar.

## What `static_hash` would need for serious GPU work

### Do not start with

- direct GPU ports of `hash_any`;
- direct GPU ports of `stableHashAny`;
- per-message host-call APIs.

### Start with

- batched byte hashing APIs;
- tree-hash / Merkle primitives;
- fixed-schema row or column batch hashing;
- explicit device-buffer and async execution boundaries.

## Needed redesigns that do not exist yet in this repo

- `hashMany(bytes_list, seeds)` style batched APIs for many independent inputs;
- schema-compiled stable hashing for repeated records, rather than generic
  reflective `anytype` dispatch;
- explicit in-memory keyed surface for hash tables and adversarial short keys;
- a separate `static_hash_gpu` or sibling accelerator package if GPU work
  becomes real.

## Recommendation

- Keep `static_hash` itself focused on portable deterministic hashing plus a
  clearly separated in-memory fast-hash surface.
- Treat GPU hashing as a separate design track built around batch, tree, and
  device-resident execution.
- If the repo wants one crypto/accelerator addition first, `BLAKE3` is the
  strongest candidate. If the repo wants one in-memory fast-hash addition
  first, an AES-oriented keyed hasher is the strongest candidate.

## Sources

- Local code:
  - `packages/static_hash/src/hash/hash_any.zig`
  - `packages/static_hash/src/hash/stable.zig`
  - `packages/static_hash/src/hash/fingerprint.zig`
  - `packages/static_hash/src/hash/combine.zig`
- External references:
  - `https://github.com/tkaitchuck/aHash`
  - `https://github.com/ogxd/gxhash`
  - `https://github.com/orlp/foldhash`
  - `https://github.com/BLAKE3-team/BLAKE3`
  - `https://keccak.team/2016/sp_800_185.html`
  - `https://docs.nvidia.com/cuda/cupqc/overview/feature_cupqc_hash.html`
  - `https://www.usenix.org/system/files/fast25-chen-menglei.pdf`
