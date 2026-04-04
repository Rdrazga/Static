# `static_gpu` package sketch - 2026-04-02

## Why this package should exist

The workspace has strong CPU-side foundations for memory, collections,
coordination, math, testing, and deterministic runtime work, but it does not
yet have a package that owns GPU-specific concerns:

- adapter and device discovery;
- bounded GPU resource lifetime management;
- explicit command recording and submission;
- cross-backend capability negotiation; and
- deterministic testable control-plane behavior around GPU setup and teardown.

Those concerns should not be forced into `static_io`, `static_math`, or a
future renderer package. They deserve a dedicated boundary.

## Mach reference points

Use Mach as an architectural reference, not as a line-by-line API template.

Primary-source observations:

- Mach explicitly positions itself as modular enough that callers can use only
  the subset they need.
- Mach's GPU documentation says it is developing `sysgpu` as a successor to
  WebGPU.
- Mach's current public GPU memory-management and error-handling docs are not
  filled out yet, so they are not a strong basis for low-level contract design.

Inference from those sources:

- the useful lesson is to keep one Zig-facing GPU boundary and hide backend
  compatibility work behind it;
- backend differences should stay package-local instead of leaking into every
  caller; and
- a future renderer or engine layer should sit above the GPU package, not
  inside it.

## Package goal

Provide a data-oriented, Zig-native GPU package that:

- exposes one explicit public API for device, resource, and submission work;
- keeps backend portability policy inside the package;
- separates control-plane setup from data-plane recording and submission;
- prefers bounded pools, arenas, rings, and caller-owned staging over hidden
  per-draw allocation;
- makes capability negotiation explicit instead of pretending all backends are
  equal; and
- is ready for deterministic mock-backed and retained-failure testing.

## Non-goals

- Do not start with a scene graph, renderer, material system, or ECS renderer.
- Do not own window creation, input, or app lifecycle.
- Do not promise full backend feature parity where hardware APIs genuinely
  differ.
- Do not start with shader compilation pipelines, asset importers, or editor
  tooling.
- Do not hide expensive synchronization or resource-state work behind
  convenience helpers.
- Do not freeze a broad graphics-plus-compute-plus-raytracing umbrella API
  before one small core path is proven.

## Recommended layer and dependency direction

`static_gpu` should be a systems/runtime package with a narrow dependency set.

Recommended runtime dependencies:

- `static_core`
- `static_memory`
- `static_collections`

Optional later dependencies only when justified:

- `static_math` for package-owned helper math types if GPU-specific math
  helpers become unavoidable;
- `static_sync` only if real fence or timeline ownership benefits from shared
  primitives instead of package-local state machines.

Avoid direct runtime dependence on:

- `static_io`
- `static_net`
- `static_serial`
- `static_profile`

Those can integrate above or alongside `static_gpu`, but they should not define
its core boundary.

## Cross-platform compatibility model

Follow Mach's modularity lesson and modern explicit-graphics reality:

1. `static_gpu` should expose one public API surface.
2. Backend implementations should stay in package-local files or internal
   modules.
3. Backend support should be expressed as an explicit capability matrix, not as
   vague portability claims.
4. Compile-time target gating and runtime adapter-feature negotiation should
   both be first-class.
5. Unsupported features should fail explicitly with operating errors such as
   `error.UnsupportedFeature`, `error.UnsupportedBackend`, or
   `error.SurfaceUnavailable`.

The durable shape should assume a backend class comparable to modern explicit
APIs such as Vulkan, Metal, and D3D12, even if only one backend is implemented
initially.

Do not start by promising all three desktop backends at package birth.

## Data-oriented design rules for this package

- Keep resource registries dense and generation-checked.
- Prefer SoA metadata tables for buffers, textures, samplers, pipelines,
  command lists, and fences.
- Keep backend-native objects package-local and reference them through dense
  ids or handles.
- Separate setup-time validation from hot-path submission.
- Encode command recording into linear or chunked command streams rather than
  scattered object graphs.
- Use bounded upload rings, transient descriptor arenas, and fixed frames in
  flight.
- Avoid per-submit heap allocation once the device and frame resources are
  initialized.
- Keep resource transitions, queue ownership, and synchronization visible in
  the API.

## Recommended public surface

### Phase 0: bootstrap and capability discovery

- `GpuConfig`
- `Instance`
- `Adapter`
- `Device`
- `BackendKind`
- `CapabilitySet`
- `LimitSet`
- `FeatureSet`

This phase should answer:

- what backend is active;
- what queues or submission classes exist;
- what limits and formats are supported; and
- what fixed resource budgets are allowed for this process.

### Phase 1: headless resource and transfer core

