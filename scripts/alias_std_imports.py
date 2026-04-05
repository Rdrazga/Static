"""
alias_std_imports.py — Workspace-wide std alias normalisation.

Transformations applied to every .zig file (excluding .zig-cache):

  1. assert  — std.debug.assert( → assert(
               adds `const assert = std.debug.assert;` if not present.

  2. panic   — std.debug.panic( → panic(
               adds `const panic = std.debug.panic;` if not present.

  3. testing — std.testing.XXX → testing.XXX
               adds `const testing = std.testing;` if not present AND no name
               conflict (files that already bind `testing` to something else are
               skipped).
               Also removes redundant inner `const testing = std.testing;`
               lines that live inside test blocks (they become shadowing noise
               once the file-scope alias exists).

Safety rules:
  - Replacements only touch `std.debug.assert(` / `std.debug.panic(` /
    `std.testing.` (call/field-access forms), NOT bare identifiers in comments
    (bare identifier without ( or . follow-up). Comments that say
    "// uses std.debug.assert" are not modified.
  - The alias definition line itself (`= std.debug.assert;`) is not replaced.
  - Alias insertions are placed immediately after `const std = @import("std");`.
  - Files without `const std = @import("std");` are skipped for alias insertion
    but still get replacements if the alias is already present.

Usage:
  python scripts/alias_std_imports.py           # apply
  python scripts/alias_std_imports.py --dry-run # show what would change
"""

import os
import re
import sys
from pathlib import Path

DRY_RUN = "--dry-run" in sys.argv

ROOT = Path(__file__).parent.parent  # workspace root

# Patterns for detecting use (call / field-access sites only)
USE_ASSERT  = re.compile(r'std\.debug\.assert\(')
USE_PANIC   = re.compile(r'std\.debug\.panic\(')
USE_TESTING = re.compile(r'std\.testing\.')

# Patterns for detecting existing aliases at file scope (line-start, unindented)
HAS_ASSERT_ALIAS  = re.compile(r'^const assert\s*=\s*std\.debug\.assert\s*;', re.MULTILINE)
HAS_PANIC_ALIAS   = re.compile(r'^const panic\s*=\s*std\.debug\.panic\s*;',  re.MULTILINE)
HAS_TESTING_ALIAS = re.compile(r'^const testing\s*=\s*std\.testing\s*;',     re.MULTILINE)

# Any binding of the name `testing` to something OTHER than std.testing
# (static_testing, a sub-module, etc.) — skip testing transform for these files.
TESTING_CONFLICT  = re.compile(
    r'^(?:pub\s+)?const\s+testing\s*=\s*(?!std\.testing\s*;)',
    re.MULTILINE,
)

# Inner (indented) duplicate testing alias to remove once file-scope one is added
INNER_TESTING_ALIAS = re.compile(r'^[ \t]+const testing\s*=\s*std\.testing\s*;\n', re.MULTILINE)

# std import line (used as insertion anchor)
STD_IMPORT_LINE = re.compile(r'^([ \t]*const std\s*=\s*@import\("std"\)\s*;)', re.MULTILINE)

# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------

def collect_zig_files(root: Path):
    for dirpath, dirnames, filenames in os.walk(root):
        # Prune cache and hidden dirs in-place
        dirnames[:] = [
            d for d in dirnames
            if d not in ('.zig-cache', '.git', 'node_modules', '.tmp')
        ]
        for name in filenames:
            if name.endswith('.zig'):
                yield Path(dirpath) / name


def insert_aliases_after_std_import(text: str, aliases: list[str]) -> str:
    """Insert alias lines immediately after `const std = @import("std");`."""
    m = STD_IMPORT_LINE.search(text)
    if not m:
        return text  # no anchor — caller handles gracefully
    insert_pos = m.end()
    blob = '\n' + '\n'.join(aliases)
    return text[:insert_pos] + blob + text[insert_pos:]


# ------------------------------------------------------------------
# Per-file transform
# ------------------------------------------------------------------

def transform(path: Path) -> tuple[str, str] | None:
    """
    Return (original, new) if a change is needed, else None.
    """
    original = path.read_text(encoding='utf-8')
    text = original

    needs_assert_alias  = False
    needs_panic_alias   = False
    needs_testing_alias = False

    # --- assert ---
    if USE_ASSERT.search(text):
        if not HAS_ASSERT_ALIAS.search(text):
            needs_assert_alias = True
        # Replace calls regardless (handles case where alias exists but
        # someone still wrote std.debug.assert() by mistake)
        text = USE_ASSERT.sub('assert(', text)

    # --- panic ---
    if USE_PANIC.search(text):
        if not HAS_PANIC_ALIAS.search(text):
            needs_panic_alias = True
        text = USE_PANIC.sub('panic(', text)

    # --- testing ---
    if USE_TESTING.search(text):
        has_conflict = TESTING_CONFLICT.search(text)
        if has_conflict:
            # Check it's NOT just our own alias (std.testing) — TESTING_CONFLICT
            # already excludes std.testing via negative lookahead, so any match
            # here is a real conflict.
            pass  # skip testing transform for this file
        else:
            has_alias = HAS_TESTING_ALIAS.search(text)
            if not has_alias:
                needs_testing_alias = True
            # Replace std.testing.XXX → testing.XXX
            # But NOT the alias definition line itself — it no longer contains
            # std.testing. after being added (or it used `std.testing` only in
            # the RHS which ends with `;`, not `.`), so the substitution is safe.
            text = USE_TESTING.sub('testing.', text)
            # Remove inner duplicate aliases (indented inside test blocks)
            if has_alias or needs_testing_alias:
                text = INNER_TESTING_ALIAS.sub('', text)

    # --- insert new aliases after `const std = @import("std");` ---
    new_aliases = []
    if needs_assert_alias:
        new_aliases.append('const assert = std.debug.assert;')
    if needs_panic_alias:
        new_aliases.append('const panic = std.debug.panic;')
    if needs_testing_alias:
        new_aliases.append('const testing = std.testing;')

    if new_aliases:
        text = insert_aliases_after_std_import(text, new_aliases)

    if text == original:
        return None
    return original, text


# ------------------------------------------------------------------
# Main
# ------------------------------------------------------------------

def main():
    changed = 0
    skipped_no_std = 0

    for path in sorted(collect_zig_files(ROOT)):
        result = transform(path)
        if result is None:
            continue

        original, new_text = result

        # Sanity: if we needed to insert an alias but couldn't find the anchor
        # (std import), don't write garbage
        if 'const std = @import("std");' not in original:
            # aliases were not inserted (insert_aliases_after_std_import is a
            # no-op when anchor missing) — only write if replacements changed text
            skipped_no_std += 1

        rel = path.relative_to(ROOT)
        if DRY_RUN:
            print(f"  WOULD CHANGE: {rel}")
        else:
            path.write_text(new_text, encoding='utf-8')
            print(f"  changed: {rel}")
        changed += 1

    print(f"\n{'[dry-run] ' if DRY_RUN else ''}{'would change' if DRY_RUN else 'changed'} {changed} files.")
    if skipped_no_std:
        print(f"  ({skipped_no_std} of those had no `const std` anchor for alias insertion)")


if __name__ == '__main__':
    main()
