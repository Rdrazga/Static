# Testing And Documentation Rules

Use this document when adding tests, examples, simulation coverage, or
reference material.

## Testing

Tests must exercise valid data, invalid data, and transitions where valid data
becomes invalid.

### Tiered testing

- Unit tests: inline `test` blocks in `src/` for the fast loop.
- Integration tests: `tests/integration/` for build-loop and cross-package
  validation.
- Compile-time tests: `comptime` assertions and `@compileError` for invariants.
- Fuzz and property tests: deterministic seeds with strong boundary focus for
  parsers, codecs, and configuration.

### Additional expectations

- Prefer deterministic seeds and replayable failures.
- Add simulation coverage when the behavior depends on interleavings or
  schedule-sensitive state.
- Test operating-error paths as thoroughly as success paths.

## Documentation

Documentation is layered:

- Tier 0: `AGENTS.md` for commands, key paths, and current work pointers.
- Tier 1: in-code `//!` and `///` comments, which should generate most code
  documentation.
- Tier 2: `docs/architecture.md` for system-level views.
- Tier 3: `docs/reference/` for stable contracts such as wire formats and error
  vocabularies.

### Documentation rules

- Keep the repo's source-of-truth docs cross-linked and current.
- Move stable long-lived rules into `docs/reference/`.
- Keep exploratory material in `docs/sketches/` until it is stable enough to
  become a plan, decision, or reference document.
- When tests demonstrate a subtle contract, explain the test goal and method at
  the top of the test.
