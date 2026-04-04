# Performance Rules

Use this document when designing fast paths, benchmarking, or evaluating
tradeoffs that affect throughput or latency.

## Think early

Solve performance in the design phase whenever possible. The largest gains come
from structure, not late micro-optimization.

Have mechanical sympathy. Work with the grain of the hardware and the access
pattern.

## Back-of-the-envelope sketches

Sketch against the four main resources and their two key characteristics:

| Resource | Bandwidth | Latency |
|----------|-----------|---------|
| Network | ... | ... |
| Disk | ... | ... |
| Memory | ... | ... |
| CPU | ... | ... |

Add GPU when appropriate.

Sketches are cheap and should get you within range of the real optimum before
implementation begins.

## Optimization order

- Optimize the slowest resources first: network, then disk, then memory, then
  CPU.
- Adjust for frequency. A repeated memory miss can matter as much as a rare
  disk flush.

## Control plane vs. data plane

- Keep a clear separation between control-plane work and data-plane work.
- Batch across the boundary when possible.
- Preserve assertion density in setup code so hot paths can stay lean.

## Batching

- Batch network, disk, memory, and CPU work wherever possible.
- Give the CPU large, predictable chunks of work.
- Avoid unnecessary per-event context switching.

## Explicitness over compiler trust

- Be explicit rather than depending on the compiler to discover the right
  optimization.
- Extract hot loops into standalone functions with primitive arguments instead
  of `self`.
- This helps both humans and the compiler reason about aliasing and repeated
  loads.

Example pattern:

```zig
fn hot_loop(base_ptr: [*]u8, count: u32, stride: u32) void {
    // Standalone: no self, primitive args, easy to reason about.
}
```
