# `static_testing` repair and liveness execution sketch

## Goal

Add a reusable deterministic execution mode that can:

- run a scenario under a fault-heavy or adversarial phase;
- transition the scenario into a repair profile;
- continue running under separate convergence budgets; and
- report typed pending reasons when the system fails to settle.

This is the missing reusable concept surfaced by the TigerBeetle VOPR
comparison. The package already supports deterministic swarm campaigns,
simulation fixtures, and retained artifacts, but it does not yet offer a
first-class "heal and prove convergence" contract.

## Why this belongs in `static_testing`

- Recovery behavior is a core invariant for many distributed, queue-heavy,
  timeout-heavy, and process-boundary systems.
- Downstream users should not have to build their own local "fault phase then
  repair phase" harness on top of `testing.system`, `testing.sim`, or
  `testing.swarm_runner`.
- This fits the library boundary as long as the repair phase remains bounded,
  deterministic, and caller-owned.

## Design posture

- Keep the concept generic: this is not consensus-specific liveness logic.
- Separate execution phases explicitly instead of burying repair behavior in a
  scenario-specific callback.
- Make convergence failure diagnosable with typed pending reasons, not only a
  generic timeout.
- Reuse existing run identity, failure bundles, provenance, and swarm/system
  reporting surfaces rather than inventing a parallel artifact path.

## Proposed vocabulary

### Execution phases

- `fault_phase`: normal adversarial execution where failures, faults, and
  partitions may still be active.
- `repair_phase`: deterministic healing profile where the scenario can disable
  or reduce certain faults and the harness checks whether the system settles.

### Core types

- `RepairLivenessConfig`
  - `fault_phase_steps_max`
  - `repair_phase_steps_max`
  - `stop_on_safety_failure`
  - `record_pending_reason`
- `PendingReason`
  - typed convergence blockers such as `inflight_request`,
    `scheduled_timer_remaining`, `mailbox_not_empty`,
    `work_queue_not_empty`, `node_unrecovered`, `reply_sequence_gap`,
    `custom`
- `PendingReasonDetail`
  - reason code plus optional small numeric metadata and label
- `RepairProfile`
  - a caller-owned profile describing how the scenario should heal, for example
    clear partitions, disable injected corruption, resume paused nodes, or
    advance to a low-fault clock/network/storage policy
- `LivenessSummary`
  - fault-phase result
  - repair-phase result
  - whether convergence succeeded
  - final pending reasons if it did not

### Callback shape

Possible callback split:

- `run_fault_phase(input) -> ScenarioExecution`
- `transition_to_repair(context, profile) -> void`
- `pending_reason(context) -> ?PendingReasonDetail`

The key is that transition and pending inspection should be explicit contracts,
not inferred from a free-form scenario result.

## Likely ownership

Most likely placement is one of:

1. A small reusable helper under `testing.sim` or `testing.system` that owns
   the phase split and pending-reason contract.
2. A thin lower-level helper used by `testing.swarm_runner` and
   `testing.system`, so campaign orchestration and direct system runs can share
   the same repair/liveness semantics.

The runner should probably not own all of this by itself because direct
non-swarm deterministic system tests may also need the same capability.

## Reporting and artifact expectations

- Progress and summary output should report separate fault-phase and
  repair-phase budgets.
- Failure bundles should persist whether failure happened during the fault
  phase or the repair phase.
- Repair-phase convergence failures should retain typed pending reasons and any
  trace/provenance data already supported by the current artifact system.

## Non-goals

- No theorem proving or unbounded liveness proof engine.
- No distributed-system-specific quorum semantics in the core helper.
- No hosted orchestration or autonomous retry control plane.
- No package-specific "repair profile" policy hardcoded in the library.

## Implementation slices

### Slice 1: phase contract

- Define execution-phase vocabulary.
- Define `PendingReason` and summary shape.
- Add one package-owned example with a simple simulated subsystem that fails to
  converge until repair is applied.

### Slice 2: shared helper

- Add one reusable bounded helper for fault-phase then repair-phase execution.
- Reuse failure bundles and provenance surfaces.
- Add stable plain-text summary formatting.

### Slice 3: downstream proof

- Move one downstream package adopter onto the new contract.
- Prefer a package with real queueing, timers, or process recovery pressure.

## Early decision questions

- Should pending reasons be a closed core enum with `custom`, or fully
  scenario-defined?
- Should repair/liveness execution live closer to `testing.system`,
  `testing.sim`, or as a shared lower-level helper?
- Should swarm summaries always include repair-phase results, or only when a
  scenario opts into the contract?
