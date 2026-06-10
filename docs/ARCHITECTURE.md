# Architecture

How the code is organised, how data flows through it, and why. Read `CLAUDE.md`
first for the high-level map and invariants; this document is the detailed
reference. Product reasoning lives in `PLAN.md`.

---

## 1. Layering & dependency direction

```
┌───────────────────────────────────────────────────────────────┐
│ Views (SwiftUI)            App/Goals/Views/**                   │
│   read @Observable VMs, render, dispatch user intents          │
├───────────────────────────────────────────────────────────────┤
│ ViewModels (@Observable)   App/Goals/ViewModels/**             │
│   per-screen state; call services; expose display data         │
├───────────────────────────────────────────────────────────────┤
│ Services (@MainActor)      App/Goals/Services/**               │
│   PlanEngine, SchedulingCoordinator, TaskActionService,        │
│   CoachService, PerformanceService, NotificationService,       │
│   LLMClient, Clock                                             │
├───────────────────────────────────────────────────────────────┤
│ Repositories (protocols)   App/Goals/Persistence/             │
│   GoalRepository, ScheduleRepository, ChatRepository,          │
│   RevisionRepository, ConstraintRepository, AppStateRepository │
│   └ impl: SwiftDataStore (the only SwiftData-aware code)       │
├───────────────────────────────────────────────────────────────┤
│ Domain (pure)              Packages/GoalsCore/**               │
│   value-type models, Scheduler, PlanValidator/Mutator,         │
│   PerformanceAnalyzer, AdaptationPolicy, ReplanService,        │
│   LLMService protocol + MockLLMService, structured schemas     │
└───────────────────────────────────────────────────────────────┘
        │                                   │
   SwiftData (on-device)            LLM proxy (proxy/) → Anthropic API
   behind repository seam           behind LLMService seam
```

Rule: a layer may depend only on the layers below it. `GoalsCore` depends on
nothing Apple-UI-specific, so it is the foundation and is independently
testable.

Two seams make the two external dependencies swappable:
- **Repository seam** — `App/Goals/Persistence/Repositories.swift` defines
  protocols in terms of `GoalsCore` value types; `SwiftDataStore` is the only
  implementation. Swapping to GRDB/SQLite later is contained here.
- **LLM seam** — `LLMService` (in `GoalsCore/LLM/LLMService.swift`) abstracts the
  model. `LLMClient` networks to the proxy; `MockLLMService` is deterministic and
  offline. The app picks one in `AppContainer.init` based on `Config`.

---

## 2. The pure domain layer (`GoalsCore`)

Compiles and unit-tests on any platform. No `import SwiftUI/SwiftData/UIKit`.

### Models (`Sources/GoalsCore/Models/`)
- **`Time.swift`** — `Weekday` (String-raw enum, ISO ordering, `.shortName`,
  `calendarWeekday` bridge), `MinuteWindow` (half-open `[start,end)` minutes from
  midnight, with `overlaps`/`subtracting`), `CalendarDay` (y/m/d, timezone-stable).
  These two types are why scheduling never stores UTC instants.
- **`Recurrence.swift`** — `RecurrenceRule` (`specificWeekdays` /
  `timesPerWeek` / `everyNDays` / `once`) + `occurrencesPerWeek` for budgeting.
- **`Entities.swift`** — `Goal` (+`GoalType`/`GoalStatus`), `Milestone`,
  `TaskTemplate` (+`Flexibility`, `minimumViableVariant`, `weeklyLoadMinutes`),
  `TaskOccurrence` (+`OccurrenceStatus`), `ConstraintProfile`
  (work hours + wake/bedtime minutes + blackout days + `maxDailyTaskMinutes`,
  with `awakeWindow(_:)`).
- **`Plan.swift`** — `Plan` aggregate (goal + milestones + templates); the unit
  the validator/mutator/scheduler operate on. `weeklyLoadMinutes`,
  `activeTemplates`, lookups.
- **`Performance.swift`** — `TimeOfDay` bucket, `TemplatePerformance`,
  `PerformanceSnapshot` (`overallCompletionRate`, `isOverBudget`,
  `strugglingTemplates(threshold:)`). The only behavioural aggregate sent to the
  LLM.
- **`Chat.swift`** — `ChatMessage` (+`ChatRole`, `ChatArtifact` enum for native
  cards), `PlanRevision` (+`RevisionTrigger`) — the plan-history audit record.

