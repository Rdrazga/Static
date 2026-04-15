# `static_profile` follow-up plan

Scope: counters, hooks, and trace-export instrumentation.

Status: follow-up closed on 2026-03-31. The root `static_core` alias cleanup
and package-owned deterministic integration coverage are landed, so no concrete
package-local follow-up remains today.

## Current posture

- `static_profile` now has direct integration proof for mixed-event export
  shape, hook ordering, repeated same-name counters, and bounded counter-buffer
  lifecycle behavior.
- The public root `static_core` alias has been removed while internal
  implementation use remains package-local.
- Retained export artifacts and instrumentation benchmarks remain trigger-only
  follow-up rather than current active work.

## Open follow-up triggers

- Reopen only if a real export-shape regression needs retained failure
  artifacts.
- Add benchmark work only if downstream review pressure proves instrumentation
  overhead needs durable baselines.
- Revisit the package boundary only if counters, hooks, or trace export start
  exposing broader policy than the package should own.
