# Zig 0.16.0 stable migration closed

Date: 2026-04-14

## Scope

Move the workspace from the previously pinned `0.16.0-dev` snapshot to the
tagged Zig `0.16.0` stable release, restore the supported root build surface on
that toolchain, and capture which Zig 0.16 changes were intentionally adopted
while closing the migration.

## Outcome

- The machine and repo baseline now target tagged Zig `0.16.0` stable.
- Root and package `build.zig.zon` files now declare
  `.minimum_zig_version = "0.16.0"`.
- The supported root validation surface is green on stable:
  - `zig build docs-lint`
  - `zig build check`
  - `zig build ci`
- The migration no longer depends on the prior dev snapshot.

## Closed work

1. `Repo baseline and metadata`
   Closed by:
   - moving repo and package metadata off the dev snapshot;
   - removing repo references to the old unstable download path;
   - documenting the stable baseline in the root repo docs.
2. `Core stdlib API migration`
   Closed by:
   - introducing shared stable time and threading compatibility surfaces;
   - updating downstream timing, mutex, condition-variable, futex, queue,
     scheduling, I/O, and testing call sites to the stable API shape.
3. `Container init-shape migration`
   Closed by:
   - moving affected `std.ArrayListUnmanaged` and similar unmanaged-container
     initialization sites to the stable zero-value shape.
4. `Windows stdlib and process-surface migration`
   Closed by:
   - adding repo-local Windows compatibility shims where Zig 0.16 moved or
     dropped stdlib wrappers needed by this workspace;
   - updating Windows file, socket, process, and path/cwd call sites to the
     stable signatures;
   - realigning stable test and example surfaces that depended on older Windows
     or allocator APIs.
5. `ECS stable-language migration`
   Closed by:
   - making the tuple-field metadata used by ECS validators explicitly
     comptime-known under Zig 0.16;
   - giving `ComponentTypeId` an explicit packed `u32` backing so encoded-bundle
     extern headers remain valid.
6. `Stable validation sweep`
   Closed by:
   - fixing the remaining stable-only validation fallout uncovered by
     `zig build ci`, including process-timeout test commands, compile-contract
     child cwd setup, Windows loopback integration coverage, and example
     allocator updates.

## Deliberate Zig 0.16 adoption

- `packed struct(u32)` is now used where binary or extern ECS contracts require
  an explicit backing integer instead of relying on inferred signedness.
- Repo-local Windows compat modules now own the exact stable subset of the old
  stdlib Windows wrapper surface this workspace still needs, keeping callers
  stable without broadening package APIs.
- Child-process call sites now use the stable `std.process.Child.Cwd` union
  shape directly instead of preserving the older string-only assumption.

## Follow-up posture

No extra cross-package stable-migration work remains open. Future work should
reopen through package-local plans or a new workspace plan only when a concrete
0.16-specific bug, benchmark signal, or ownership mismatch appears.