### Structured schemas (`Sources/GoalsCore/Schemas/`)
The typed boundary between the LLM and the engine. All `Codable`.
- **`GoalSpec`** — onboarding interview result (title, type, criteria,
  target date, weekly budget, `isComplete`, `nextQuestion`).
- **`PlanProposal`** — milestones + task templates with a `materialise(spec:…)`
  that mints real UUIDs and resolves milestone keys → IDs, producing a `Plan`.
- **`PlanDiff`** — `summary` + `[PlanOperation]` (+ optional
  `clarifyingQuestion`/`clarifyingChoices`). `PlanOperation` is a **flat struct
  with a `kind` discriminator** (not a Swift enum with associated values) because
  a single object shape is far more reliable for schema-constrained generation
  and trivial to validate field-by-field. A custom `init(from:)` tolerates the
  model omitting `id`.

### Scheduling (Layer 1, `Sources/GoalsCore/Scheduling/`)
- **`Availability.swift`** — `freeWindows(day:…)`: awake span − work − calendar
  busy, `[]` on blackout days. Pure.
- **`Scheduler.swift`** — expands active templates into desired demands across
  the horizon (handling each cadence + `timesPerWeek` load-smoothing across the
  week), then **greedily places** them: fixed tasks first, then larger effort
  first; honours preferred windows / historical best time; caps at
  `maxDailyTaskMinutes`; carves placed slots out of remaining free time. Unplaceable
  demand → `OvercommitSignal` (reasons: `noFreeWindow` / `dailyCapReached` /
  `blackout`). Greedy, not an optimiser — explainability beats optimality at this
  problem size.

### Planning (`Sources/GoalsCore/Planning/`)
- **`PlanValidator.swift`** — semantic validation of a `PlanDiff` against a `Plan`
  + `ConstraintProfile`: references resolve, effort/frequency in range, reorder is
  a true permutation, resulting weekly load within budget (+15% grace),
  question-only diffs always valid. Returns `[Violation]`.
- **`PlanMutator.swift`** — applies a (validated) `PlanDiff` to a `Plan`, purely.
  Only the intent layer (goal/milestones/templates) changes; occurrences are
  untouched. Remove/pause soft-deactivate (`isActive = false`) for reversibility.
- **`PerformanceAnalyzer.swift`** — builds a `PerformanceSnapshot` from raw
  occurrences (completion rate, miss streak, modal best time-of-day, avg
  difficulty) and `bestTimeHints(from:)` for the scheduler. The only place raw
  history is read.
- **`AdaptationPolicy.swift`** — deterministic *trigger* rules: returns the
  highest-priority `RevisionTrigger` (`overcommitted` > `missedTasks` > none) and
  `isWeeklyReviewDue`. Gates the expensive LLM call with cheap logic.

### LLM (`Sources/GoalsCore/LLM/`)
- **`LLMService.swift`** — the protocol (`interview`, `generatePlan`, `replan`,
  `coachTurn`, `reviewNarrative`) + `InterviewResult`/`CoachReply`/`LLMError` +
  `PromptVersion` constants (pinned, surfaced to the proxy & eval suite).
- **`ReplanService.swift`** — the **validate-and-retry loop**: ask for a
  `PlanDiff`, validate it, on failure feed the violation list back (≤ `maxRetries`),
  else return the diff + preview plan. Pure of network/UI; depends only on the
  protocol + validator, so it's fully unit-tested with a mock.
- **`MockLLMService.swift`** — deterministic, offline conformance. Keyword
  heuristics produce plausible specs/plans/diffs/coach replies so the whole app
  runs with no backend, and the test suite has a stable oracle.

---

## 3. Persistence

`App/Goals/Persistence/`.

**Strategy: queryable columns + a JSON payload.** Each `SD*` `@Model` class
stores a few indexable columns (id, goalID, status, dayKey, timestamps) plus a
`Data` `payload` that is the JSON of the corresponding `GoalsCore` value type.
The repositories map `SD* ↔ domain struct`. This is deliberate: it keeps the
domain layer the single source of truth, sidesteps SwiftData's evolving handling
of nested value types, and is reliable without fighting macro codegen we can't
unit-test. Trade-off: id/status are duplicated inside the payload.

