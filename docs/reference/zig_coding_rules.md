# Zig Coding Rules

This index replaces the old monolithic rules document with task-specific
references. Start here, then open the rule set that matches the work you are
doing.

## Design goals

Priorities, in order:

1. Safety
2. Performance
3. Dev experience
4. Maintainability
5. Extensibility

## Rule sets by task

- `docs/reference/zig_coding_rules/design_and_safety.md` for implementation
  design, bounded control flow, assertions, memory rules, and error handling.
- `docs/reference/zig_coding_rules/performance.md` for performance planning,
  batching, hot-loop shape, and resource sketches.
- `docs/reference/zig_coding_rules/api_and_style.md` for naming, comments,
  argument design, call-site clarity, and code-shape rules.
- `docs/reference/zig_coding_rules/repo_workflow.md` for project structure,
  planning, scripts, and repository change workflow.
- `docs/reference/zig_coding_rules/testing_and_docs.md` for tests,
  compile-time checks, fuzzing expectations, and documentation layering.

## How to use this index

- When implementing runtime code, read `design_and_safety.md` first and then
  `performance.md` or `api_and_style.md` as needed.
- When changing repository structure or automation, read `repo_workflow.md`.
- When adding or changing tests, examples, or reference material, read
  `testing_and_docs.md`.
- Keep this index stable. Add new rule documents only when a category has a
  clear long-lived purpose.
