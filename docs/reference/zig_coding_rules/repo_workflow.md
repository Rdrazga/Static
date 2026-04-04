# Repository Workflow Rules

Use this document when changing repository structure, planning non-trivial
work, or adding automation.

## Project structure

The repository should be navigable by inspection. Prefer simple, predictable
paths.

Default layout:

```text
project/
|-- AGENTS.md
|-- build.zig
|-- build.zig.zon
|-- src/
|   |-- main.zig
|   |-- root.zig
|   |-- testing/
|   `-- ...
|-- tests/
|   |-- integration/
|   `-- vopr/
|-- scripts/
`-- docs/
    |-- plans/active/
    |-- plans/completed/
    |-- decisions/
    `-- sketches/
```

Rules:

- Plan structure before implementation so refactors are not needed later.
- `build.zig` is not a dumping ground. Complex automation belongs in
  `scripts/*.zig`.
- Do not create `utils.zig` or `helpers.zig`. Name files by purpose.
- Test infrastructure belongs in `src/testing/`. Test cases belong in `tests/`.

## Planning and design process

Non-trivial work must be planned before coding.

Recommended doc structure:

- `docs/plans/active/` for implementation plans.
- `docs/plans/completed/` for completed plans.
- `docs/decisions/` for ADRs extracted from plans when a decision outlives the
  implementation.
- `docs/sketches/` for back-of-the-envelope calculations and exploratory notes.

Rules:

- Plans are the primary working artifact for non-trivial work.
- Code comments must remain self-contained even when plans or ADRs exist.
- When a change affects the repository workflow or source-of-truth documents,
  update the docs in the same change.
