# Status & Next Work

The honest state of the project and a prioritised backlog. **Start here to pick
up work.** Maps to the phases in `PLAN.md` §8.

Last updated: first Mac build — **the project now compiles and runs**
(Xcode 26.4 / Swift 6.3, iPhone 17 Pro simulator). Keep this file current as you
verify and extend.

---

## ✅ Reality check: it now compiles and runs

This codebase was originally written in a Linux container with no Swift toolchain
and had never been compiled. As of the first Mac build it is green:

- `cd Packages/GoalsCore && swift test` → **29 tests pass.**
- `cd App && xcodegen generate && xcodebuild -scheme Goals -destination
  'platform=iOS Simulator,name=iPhone 17 Pro' build` → **build succeeds**; the app
  installs, launches, and runs onboarding on the offline `MockLLMService`.

Five issues the compiler-less author couldn't catch were fixed to get here:
1. `LLMClient.swift` — a generic `Wrapper<T>` was nested inside a generic function
   (illegal); moved to file scope as `ResultWrapper`.
2. `CoachView.swift` — an ambiguous `$0` trailing closure for `onChoose`; named the
   parameter.
3. `GoalDetailView.swift` — an `onChoose` closure returned a `Task` (type mismatch);
   added an explicit `return`.
4. `PlanCards.swift` — `ToolbarItemPlacement.cancelAction` → `.cancellationAction`.
5. `Info.plist` — missing `CFBundleIdentifier`/`CFBundleExecutable`/`CFBundleName`/
   `CFBundlePackageType` (install failed with "Missing bundle ID"); added the
   standard `$(PRODUCT_*)` build-variable keys.

Remaining strict-concurrency **warnings** (not errors) to clean up later:
`UNUserNotificationCenter`/`UNNotification` non-Sendable in the notification
delegate (`GoalsApp.swift`), `UIBarAppearance.configure()` off-MainActor in
`RootView.swift:66`, and SwiftData `#Predicate` `KeyPath`-not-Sendable warnings in
`Repositories.swift`.

**First session on a Mac should:**
1. `cd Packages/GoalsCore && swift test` — fix any failures here first; this
   layer has no Apple-UI dependencies and is the foundation.
2. `cd App && xcodegen generate && open Goals.xcodeproj` — build for an iOS 17
   simulator, fix compile errors, run.
3. `cd proxy && npm install && npm run typecheck`.
4. Update the "Verified" column below as you go.

---

## ✅ Onboarding redesign — implemented (the "Guided Discovery Interview")

The thin 3-turn interview was replaced with a deep, concreteness-driven onboarding
and the IA to match (58 GoalsCore tests pass; app builds + runs on the simulator).

- **Concrete objects** — `GoalSpecifics` (reading: book + chapters; fitness:
  program + routines/sets×reps; generic: ordered units), opaque to the Scheduler.
  A post-scheduler `Sequencer` stamps "Chapter N" / "Workout A" onto sessions.
- **The interview** — `OnboardingState`/`PersonSketch`/`AspirationDraft` +
  `onboardingTurn` (replaces `interview`). Swift-owned stages
  (ground → surface → concretize → confirm → formalize); the deterministic
  `ConcretenessCheck` gate (not the model) decides when a goal is concrete and
  enforces a weekly-capacity cap across the 1–3 chosen goals. `MockLLMService` is
  the offline stage machine; the proxy `onboardingTurn` mirrors it.
- **IA** — Settings → **You** (the learned `UserProfile`); `GoalDetailView`
  "Where you are" (chapters / routines); Today shows the concrete slice + a
  `TaskDetailSheet`; Goals groups by horizon + surfaces backlog; add-goal "+"
  enters mid-flow. `markUnitComplete` checks off chapters via `PlanEngine`.
- **Follow-ups:** the deployed proxy still serves the old `interview` task — run
  `cd proxy && npm run deploy` for the live coach, or use the mock
  (`LLM_PROXY_BASE_URL=""`). The weekly-review sheet auto-presents on fresh
  installs and wants a gentler gate.

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
| Domain models | All value types, timezone-stable time model | ✅ 29 tests pass |
| Scheduler (Layer 1) | Availability + greedy placement + overcommit signal | ✅ 29 tests pass |
| Plan validation/mutation | `PlanValidator`, `PlanMutator` | ✅ 29 tests pass |
| Performance analysis | `PerformanceAnalyzer`, snapshots, miss streaks | ✅ 29 tests pass |
| Adaptation triggers | `AdaptationPolicy` (deterministic gating) | ✋ |
| LLM contracts | `GoalSpec` / `PlanProposal` / `PlanDiff` schemas | ✋ |
| Replan loop | `ReplanService` validate-and-retry | ✅ 29 tests pass |
| Offline LLM | `MockLLMService` (deterministic) | ✋ |
| Persistence | SwiftData models + repository seam | ✋ |
| Services | PlanEngine, SchedulingCoordinator, Task/Coach/Perf/Notification | ✋ |
| LLM networking | `LLMClient` + decode-repair round-trip | ✋ |
| Onboarding UI | Interview chat + editable proposal card | ✅ builds + runs |
| Today UI | List, complete/skip/snooze, forgiving progress, adaptation prompt | ✋ |
| Goals UI | List, detail, milestones, plan history, lifecycle, adaptation | ✋ |
| Coach UI | Chat with inline diff cards | ✋ |
| Weekly review UI | Sheet with narrative + diff | ✋ |
| Settings UI | Constraints editor, privacy, export, erase | ✋ |
| Notifications | Local digest + per-task reminders + Done/Snooze | ✋ |
| Proxy | Cloudflare Worker, versioned prompts, structured output | ✋ typecheck not run |
| Design system | Warm-paper + pine-teal tokens, components, all screens restyled, Welcome flow | ✋ |

Legend: ✅ verified · ✋ written but unverified · ⛔ broken/known-bad.

---

## Stubbed (intentional placeholders)

- **App Attest / device auth** — `DeviceAttestation.token()` returns `nil`
  (`AppContainer.swift`). The proxy accepts unauthenticated requests. Real
  attestation is a production TODO.
- **Proxy auth / rate limiting / subscription metering** — commented TODOs in
  `proxy/src/index.ts`. No StoreKit yet.
- **App icon** — `AppIcon.appiconset` has the metadata slot but no rasterised
  image yet. The brand mark is drawn in-app (`BrandMark`) and the icon artwork is
  specified in the design system (warm-paper square + pine-teal concentric rings,
  `#3B7A6B`); export a 1024² PNG from that and drop it in.
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
