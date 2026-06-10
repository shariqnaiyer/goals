# Status & Next Work

The honest state of the project and a prioritised backlog. **Start here to pick
up work.** Maps to the phases in `PLAN.md` §8.

Last updated: initial build (authored without a compiler — see the warning
below). Keep this file current as you verify and extend.

---

## ⚠️ Reality check: nothing has been compiled

This codebase was written in a Linux container with **no Swift toolchain and no
Xcode**. It has never been compiled or run. The structure is complete and
internally consistent, and the pure domain layer is written to be testable, but
expect to fix compiler issues on the first Mac build.

**First session on a Mac should:**
1. `cd Packages/GoalsCore && swift test` — fix any failures here first; this
   layer has no Apple-UI dependencies and is the foundation.
2. `cd App && xcodegen generate && open Goals.xcodeproj` — build for an iOS 17
   simulator, fix compile errors, run.
3. `cd proxy && npm install && npm run typecheck`.
4. Update the "Verified" column below as you go.

Most-likely problem spots (no compiler caught these):
- SwiftData `#Predicate` expressions in `Repositories.swift` (UUID/String/Int
  comparisons, compound predicates).
- `@Observable` / `@Bindable` usage and observation in view bodies.
- `Substring` vs `String` seams (mostly defended against, but verify).
- `ModelContainer`/`Schema` construction from `AppSchema.models`.
- Notification delegate isolation (`NotificationCoordinator`).

---

## Implemented (Phase 0 + most of Phase 1)

| Area | What exists | Verified? |
|---|---|---|
| Domain models | All value types, timezone-stable time model | ✋ tests written, not run |
| Scheduler (Layer 1) | Availability + greedy placement + overcommit signal | ✋ tests written, not run |
| Plan validation/mutation | `PlanValidator`, `PlanMutator` | ✋ tests written, not run |
| Performance analysis | `PerformanceAnalyzer`, snapshots, miss streaks | ✋ tests written, not run |
| Adaptation triggers | `AdaptationPolicy` (deterministic gating) | ✋ |
| LLM contracts | `GoalSpec` / `PlanProposal` / `PlanDiff` schemas | ✋ |
| Replan loop | `ReplanService` validate-and-retry | ✋ tests written, not run |
| Offline LLM | `MockLLMService` (deterministic) | ✋ |
| Persistence | SwiftData models + repository seam | ✋ |
| Services | PlanEngine, SchedulingCoordinator, Task/Coach/Perf/Notification | ✋ |
| LLM networking | `LLMClient` + decode-repair round-trip | ✋ |
| Onboarding UI | Interview chat + editable proposal card | ✋ |
| Today UI | List, complete/skip/snooze, forgiving progress, adaptation prompt | ✋ |
| Goals UI | List, detail, milestones, plan history, lifecycle, adaptation | ✋ |
| Coach UI | Chat with inline diff cards | ✋ |
| Weekly review UI | Sheet with narrative + diff | ✋ |
| Settings UI | Constraints editor, privacy, export, erase | ✋ |
| Notifications | Local digest + per-task reminders + Done/Snooze | ✋ |
| Proxy | Cloudflare Worker, versioned prompts, structured output | ✋ typecheck not run |

Legend: ✅ verified · ✋ written but unverified · ⛔ broken/known-bad.

---

## Stubbed (intentional placeholders)

- **App Attest / device auth** — `DeviceAttestation.token()` returns `nil`
  (`AppContainer.swift`). The proxy accepts unauthenticated requests. Real
  attestation is a production TODO.
- **Proxy auth / rate limiting / subscription metering** — commented TODOs in
  `proxy/src/index.ts`. No StoreKit yet.
- **App icon** — `AppIcon.appiconset` has the metadata slot but no image asset.
- **Eval suite** — the plan calls for a recorded-scenario regression suite for
  prompts/diffs (Phase 0). The `GoalsCoreTests` cover the deterministic engine;
  the prompt-quality eval harness is not built.

---

## Explicitly NOT built yet (deferred per PLAN.md §8)

**Phase 1 finish / hardening**
- Multiple simultaneous active goals are *supported by the engine* but the v1 UX
  doesn't surface cross-goal load balancing in the scheduler (each goal schedules
  independently; `SchedulingCoordinator.rescheduleAll` loops per goal).
- Auto-adaptation triggers fire on skip (Today) and weekly review; a background
  task to proactively detect overcommitment between sessions is not wired.
- No CI; no `.xcodeproj` committed (regenerated from `project.yml`).

**Phase 2**
- EventKit (calendar busy intervals feed the scheduler — `BusyInterval` /
  `busyByDay` plumbing exists in `Scheduler`, but nothing populates it yet).
- WidgetKit (next task / today progress, interactive complete).
- Subscription + paywall (StoreKit 2).

**Phase 3**
- HealthKit (sleep to learn real bedtime; workouts to auto-complete).
- CloudKit sync + Sign in with Apple.
- App Intents / Siri / Shortcuts.
- On-device model tier (Apple Foundation Models) + offline coach fallback.
- Live Activities.

**Permanent cuts** (don't add): streaks/gamification (conflicts with the
forgiveness principle), social features.

---

## Prioritised backlog (pick from the top)

1. **Make it build.** `swift test` green, then Xcode build + run on simulator.
   Fix the likely-suspect list above. Update the Verified column.
2. **Add an app icon** so it installs cleanly.
3. **Wire a SessionStart hook / CI** so future web sessions can run
   `swift test` automatically (there's a `session-start-hook` skill for this).
4. **Eval harness for prompts** (Phase 0 debt): record onboarding transcripts +
   replan scenarios with golden `PlanDiff` outputs; assert validator pass-rate.
   Highest leverage for plan quality.
5. **EventKit read integration** (Phase 2): request permission contextually,
   convert events to `BusyInterval`s, populate `Scheduler.Input.busyByDay` in
   `SchedulingCoordinator`. The scheduler already consumes busy intervals and has
   a test for it (`testCalendarBusyIntervalsBlockPlacement`).
6. **Interactive widget** (Phase 2): a `WidgetKit` extension reading today's
   occurrences (reuse `ScheduleRepository`), with an interactive complete button.
7. **Cross-goal load balancing**: have `SchedulingCoordinator` schedule all active
   goals against one shared daily budget rather than per-goal.
8. **Background refresh**: a `BGAppRefreshTask` that re-runs `rescheduleAll` and
   re-evaluates `AdaptationPolicy`, surfacing proactive prompts.
9. **StoreKit 2 paywall + proxy metering** (Phase 2 monetisation).
10. **App Attest** end-to-end with proxy verification (privacy/abuse).

---

## Risks & things to watch (from PLAN.md §9)

- **LLM cost per active user** — mitigated by diffs-not-rewrites and zero-API
  daily scheduling; measure tokens/user/week before pricing.
- **Onboarding latency** — stream responses; the proxy uses `effort: "medium"`.
- **Plan quality variance** — the missing eval suite is the real control; plan
  history is the trust backstop.
- **Notification fatigue** — keep the ~3/day cap and adaptive frequency.
- **SwiftData maturity** — the repository seam contains the blast radius; if
  CloudKit sync forces awkward constraints, the payload-column strategy or a GRDB
  swap is the escape hatch.

---

## Open product questions (don't block engineering)

Pricing/trial length; coach personality (one voice vs configurable); goal
templates vs pure generation; iPad/Mac; whether the weekly review interrupts.
See `PLAN.md` §9.