- `Buffer`
- `Texture`
- `TextureView`
- `Sampler`
- `ShaderModule`
- `BindGroupLayout`
- `BindGroup`
- `PipelineLayout`
- `CommandEncoder`
- `CommandList`
- `Queue`
- `Fence`
- `UploadRing`
- `ReadbackRing`

This first real slice should prefer headless compute and copy capability before
present surfaces. That keeps the initial boundary tighter and avoids windowing
or swapchain pressure too early.

### Phase 2: graphics and presentation

- `Surface`
- `Swapchain`
- `RenderPipeline`
- `RenderPassEncoder`
- `ComputePipeline`

Presentation should arrive only after the resource and submission path is
stable. The first rendering proof can be one bounded triangle or clear-screen
example, not a renderer framework.

## Internal layout recommendation

Suggested package shape:

- `packages/static_gpu/src/root.zig`
- `packages/static_gpu/src/gpu/config.zig`
- `packages/static_gpu/src/gpu/errors.zig`
- `packages/static_gpu/src/gpu/caps.zig`
- `packages/static_gpu/src/gpu/limits.zig`
- `packages/static_gpu/src/gpu/handles.zig`
- `packages/static_gpu/src/gpu/resources.zig`
- `packages/static_gpu/src/gpu/command_stream.zig`
- `packages/static_gpu/src/gpu/backend_interface.zig`
- `packages/static_gpu/src/gpu/backends/mock.zig`
- `packages/static_gpu/src/gpu/backends/vulkan.zig`
- `packages/static_gpu/tests/integration/root.zig`
- `packages/static_gpu/examples/`

Do not add a sibling `static_gpu_native` package unless backend bindings or OS
surface ownership become large enough to justify the split. The repo already
has the pattern through `static_net` and `static_net_native`, but `static_gpu`
should earn that extra boundary instead of starting with it.

## Error model

Follow the repo's existing safety split:

- programmer misuse such as invalid handle reuse, illegal encoder state, or
  impossible resource transition tables should fail fast with assertions;
- operating errors such as device loss, unsupported format, memory exhaustion,
  or surface acquisition failure should use named error sets.

Likely package error vocabulary:

- `error.OutOfMemory`
- `error.UnsupportedBackend`
- `error.UnsupportedFeature`
- `error.UnsupportedFormat`
- `error.DeviceLost`
- `error.SurfaceLost`
- `error.SurfaceUnavailable`
- `error.Timeout`

## Testing fit

Best fit:

- direct integration coverage for creation, destruction, and validation
  contracts;
- mock-backend tests for command recording, capability negotiation, and error
  paths;
- `static_testing.testing.model` coverage for resource lifecycle,
  submit-and-complete sequencing, and fence progression;
- bounded benchmark workflows for upload throughput, submission overhead, and
  descriptor allocation churn.

Later fit:

- backend smoke tests gated behind OS/backend build options;
- retained failure bundles for minimized driver-facing repro cases when a real
  backend exists.

Not first-fit:

- process-boundary tests;
- ECS integration;
- full renderer correctness images;
- broad async runtime orchestration.

## First implementation slice recommendation

The first active plan should stay small:

1. create `packages/static_gpu/` with root exports, config, error vocabulary,
   handle types, and a mock backend;
2. implement `Instance`, `Adapter`, `Device`, `CapabilitySet`, and one bounded
   command-stream shape;
3. implement one `Buffer` plus `UploadRing` path and one deterministic
   submit-and-fence completion path;
4. add direct integration and model-backed proof for lifecycle and ordering;
5. only then decide whether the first real backend should be Vulkan, Metal, or
   D3D12 based on target coverage and tooling constraints.

Do not start with swapchains, shader reflection, bindless resource systems, or
multi-queue scheduling policy.

## Promotion conditions

This sketch should move into an active plan only when all of the following are
true:

- a first concrete backend target is chosen or a mock-only bootstrap slice is
  explicitly approved;
- the package's initial dependency set is accepted;
- the first validation command is named on the plan; and
- the repo is ready to add `static_gpu` to the root `build.zig` workspace graph.

## Sources

- Repo sources:
  - `README.md`
  - `docs/architecture.md`
  - `docs/plans/README.md`
  - `docs/plans/active/README.md`
  - `docs/plans/active/workspace_operations.md`
  - `docs/reference/zig_coding_rules/design_and_safety.md`
  - `docs/reference/zig_coding_rules/performance.md`
  - `docs/reference/zig_coding_rules/repo_workflow.md`
  - `docs/reference/zig_coding_rules/testing_and_docs.md`
- Mach sources:
  - `https://machengine.org/docs/modularity/`
  - `https://machengine.org/docs/gpu/`
  - `https://machengine.org/docs/gpu/errors/`
  - `https://machengine.org/docs/zig-version/`
  - `https://github.com/hexops/mach`
