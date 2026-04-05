# `static_simd`

Portable SIMD lane-vector types and helpers for the `static` workspace.

## Current status

- The root workspace build is the supported entry point; package-local `zig build` is not the supported validation surface.
- `static_simd` owns width-typed lane-parallel helpers over float and integer vectors, plus memory, gather/scatter, compare, horizontal, math, trig, and shuffle operations.
- Package-level integration coverage includes replay-backed trig differential testing against scalar references and edge-case checks for non-crashing behavior at the integration surface.
- The package ships usage examples for vector construction, comparisons, horizontal reduction, masked gather/scatter, memory load/store, and trig range/accuracy.
- The package does not currently admit a benchmark workflow.

## Main surfaces

- `src/root.zig` exports the package API and module summary.
- `src/simd/vec_type.zig` owns the generic wrapper factory and width-specific composition.
- `src/simd/vec2f.zig`, `src/simd/vec4f.zig`, `src/simd/vec8f.zig`, `src/simd/vec16f.zig`, `src/simd/vec2i.zig`, `src/simd/vec4i.zig`, `src/simd/vec8i.zig`, `src/simd/vec4u.zig`, and `src/simd/vec4d.zig` own the explicit vector wrappers.
- `src/simd/masked.zig`, `src/simd/memory.zig`, `src/simd/gather_scatter.zig`, `src/simd/compare.zig`, `src/simd/horizontal.zig`, `src/simd/math.zig`, `src/simd/trig.zig`, and `src/simd/shuffle.zig` own the operation families.
- `src/simd/platform.zig` owns platform detection and capability gating.
- `tests/integration/root.zig` wires the package-level regression surface.
- `tests/integration/replay_fuzz_trig_differential.zig` owns the retained trig differential proof.
- `examples/` owns the canonical usage samples.

## Validation

- `zig build check`
- `zig build test`
- `zig build examples`
- `zig build docs-lint`

## Key paths

- `tests/integration/replay_fuzz_trig_differential.zig` checks trig lanes against scalar references over bounded deterministic families.
- `examples/vec4f_basic.zig` shows the basic vector construction and lane access pattern.
- `examples/compare_select_basic.zig` demonstrates compare/select helpers.
- `examples/horizontal_reduction.zig` shows horizontal reduction behavior.
- `examples/masked_gather_scatter_basic.zig` and `examples/memory_load_store.zig` cover masked and memory-access helpers.
- `examples/trig4f_range_and_accuracy.zig` shows the trig range and accuracy contract.

## Notes

- Keep SIMD-specific behavior explicit in code and examples instead of relying on implicit platform assumptions.
- Keep scalar math and geometry conventions in `static_math`; `static_simd` stays focused on lane-parallel execution helpers.
