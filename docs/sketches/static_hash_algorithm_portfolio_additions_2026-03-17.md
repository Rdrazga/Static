# `static_hash` algorithm portfolio additions sketch - 2026-03-17

## Purpose

This sketch defines the remaining algorithmic portfolio work for `static_hash`
after the current correctness, benchmark, and wrapper-normalization pass.

The immediate question is not "what is the single fastest hash on the internet?"
It is:

1. which missing algorithm families materially improve the package;
2. which of those fit the repo's deterministic and bounded constraints; and
3. which should remain separate surfaces because they optimize for different
   goals.

## Current package boundary

`static_hash` already covers:

- portable scalar non-cryptographic hashing: `fnv1a`, `wyhash`, `xxhash3`;
- keyed and checksum surfaces: `siphash`, `crc32`, `crc32c`;
- package-owned deterministic semantics: `fingerprint`, `stable`, `hash_any`,
  `combine`, and `budget`.

The remaining gap is portfolio breadth, not basic correctness.

## Candidate families

| Candidate family | Why add it | Fit with current package | Main risk | Recommendation |
| --- | --- | --- | --- | --- |
| `rapidhash`-class portable non-crypto hash | Strong portable throughput candidate and natural successor/peer to `wyhash` | Good fit as a one-shot + seeded + streaming wrapper if implementation is stable enough | Upstream maturity and output-stability policy | Prototype first |
| AES-accelerated in-memory hash (`aHash`/`gxhash` class) | Gives a distinct high-end in-memory path for hash tables and batched keys | Good fit only as a separate fast/in-memory surface | Target-feature gating, unsafe/vector-heavy implementation, weak persistence story | Research and likely add behind explicit surface split |
| `foldhash`-class minimally DoS-resistant map hasher | Valuable for hash table workloads where keyed speed matters more than portability | Partial fit; stronger as a table-oriented surface than as a general-purpose hash API | Rust-specific assumptions and map-centric ergonomics | Research as design input, not necessarily as direct port |
| `polymur` / universal-mixing family | Interesting quality/performance point for keyed scalar hashing | Possible fit for specialized keyed/flood-resistant use cases | Additional math/validation burden without a clear immediate consumer | Defer unless a concrete consumer appears |
| `BLAKE3` | Adds a cryptographic, SIMD- and tree-parallel content hash for large payloads | Fits as a separate crypto/content-addressing surface, not a replacement for current fast hashers | Larger API and implementation scope | Research and decide separately |
| `ParallelHash` / `KangarooTwelve` class tree hashes | Valuable when standards-based or GPU/parallel-friendly long-input hashing matters | Better as a later crypto/parallel sub-surface than a near-term core addition | Scope expansion and weaker immediate demand | Defer behind `BLAKE3` decision |

## Decision rules

### Add near-term only if all are true

- the algorithm fills a portfolio gap, not just a benchmark vanity gap;
- it can be exposed with deterministic seeds and bounded artifacts;
- the package can explain where it is safe to use and where it is not;
- benchmark wins are meaningful on at least one supported hardware class; and
- the test surface can compare against a primary source or official vectors.

### Keep separate surfaces when any are true

- the algorithm is intentionally unstable across versions or hardware;
- the algorithm is only attractive for in-memory hash maps;
- the algorithm depends on target features such as AES or wide SIMD;
- the algorithm is only compelling in batched/SoA workloads; or
- the algorithm is cryptographic and wants different usage guidance.

## Proposed portfolio shape

### Surface A: deterministic general-purpose

Keep the current portable and explainable default surface here:

- `wyhash`, `xxhash3`, `fnv1a`, `siphash`, `crc32`, `crc32c`;
- `fingerprint`, `stable`, `hash_any`, `combine`, `budget`.

Potential additions:

- `rapidhash` if it proves materially better than `wyhash` or `xxhash3` on the
  repo's representative workloads without harming the API story;
- `BLAKE3` if the package wants a cryptographic content-addressing surface.

### Surface B: in-memory / DoS-aware / hardware-accelerated

Make this an explicit opt-in family rather than blending it into the current
defaults.

Potential additions:

- AES-accelerated keyed hasher in the `aHash`/`gxhash` class;
- maybe a map-oriented batching surface that hashes many short keys per call.

Rules:

- outputs are not for persistence or wire protocols;
- architecture and target-feature dependence must be documented at the API
  boundary; and
- deterministic seeds must be supported even if the default runtime mode uses
  randomized keys.

### Surface C: crypto / tree / accelerator-oriented

If added, this should likely be a submodule or a sibling package boundary:

- `BLAKE3`;
- maybe standards-based `ParallelHash` later;
- future GPU-oriented tree hash / Merkle primitives.

## Recommended research order

1. `rapidhash`-class portable addition
2. AES-accelerated keyed in-memory family
3. `BLAKE3`
4. parallel / GPU-friendly tree hashes

This order keeps scope bounded:

- first close the gap against newer portable non-cryptographic libraries;
- then decide whether a separate in-memory/DoS-oriented surface belongs here;
- then decide whether `static_hash` wants a cryptographic/tree-hash lane.

## Implementation slices

### Slice 1: portfolio baselines

- Add research-only benchmark rows against external candidate implementations.
- Extend the current benchmark matrix with large-buffer and many-short-key cases
  that reflect the candidate families' strengths.

### Slice 2: candidate prototypes

- Prototype one portable candidate and one AES-oriented candidate behind
  internal or experimental naming.
- Reuse the current replay, differential, and benchmark harnesses.

### Slice 3: surface split decision

- Decide whether in-memory keyed/hash-table surfaces belong inside
  `static_hash` or in a sibling package/module.
- Freeze naming, seed policy, and stability policy before broad adoption.

### Slice 4: crypto / accelerator follow-up

- Decide whether `BLAKE3` belongs in `static_hash` or should live in a new
  dedicated crypto/accelerator surface.
- Only after that, decide whether GPU-facing work should be part of the same
  design line.

## Non-goals

- Replace the current default portfolio only because another algorithm is
  faster on one benchmark chart.
- Hide architecture-specific behavior behind the same API contract as the
  current deterministic portable surface.
- Port arbitrary host-language `hash_any` semantics onto GPU kernels.

## External reading

- `https://github.com/wangyi-fudan/wyhash`
- `https://github.com/Cyan4973/xxHash`
- `https://github.com/tkaitchuck/aHash`
- `https://github.com/ogxd/gxhash`
- `https://github.com/orlp/foldhash`
- `https://github.com/BLAKE3-team/BLAKE3`
- `https://keccak.team/2016/sp_800_185.html`
