# Zig coding rules domain split

Date: 2026-03-16

## Goal

Split the monolithic Zig rules reference into domain-specific documents so
humans and agents can open the rule set that matches the task at hand.

## Changes

- Converted `docs/reference/zig_coding_rules.md` into an index document.
- Added separate rule docs for design and safety, performance, API and style,
  repository workflow, and testing and documentation.
- Kept the top-level path stable so existing cross-links still land on a useful
  entry point.
- Updated reference docs and lint checks to treat the split documents as part
  of the repo's source of truth.