- **`SwiftDataModels.swift`** — the `SD*` classes, `DayKey` (sortable
  `yyyymmdd` Int), the shared `JSON` coder (ISO dates), and `AppSchema.models`
  (the list passed to `ModelContainer`).
- **`Repositories.swift`** — the protocols and the single `SwiftDataStore`
  implementation (a `@MainActor` class over a `ModelContext`). `save(plan:)`
  replaces the goal's milestones/templates wholesale (small sets, simplest
  correct path). `deletePending(goalID:from:)` clears future pending occurrences
  before a reschedule.

To add an entity: new `SD*` class → mapping → repository method(s) → register in
`AppSchema.models`.

---

## 4. Services (orchestration)

`App/Goals/Services/`. All `@MainActor`.

- **`Clock.swift`** — injectable `now`/`calendar`/`today` so scheduling and
  adaptation are deterministic in tests.
- **`PlanEngine.swift`** — the orchestrator. Every plan mutation flows through
  here: `createGoal(from spec:)` (generate → materialise → persist → record
  initial revision → schedule), `proposeRevision` (delegates to `ReplanService`),
  `apply(diff:)` (re-validate → `PlanMutator` → persist → record → reschedule),
  `recordRejected`, and lifecycle `setStatus`.
- **`SchedulingCoordinator.swift`** — runs Layer 1 for a goal: gathers profile +
  best-time hints + existing done occurrences (as busy intervals), clears future
  pending, runs `Scheduler`, upserts occurrences, refreshes notifications.
- **`TaskActionService.swift`** — complete / skip / snooze; after a skip it
  re-checks `AdaptationPolicy` and returns a trigger if a struggle threshold was
  crossed (drives the gentle Today-screen replan prompt).
- **`PerformanceService.swift`** — builds a `PerformanceSnapshot` for a plan over
  a lookback window via `PerformanceAnalyzer`.
- **`CoachService.swift`** — chat turns: persists the user message, calls
  `llm.coachTurn` with only the relevant goal summary + snapshot + history,
  persists the assistant reply (with an optional `planDiff` artifact).
