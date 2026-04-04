# `static_testing` artifact format strategy - 2026-03-18

## Goal

Define one coherent artifact policy for `static_testing` so benchmark,
simulation, replay, and failure outputs stay:

- Zig-native and schema-driven;
- easy to validate against typed structs;
- efficient for long-running and append-only workloads; and
- easy to extract into a later dedicated artifact package without rewriting
  every harness surface.

## Constraints

- Keep all work inside `static_testing` for now.
- Do not add built-in `zon -> json`, `binary -> jsonl`, or similar conversion
  helpers.
- Assume downstream repos are Zig-first and can import the same schema types.
- Prefer compile-time checked schemas where possible and strict typed runtime
  decode where artifacts are generated at runtime.
- Avoid I/O-heavy text formats on hot append-only paths such as benchmark
  histories, long-running swarm campaigns, or future causality/event streams.

## Current artifact inventory

| Surface | Current output | Current format class | Intended use |
| --- | --- | --- | --- |
| Replay artifact | `replay.bin` | compact binary | deterministic replay payload |
| Corpus entry | `*.bin` replay artifact | compact binary | persisted failing seed/artifact |
| Benchmark baseline | `baseline.json` | bounded text document | reviewable baseline artifact |
| Benchmark history | `history.jsonl` | append-only text stream | prior-run comparison history |
| Failure bundle manifest | `manifest.json` | bounded text document | metadata and compatibility |
| Failure bundle violations | `violations.json` | bounded text document | checker output |
| Failure bundle trace | `trace.json` | potentially large text document | retained event trace |
| Model action mirror | `actions.zon` | bounded typed document | optional review/debug copy of action log |
| Model action record | `actions.bin` | compact binary | canonical replay-oriented actions |
| Process output | `stdout.txt` / `stderr.txt` | raw text | literal captured process output |
| Exploration failure record | in-memory only today | none persisted | failing schedule decision stream |
| Swarm/campaign progress | plain text only today | none persisted | local/CI progress output |

## Policy

Use three artifact classes, not one universal format:

1. **Bounded typed documents** use `ZON`.
2. **Append-only or high-volume records** use versioned binary frames.
3. **Opaque payloads** keep their native format when they are already the
   canonical replay/input bytes.

That yields:

| Artifact class | Canonical encoding | Why |
| --- | --- | --- |
| Reviewable bounded metadata | `ZON` | direct mapping to Zig structs, explicit schema ownership, no custom JSON shape drift |
| Append-only histories and event streams | framed binary | smaller, faster, easier to bound, avoids text parsing on hot paths |
| Replay bytes and payload mirrors | binary | already canonical and replay-oriented |
| Raw captured process output | plain text | preserve byte-for-byte debugging payload |

## Target mapping

| Current surface | Target canonical form | Notes |
| --- | --- | --- |
| `baseline.json` | `baseline.zon` | canonical baseline document becomes ZON |
| `history.jsonl` | binary record log | append-only benchmark history should stop using text |
| `manifest.json` | `manifest.zon` | bounded bundle metadata should be typed and Zig-native |
| `violations.json` | `violations.zon` | bounded structured checker output |
| `trace.json` | binary trace/event record | trace volume and future causality work make text a poor canonical format |
| `actions.zon` | optional typed mirror beside `actions.bin` | keep the mirror caller-selected so replay-only users can skip it |
| exploration retained record | binary decision record | make persisted replay cheap and explicit |
| swarm/campaign history | binary record log | needed for resume, sharding, retention, and long-running summaries |

## Internal boundary

Do not scatter ad hoc file writing across `bench/`, `testing/`, `sim/`, and
`swarm_runner`. Add one internal artifact boundary inside `static_testing`,
shaped so it can be extracted later with minimal churn.

Suggested module shape:

```text
packages/static_testing/src/artifact/
  root.zig
  document.zig      // bounded typed document write/read, currently ZON
  record_log.zig    // append-only framed binary records
  versioning.zig    // schema/version helpers
  naming.zig        // stable file names and suffix helpers
```

Design rule:

- feature modules own schemas and business logic;
- artifact helpers own storage framing, version tagging, and file I/O patterns.

This keeps later extraction mechanical instead of requiring semantic rewrites.

## What should not be built

- No built-in format-conversion helpers.
- No promise of JSON compatibility for generated artifacts.
- No requirement that append-only records be human-readable in-place.
- No new package boundary yet.

## Recommended execution order

1. Land the shared artifact boundary in `static_testing`.
2. Migrate benchmark baselines from JSON to ZON.
3. Migrate benchmark history from JSONL to binary record logs.
4. Migrate failure-bundle metadata documents from JSON to ZON.
5. Move retained trace/exploration/swarm records onto shared binary record
   framing.
6. Revisit whether caller-selected `actions.zon` remains valuable once binary
   replay/debug readers are stronger.

## Acceptance standard

The strategy is complete only when:

- `static_testing` no longer treats JSON or JSONL as canonical artifact
  storage;
- bounded documents use `ZON`;
- append-only campaign/history outputs use a shared binary record layer; and
- the storage helpers are isolated enough that a later `static_*` extraction is
  a file-move and import update, not a redesign.
