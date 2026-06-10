# CLAUDE.md — Goals app (SwiftUI + SwiftData)

The iOS app that wraps `GoalsCore`. See the root `CLAUDE.md` and
`docs/ARCHITECTURE.md` §3–6 for the full picture.

## Project generation

There is **no committed `.xcodeproj`** — it's generated from `App/project.yml`
(XcodeGen). The spec globs `App/Goals`, so new files are picked up
automatically; just re-run `xcodegen generate` after adding files. The
`GoalsCore` package is wired in via `project.yml`'s `packages:` block. Build
settings of note: `SWIFT_STRICT_CONCURRENCY: complete`, iOS 17 deployment
target, Info.plist at `Goals/Resources/Info.plist`, `LLM_PROXY_BASE_URL` pulled
from a git-ignored `Secrets.xcconfig`.

## Structure

- `App/` — `@main GoalsApp`, `AppContainer` (DI / composition root), `Config`,
  `NotificationCoordinator` (notification-action routing).
- `Persistence/` — `SD*` SwiftData models + the `JSON` payload strategy, and the
  repository protocols + `SwiftDataStore`. **This is the only SwiftData-aware
  code.** Everything above speaks `GoalsCore` value types.
- `Services/` — `@MainActor` orchestration: `PlanEngine` (the funnel for all plan
  mutation), `SchedulingCoordinator` (runs Layer 1), `TaskActionService`,
  `CoachService`, `PerformanceService`, `NotificationService`, `LLMClient`,
  `Clock`.
- `ViewModels/` — `@Observable` per-screen view models.
- `Views/` — SwiftUI screens + `Views/Shared/` reusable chat/card components.
- `Resources/` — Info.plist, asset catalog, `Secrets.example.xcconfig`.

## Conventions

- **MVVM-lite.** View models are thin glue; real logic is in `GoalsCore`. No TCA.
- **View models are created lazily** in `.onAppear` (or `.task`) and assigned to
  a `@State private var model: SomeVM?`; they take the container from
  `@Environment(AppContainer.self)`. Follow the existing pattern (see
  `TodayView`, `GoalDetailView`).
- **All persistence/service calls go through `AppContainer`** (`app.store`,
  `app.planEngine`, `app.taskActions`, `app.coach`, `app.scheduling`,
  `app.performance`, `app.notifications`). Don't reach into SwiftData directly
  from a view.
- **Every plan mutation goes through `PlanEngine`** — never mutate a `Plan` and
  call `store.save` from a view model. `PlanEngine.apply(diff:)` re-validates,
  applies, persists, records a `PlanRevision`, and reschedules atomically.
- **Hybrid chat:** any LLM action that changes state renders as a native editable
  card (`ChatArtifact` → `PlanProposalCard` / `PlanDiffCard`), never raw prose.
- **Forgiveness, not shame:** UI uses a gentle palette (`Palette.gentle`, never
  red for misses), "daily minimum" framing, and skip-with-reason. No streaks.

## Recipes

**Add a screen:** new `View` under `Views/<Area>/` + a `@Observable` view model
under `ViewModels/`, wired into `RootView`/`MainTabView`. Re-run
`xcodegen generate`.

**Add a persisted field/entity:** add/modify an `SD*` model + mapping in
`Persistence/SwiftDataModels.swift`, expose via a repository protocol + the
`SwiftDataStore` impl in `Repositories.swift`, register new models in
`AppSchema.models`. Prefer adding to a value type's JSON payload over a new
column unless you need to query/sort on it.

**Add an iOS integration (EventKit/HealthKit/Widgets):** new service in
`Services/` behind a small protocol; feed the scheduler via
`Scheduler.Input.busyByDay` for calendar, or derived facts only (never raw Health
data) per the privacy rule. See `docs/STATUS.md` backlog.

## Gotchas (unverified — first Mac build will surface real issues)

- SwiftData `#Predicate` expressions in `Repositories.swift` are the most likely
  compile suspects.
- `@Observable` view models stored in `@State?` rely on body reading their
  properties for observation — keep that pattern.
- The app runs fully offline on `MockLLMService`; only set `Secrets.xcconfig` when
  you want the live proxy.
