# CLAUDE.md — GoalsCore (pure domain layer)

The heart of the app: value-type models, the deterministic scheduler, plan
validation/mutation, performance analysis, adaptation policy, and the LLM
contracts + orchestration. See the root `CLAUDE.md` and `docs/ARCHITECTURE.md`
§2 for context.

## The cardinal rule

**This package must not import `SwiftUI`, `SwiftData`, `UIKit`, or any
Apple-platform-only framework.** Only `Foundation`. That purity is why it
compiles and tests on Linux, runs identically in tests and the app, and is the
trustworthy foundation everything else sits on. If you reach for persistence or
UI here, you're in the wrong layer — move it to `App/Goals/`.

## Run the tests

```sh
swift test                 # from this directory
```

Tests use a fixed UTC calendar and fixed dates (`Tests/.../TestSupport.swift`,
`Fixtures`) for determinism. **New domain logic ⇒ a new test.** The tests are the
executable spec for this layer.

## Layout

- `Sources/GoalsCore/Models/` — value types. Time model (`Weekday`,
  `MinuteWindow`, `CalendarDay`) is timezone-stable by design; don't introduce
  UTC `Date` instants for scheduling.
- `Sources/GoalsCore/Schemas/` — `GoalSpec` / `PlanProposal` / `PlanDiff`: the
  `Codable` contracts the LLM fills. Keep them close to plain English (reliable
  generation) and machine-validated.
- `Sources/GoalsCore/Scheduling/` — `Availability` + `Scheduler` (Layer 1). Pure
  functions over value types.
- `Sources/GoalsCore/Planning/` — `PlanValidator`, `PlanMutator`,
  `PerformanceAnalyzer`, `AdaptationPolicy`.
- `Sources/GoalsCore/LLM/` — `LLMService` protocol, `ReplanService` (validate +
  retry loop), `MockLLMService` (deterministic offline conformance),
  `PromptVersion`.

## Invariants enforced here

- The LLM emits **operations against a plan** (`PlanDiff`), never datetimes.
- `PlanValidator` is the guardrail: a diff that fails validation is never
  applied. Add validation for any new `PlanOperation.Kind`.
- `PlanMutator` only mutates the **intent** layer (goal/milestones/templates).
  Never touch `TaskOccurrence` history here.
- Soft-deactivate (`isActive = false`) instead of deleting templates, for
  reversibility from plan history.

## Recipes

**New `PlanOperation` kind:** add the `case` in `Schemas/PlanDiff.swift` →
handle in `Planning/PlanMutator.swift` → validate in `Planning/PlanValidator.swift`
→ have `LLM/MockLLMService.swift` emit it where sensible → add a test in
`Tests/.../PlanningTests.swift`. Also update the proxy schema (`proxy/src/prompts.ts`).

**New scheduling behaviour:** edit `Scheduling/Scheduler.swift` /
`Availability.swift`, add a `SchedulerTests` case. Iterate entirely via
`swift test` — no app needed.

**New LLM method:** add to the `LLMService` protocol, implement in
`MockLLMService`, add the networking side in `App/Goals/Services/LLMClient.swift`
and the prompt/schema in `proxy/src/prompts.ts`.
