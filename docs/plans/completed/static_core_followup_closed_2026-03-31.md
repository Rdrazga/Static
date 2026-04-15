# `static_core` follow-up plan

Scope: shared error vocabulary, config validation, and base contracts.

Status: follow-up closed on 2026-03-31. The 2026-03-24 sweep found no concrete
package-local debt, so the package returns to monitor-only status.

## Current posture

- `static_core` already has direct package-level negative-contract coverage for
  config, options, error vocabulary, and time-budget behavior.
- The package remains a poor fit for heavier shared harness work unless a real
  replayable invalid-config bug or justified hot helper appears.
- No concrete unfinished package-local follow-up remains from the current
  sweep.

## Open follow-up triggers

- Reopen only if the shared vocabulary or config boundary starts broadening
  again.
- Add retained replay or failure-bundle work only if repeated invalid-config
  reproducers appear.
- Add benchmark work only if a core helper becomes hot enough to justify a
  durable review artifact.
