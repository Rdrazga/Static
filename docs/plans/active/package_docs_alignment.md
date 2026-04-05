# Package docs alignment plan

Scope: add and align package-local `README.md` and `AGENTS.md` files across
all `static_*` packages so package navigation, validation commands, and
workflow expectations are explicit, short, and mechanically enforceable.

## Context

- The 2026-02-11 OpenAI harness engineering write-up reinforces the repo shape
  this workspace already uses: short `AGENTS.md` files should act as maps,
  deeper rules should live in versioned repo docs, and documentation topology
  should be enforced mechanically.
- This repo already has a strong root map plus package-local docs for
  `static_io`, `static_testing`, and `static_ecs`, but most package roots still
  lack the same entry-point pair.
- The right end state is not "write marketing copy for each package." The
  right end state is "make every package legible to an agent or new engineer
  from the package root without bloating context or diverging from root
  command semantics."

## Durable package-doc contract

- Every `packages/static_*` root should carry both `README.md` and `AGENTS.md`.
- `AGENTS.md` is the fast operational map:
  - source-of-truth links first;
  - supported root validation commands;
  - package-specific working agreements;
  - a short package map over real source/test/benchmark/example paths;
  - a small change checklist;
  - keep it short enough to stay usable as an injected map rather than a
    package manual.
- `README.md` is the package entry point:
  - one-sentence purpose;
  - current status and scope boundary;
  - main surfaced modules;
  - validation commands;
  - key paths;
  - benchmark artifact notes only when the package owns benchmarks.
- Cross-package wording should stay aligned:
  - root `build.zig` is the supported validation surface;
  - command semantics should match the root docs;
  - package docs should point to `docs/architecture.md`,
    `docs/plans/active/workspace_operations.md`, and the most relevant active
    or completed package plan when one exists.

## Ordered SMART tasks

1. `Shared package-doc rules`
   Record the package-local `README.md` and `AGENTS.md` contract in the repo's
   durable documentation rules.
   Done when the package-doc structure, section intent, and alignment rules are
   written into the matching reference/workflow docs.
   Validation:
   - `zig build docs-lint`
2. `Package root coverage`
   Add the missing package-local doc pair for every `packages/static_*`
   directory and align any existing pairs to the same structure and command
   semantics.
   Done when every package root has both files and each pair reflects the real
   source, tests, examples, benchmarks, and current package scope.
   Validation:
   - `zig build docs-lint`
3. `Shared navigation alignment`
   Update the root repo docs so they describe the package-local docs as a
   normal part of repository navigation instead of a few package-specific
   exceptions.
   Done when root navigation docs describe package-local entry points without
   stale package-specific caveats.
   Validation:
   - `zig build docs-lint`
4. `Mechanical enforcement`
   Extend docs lint so missing package-local docs or obvious topology drift are
   caught automatically.
   Done when `scripts/docs_lint.zig` validates package-local doc presence and
   the minimum shared package-doc invariants.
   Validation:
   - `zig build docs-lint`

## Work order

1. Lock the shared package-doc contract.
2. Add or align package-local docs package by package.
3. Update root navigation once the package coverage exists.
4. Enforce the new topology mechanically.

## Ideal state

- Every package root is self-anchoring.
- Package docs stay short, local, and structurally aligned.
- Deeper rules remain in repo-owned plans, reference docs, and code comments
  instead of leaking into package maps.
- Docs lint catches missing package entry points before drift compounds.
