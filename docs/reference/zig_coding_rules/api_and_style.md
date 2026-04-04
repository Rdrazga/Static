# API And Style Rules

Use this document when shaping public APIs, writing comments, naming things, or
making code easier to review and maintain.

## Naming

### General principles

- Get the nouns and verbs right.
- Do not abbreviate unless the variable is a primitive integer in a sort or
  matrix context.
- Use proper capitalization for acronyms: `VSRState`, not `VsrState`.
- Follow the Zig style guide unless a repository rule overrides it.

### Units, qualifiers, and ordering

- Put units and qualifiers last, in descending significance:
  `latency_ms_max`, not `max_latency_ms`.
- Use names that communicate ownership and lifecycle, such as `gpa` or
  `arena`, rather than generic `allocator`.

### Function and callback naming

- Prefix helper and callback names with the calling function when they are
  tightly coupled, such as `read_sector_callback`.
- Put callbacks last in parameter lists.

### Struct and file ordering

- Files are read top-down. Put the important entry points near the top.
- In structs, order as fields, then types, then methods.

### Name clarity

- Avoid overloaded names with context-dependent meanings.
- Prefer noun descriptors that work well in code, docs, and conversation.

### Named arguments

- Use Zig's `options: struct` pattern when arguments can be mixed up.
- Functions with multiple same-typed scalar arguments should prefer an options
  struct.
- If `null` is meaningful, name the parameter so the meaning of `null` is clear
  at the call site.

## Comments and rationale

- Always say why.
- In tests, also say how.
- Write comments as proper sentences.
- Keep comments self-contained.
- Avoid claims of completeness or optimality; explain mechanism and rationale
  instead.

## Commit messages

- Write descriptive commit messages.
- Commit logical changes that compile and pass fast validation.

## Explicit options at call sites

- Pass options explicitly to library functions rather than relying on defaults.

```zig
@prefetch(a, .{ .cache = .data, .rw = .read, .locality = 3 });
```

## Cache invalidation and data-shape clarity

- Do not duplicate variables or alias state without a clear need.
- If a function argument is larger than 16 bytes and should not be copied, pass
  it as `*const`.
- Construct large structs in place through out-pointers when initialization
  would otherwise force an unnecessary move.
- Prefer simpler return types when they communicate enough information.
- Ensure functions run to completion without suspension so precondition
  assertions remain meaningful.

## Buffer bleeds

- Guard against padding and buffer underflow cases that can leak data or break
  determinism.

## Resource lifecycle

- Visually group allocation and deallocation with blank lines before the
  allocation and after the matching `defer`.

## Off-by-one discipline

- Treat `index`, `count`, and `size` as distinct concepts.
- Make conversions explicit in names and arithmetic.
- Show rounding intent with `@divExact()`, `@divFloor()`, or `div_ceil()`.

## Tooling

- Prefer a small, standard toolbox.
- Use Zig for production code and scripts.
- Put automation in `scripts/*.zig` instead of shell scripts.
