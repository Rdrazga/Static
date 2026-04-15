# Harness engineering repo alignment

Date: 2026-03-16

## Context

The OpenAI harness engineering article argues for three repository properties that matter here:

- Repository knowledge should be the system of record, with short boot documents and strong cross-linking.
- Harnesses should be first-class workflow entry points rather than buried implementation details.
- Repository legibility should be maintained mechanically where possible so agents and humans can re-anchor quickly.

## Repo gaps found

- The root `agents.md` had grown into a long policy document instead of a fast operational entry point.
- The workspace had strong harness primitives in `packages/static_testing/`, but no root `zig build harness` step that made them obvious.
- `zig build docs-lint` only checked formatting and did not verify the repository's source-of-truth documents.
- `docs/architecture.md` and `README.md` did not surface `static_testing` as part of the repo's primary workflow.

## Changes applied

- Renamed the root guide to `AGENTS.md` and shortened it to an operational repo map.
- Moved the detailed coding contract into `docs/reference/zig_coding_rules.md`.
- Added `docs/plans/README.md` so the plan workflow is visible from a single stable path.
- Added `scripts/docs_lint.zig` and wired `zig build docs-lint` to mechanically validate required doc topology and cross-links.
- Added `zig build harness` as a workspace entry point for the deterministic `static_testing` smoke path.
- Updated `README.md`, `docs/architecture.md`, and `docs/reference/README.md` to cross-link the new source-of-truth documents.

## Follow-up recommendations

- Add hosted CI wiring that runs `zig build docs-lint`, `zig build test`, and `zig build harness` on every change.
- Introduce a stable artifact convention for replay failures and benchmark outputs once the workspace starts exporting them from root-level workflows.
- Periodically move ad hoc review prompts, such as `Note.txt`, into plans or sketches so the repo stays self-describing.