- **`NotificationService.swift`** — local `UserNotifications` only: a morning
  digest + ≤ 2 per-task reminders/day (hard cap ~3), Done/Snooze actions. Gentle
  by design (notification fatigue is the #1 churn risk).
- **`LLMClient.swift`** — the networking `LLMService`. Wraps each call in an
  envelope `{ task, promptVersion, schemaVersion, repair, payload }`, decodes
  `{ result }`, and on a decode failure does one **repair round-trip** (asks the
  proxy to re-emit valid JSON) before surfacing an error.

---

## 5. Composition root & app entry

- **`App/Goals/App/Config.swift`** — reads `LLMProxyBaseURL` from Info.plist
  (injected via `Secrets.xcconfig`); empty ⇒ offline mock.
- **`AppContainer.swift`** — `@MainActor @Observable` DI root. Constructs the
  store, services, and the chosen `LLMService`. `bootstrap()` seeds a default
  constraint profile, registers notification categories, and reschedules all
  active goals. `DeviceAttestation.token()` is the App Attest stub.
- **`GoalsApp.swift`** — `@main`. Builds the `ModelContainer` (falls back to an
  in-memory store if the on-disk store is corrupt, so a bad store never bricks
  launch), injects `AppContainer` into the environment, and on first launch wires
  `NotificationCoordinator` (the `UNUserNotificationCenterDelegate` that routes
  Done/Snooze actions back into `TaskActionService`).

---

## 6. View layer

`App/Goals/Views/`. SwiftUI, iOS 17 (`@Observable`, interactive widgets-ready,
`ContentUnavailableView`, modern `onChange`).

- **`RootView.swift`** — onboarding gate → `MainTabView` (Today / Goals / Coach /
  Settings). The weekly review is a *sheet* surfaced when due, not a tab.
- **Onboarding** — `OnboardingView` drives the interview chat and renders the
  editable `PlanProposalCard`.
- **Today** — `TodayView`: today/tomorrow occurrences, forgiving progress header,
  swipe complete/skip/snooze, skip-with-reason dialog, and the
  `AdaptationPromptSheet` after repeated misses.
- **Goals** — `GoalsListView` (cards + new-goal flow) and `GoalDetailView`
  (milestones, upcoming, **plan history**, lifecycle, and `GoalAdaptationView`
  which previews/accepts a proposed diff).
- **Coach** — `CoachView`: the chat; coach-proposed diffs render as inline
  `PlanDiffCard`s the user applies.
- **Review** — `WeeklyReviewView`: per-goal narrative + optional diff.
- **Settings** — `SettingsView` + `ConstraintEditorView`: per-weekday wake/sleep
  + work, notifications, the privacy disclosure, JSON export, erase-all.
- **Shared** — `ChatComponents` (bubble, composer, auto-scroll), `PlanCards`
  (proposal card, editable template row/editor, diff card, choice chips),
  `Formatting`, `DesignSystem` (calm palette, `.card()`, typing indicator).

The **hybrid-chat** rule: every LLM action that changes state renders as a
native editable card (`ChatArtifact`), never raw prose.

---

## 7. Data-flow walkthroughs

### A. Onboarding → first plan
1. `OnboardingViewModel.send` appends the user turn, calls
   `llm.interview(history:draft:)`, shows the assistant reply, updates the draft
   `GoalSpec`.
2. When `spec.isComplete`, it calls `llm.generatePlan(spec:profile:)` →
   `PlanProposal`, materialises an editable `Plan`, renders `PlanProposalCard`.
3. User edits inline (effort/frequency, remove a task) → mutates `editablePlan`.
4. `accept()` saves the constraint draft, calls
   `PlanEngine.createGoal(fromEdited:)` (persist + initial `PlanRevision` +
   `SchedulingCoordinator.reschedule`), requests notification permission, marks
   onboarding complete.

### B. Completing / skipping a task
1. `TodayView` → `TodayViewModel.complete/skip/snooze` → `TaskActionService`.
2. Complete sets `status=.done`, `completedAt`, optional difficulty; persists.
3. Skip records a reason, then `adaptationTrigger(for:)` runs `AdaptationPolicy`
   over a fresh snapshot; a non-nil trigger sets `adaptationPrompt`, surfacing the
   gentle "want to make this lighter?" sheet → `GoalAdaptationView`.

### C. A replan (Layer 2)
1. Trigger source: weekly review, 3 consecutive misses, an overcommit signal, a
   goal edit, or an explicit chat/"adjust" request.
2. `PlanEngine.proposeRevision` builds a `PerformanceSnapshot` and calls
   `ReplanService.proposeRevision`, which loops: `llm.replan` →
   `PlanValidator.validate` → (retry with violations) → valid `PlanDiff` +
   preview `Plan`.
3. UI shows the diff as a card (`PlanDiffCard`). On accept,
   `PlanEngine.apply(diff:)` re-validates, applies via `PlanMutator`, persists,
   records an accepted `PlanRevision`, and `SchedulingCoordinator.reschedule`
   re-places the revised templates. On reject, a rejected revision is recorded
   (kept as signal in plan history).

---

## 8. Concurrency model

- Swift 6 strict concurrency (`SWIFT_STRICT_CONCURRENCY: complete`).
- SwiftUI `App`/`Scene`/`View` are `@MainActor`, so `GoalsApp.init`,
  `AppContainer` construction, and all view bodies are main-actor isolated.
- Repositories and services that touch SwiftData/UI are `@MainActor`.
- `GoalsCore` is `Sendable` value types and pure functions; `LLMService` is a
  `Sendable` protocol; the concrete clients are `Sendable` structs.
- LLM calls are `async`; UI uses `Task { await … }` from view models.

---

## 9. The LLM proxy

`proxy/` — a stateless Cloudflare Worker (TypeScript, raw `fetch`, no SDK). It
holds the Anthropic key, pins versioned prompts + JSON schemas
(`src/prompts.ts`), forces schema-valid output via single-tool `tool_choice`
(model `claude-opus-4-8`, adaptive thinking), and returns the `{ result }`
envelope `LLMClient` decodes. It stores nothing. Auth (App Attest), rate
limiting, and subscription metering are stubbed TODOs. See `proxy/CLAUDE.md`.

---

## 10. Known gaps & where the bodies are buried

See `docs/STATUS.md` for the full list. The headline: **nothing here has been
compiled** — the first Mac build will surface issues a compiler would have
caught. Likely suspects to check first: SwiftData `#Predicate` expressions,
`@Observable`/`@Bindable` usage in view bodies, and any `Substring`/`String`
seams. The pure `GoalsCore` package is the most trustworthy part (and the
easiest to verify: `swift test`).
