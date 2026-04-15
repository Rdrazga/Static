# Active Plans

This directory holds the active design and execution queue for the workspace.

- `workspace_operations.md` is the project-wide active task set and process.
- `packages/` holds active package plans only for packages with current
  in-flight work.

Usage rules:

- Start with `workspace_operations.md` when the work spans multiple packages or
  changes repo-wide process.
- Open the matching file in `packages/` before making non-trivial package
  changes when one exists; otherwise start from the latest completed review or
  open a new active plan.
- Write active plans from the target end state backward: define the durable
  boundary, review surface, and explicit non-goals first, then sequence the
  implementation needed to reach that shape without throwaway APIs.
- Express unfinished work as ordered SMART steps with explicit "done when"
  conditions and validation commands instead of vague backlog bullets or
  calendar timelines.
- Keep active plans current while work is in flight.
- Move monitor-only or trigger-only package follow-up into
  `docs/plans/completed/` instead of keeping a placeholder active plan.
- Move finished plans or major review summaries into `docs/plans/completed/`.
