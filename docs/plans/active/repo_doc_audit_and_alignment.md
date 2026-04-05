# Repo doc audit and alignment plan

Scope: review the repo's markdown and `AGENTS.md` surface for valid structure,
current references, and package/tree alignment, then validate the findings
against the real repository and apply the resulting fixes.

## Review intent

- Treat docs as repository infrastructure, not decorative prose.
- Prefer small factual fixes over style churn.
- Validate findings against the actual tree, command surface, and current
  package boundaries before editing docs.
- Keep historical docs historical: fix broken structure, stale navigation, or
  now-false statements, but do not rewrite archival design content into new
  product docs.

## Audit slices

1. Root and source-of-truth docs
   Files:
   - `AGENTS.md`
   - `README.md`
   - `docs/README.md`
   - `docs/architecture.md`
   - `docs/reference/**/*.md`
2. Package doc pairs
   Files:
   - `packages/static_*/README.md`
   - `packages/static_*/AGENTS.md`
3. Planning and index docs
   Files:
   - `docs/plans/README.md`
   - `docs/plans/active/**/*.md`
   - `docs/design/README.md`
   - `docs/decisions/README.md`
   - `docs/sketches/README.md`
4. Sketch docs
   Files:
   - `docs/sketches/**/*.md`

## Ordered SMART tasks

1. `Audit partition`
   Record the audit slices and validation criteria.
   Done when this plan exists and each slice has a bounded ownership set.
   Validation:
   - `zig build docs-lint`
2. `Parallel review and fix`
   Review each slice, validate findings against the real repo tree, and apply
   the resulting fixes in place.
   Done when each slice either lands fixes or records that no fix was needed.
   Validation:
   - `zig build docs-lint`
3. `Shared reconciliation`
   Resolve any cross-slice root-doc or lint-rule fallout discovered during the
   audit.
   Done when shared docs and `scripts/docs_lint.zig` match the final topology.
   Validation:
   - `zig build docs-lint`
4. `Final verification`
   Re-run the docs validation surface after all fixes land.
   Done when `zig build docs-lint` passes and the markdown-link check reports
   no broken `.md` links.

## Ideal state

- Source-of-truth docs match the current repo shape.
- Package doc pairs stay structurally aligned and factually correct.
- Planning and index docs point at live files and current workflow.
- Docs lint catches the stable topology expectations mechanically.
