# CLAUDE.md — Goals

Guidance for Claude Code (and humans) working in this repository. Read this
first. It is the map; the deep dives are in `docs/ARCHITECTURE.md` (how it
works), `docs/STATUS.md` (what's done / what's next), and `docs/PLAN.md` (the
original product + technical plan). Each major subtree also has its own
`CLAUDE.md` with local rules.

---

## What this is

A native **iOS** app: an intelligent, adaptive goals system. It onboards a user
through a friendly chat that turns a vague aspiration into a concrete goal,
decomposes it into milestones + recurring tasks, schedules those tasks around
the user's real constraints (work hours, sleep), tracks progress, and — the core
bet — **re-plans adaptively** based on how the user actually did, instead of
guilt-tripping them with overdue badges.

iPhone-first. Local-first (data lives on-device). The network is used only for
LLM inference, through a thin stateless proxy.

**The one architectural principle everything follows from:**
> **The LLM proposes; deterministic Swift disposes.**
> All semantic work (understanding aspirations, decomposing goals, deciding to
> ease a plan) is the LLM's job. All state mutation, scheduling, and constraint
> enforcement is deterministic, testable Swift. The LLM never writes to the
> database — it emits validated, structured *proposals* (`GoalSpec`,
> `PlanProposal`, `PlanDiff`) that pass a validator and user approval before the
> engine applies them.

---

## Repository map

```
CLAUDE.md                     ← you are here (root guidance)
README.md                     ← project blurb + status
SETUP.md                      ← how to build & run
docs/
  PLAN.md                     ← product & technical plan (the "why")
  ARCHITECTURE.md             ← how the code is organised & data flows (the "how")
  STATUS.md                   ← implemented / stubbed / next-tasks backlog
Packages/GoalsCore/           ← PURE Swift domain layer (no Apple-UI deps) + tests
  CLAUDE.md                   ← rules for the pure layer
  Sources/GoalsCore/
    Models/                   ← value types (Goal, Task*, Plan, Performance, …)
    Schemas/                  ← LLM structured-output contracts (GoalSpec, PlanProposal, PlanDiff)
    Scheduling/               ← deterministic Scheduler + Availability (Layer 1)
    Planning/                 ← PlanValidator, PlanMutator, PerformanceAnalyzer, AdaptationPolicy
    LLM/                      ← LLMService protocol, ReplanService (retry loop), MockLLMService
  Tests/GoalsCoreTests/       ← XCTest coverage for all of the above
App/                          ← the iOS app
  project.yml                 ← XcodeGen spec — SOURCE OF TRUTH for the .xcodeproj
  Goals/
    CLAUDE.md                 ← rules for the app layer
    App/                      ← @main entry, AppContainer (DI), Config, notification routing
    Persistence/              ← SwiftData models + repository protocols/impl (the swap seam)
    Services/                 ← PlanEngine, SchedulingCoordinator, Coach/Task/Notification/Perf, LLMClient
    ViewModels/               ← @Observable view models (MVVM-lite)
    Views/                    ← SwiftUI screens + shared chat/card components
    Resources/                ← Info.plist, Assets, Secrets.example.xcconfig
proxy/                        ← thin Cloudflare Worker LLM proxy (TypeScript)
  CLAUDE.md                   ← rules for the proxy
```

---

## Build, run, and verify

> ⚠️ **This code has never been compiled.** It was authored in a Linux
> container with **no Swift toolchain and no Xcode**, so there is no
> compiler/test verification yet. Your **first job on a Mac is to make it
> build** and run the tests. Treat the first `swift test` / Xcode build as the
> real correctness gate, and expect to fix a handful of issues the author
> couldn't catch without a compiler. Update `docs/STATUS.md` as you verify.

```sh
# 1. Pure domain layer — fast, no Xcode needed. START HERE.
cd Packages/GoalsCore && swift test

# 2. Generate the Xcode project (committed as project.yml, not a .xcodeproj)
brew install xcodegen          # one-time
cd App && xcodegen generate    # writes App/Goals.xcodeproj (git-ignored)
open Goals.xcodeproj           # ⌘R on an iOS 17 simulator

# 3. (Optional) the live LLM proxy — app works WITHOUT this via the mock
cd proxy && npm install && npm run typecheck
#   npx wrangler secret put ANTHROPIC_API_KEY && npm run deploy
```

The app **runs out of the box with no backend**: `AppContainer` selects a
deterministic `MockLLMService` when no proxy URL is configured (see
`App/Goals/App/Config.swift`). To enable the live coach, copy
`App/Goals/Resources/Secrets.example.xcconfig` → `Secrets.xcconfig` and set
`LLM_PROXY_BASE_URL`, then re-run `xcodegen generate`.

There is **no CI yet** and **no `.xcodeproj` in git** (regenerated from
`project.yml`). If you add source files, they're picked up automatically by
`xcodegen generate` (the spec globs `App/Goals`), so re-generate after adding
files. The `GoalsCore` package is wired in via `project.yml`'s `packages:`.

---

## Architecture in 90 seconds

Four layers, strict dependency direction (top depends on bottom, never the
reverse):

```
Views (SwiftUI)
  → ViewModels (@Observable)
    → Services  (PlanEngine, SchedulingCoordinator, Coach/Task/Notification, LLMClient)
      → Repositories (protocols)  +  GoalsCore (pure domain)
        → SwiftData (behind the repository seam)        LLM proxy (behind LLMService)
```

- **`GoalsCore`** is pure value types + pure functions. No SwiftUI, SwiftData,
  UIKit, or any Apple-platform-only API. This is why it tests on Linux and runs
  identically in tests and the app. **Keep it that way.**
- **Repositories** (`App/Goals/Persistence/Repositories.swift`) are the seam:
  everything above speaks domain value types; only the SwiftData implementation
  knows about persistence. This is the insurance for swapping SwiftData later.
- **`LLMService`** (protocol in `GoalsCore`) is the seam to the model. Two
  conformances: `LLMClient` (networks to the proxy) and `MockLLMService`
  (deterministic, offline). Orchestration logic (the validate-and-retry replan
  loop) lives in `GoalsCore/LLM/ReplanService.swift` so it's testable without a
  network.

The **two-layer adaptation engine** (the heart of the product):
- **Layer 1 — `Scheduler`** (`GoalsCore/Scheduling/`): deterministic, pure. Given
  task templates + the constraint profile, it places concrete `TaskOccurrence`s
  over a 14-day horizon. It *refuses to overload* — unplaceable demand surfaces
  as an `OvercommitSignal` rather than silently dropping tasks. Costs zero API
  calls; works offline.
- **Layer 2 — the LLM adapter** (`ReplanService` + the proxy): invoked only for
  *judgment* ("should this plan get easier?"). Emits a `PlanDiff` of operations
  against the current plan — never datetimes. Validated, previewed, applied,
  then Layer 1 re-runs.

Full detail: **`docs/ARCHITECTURE.md`**.

---

## The most important invariants (don't break these)

1. **`GoalsCore` stays pure.** No `import SwiftUI/SwiftData/UIKit` in
   `Packages/GoalsCore`. If you need persistence or UI, do it in the app layer.
2. **The LLM never mutates state directly.** It returns `GoalSpec` /
   `PlanProposal` / `PlanDiff`. Every state change goes:
   *generate → validate (`PlanValidator`) → preview → user-approve → apply
   (`PlanMutator`) → reschedule → record (`PlanRevision`).* `PlanEngine` is the
   only place this happens (`App/Goals/Services/PlanEngine.swift`).
3. **The LLM never emits datetimes.** Scheduling is deterministic. The LLM
   changes *intent* (templates/frequency/effort/milestones); the `Scheduler`
   decides *when*.
4. **Template vs occurrence split is sacred.** `TaskTemplate` is recurring
   intent; `TaskOccurrence` is a dated instance. Adaptation rewrites future
   occurrences; completed history is never falsified.
5. **Time is timezone-stable.** Persist local `CalendarDay` + minute-of-day
   `MinuteWindow`, never UTC instants. (Handles travel/DST — see `docs/PLAN.md` §9.)
6. **Forgiveness over streaks.** Product principle with teeth: no streak
   counters, no shaming red badges, no gamification. Missed tasks trigger
   adaptation, not guilt. Don't add streak/gamification features.
7. **Privacy: minimal context to the LLM.** Only the relevant goal's summary +
   the compact `PerformanceSnapshot` + active conversation are ever sent. Never
   the whole database, never other goals, never raw Health data.
8. **Three structured contracts, kept in sync across three places.** A change to
   `GoalSpec`/`PlanProposal`/`PlanDiff` must update: the Swift type
   (`GoalsCore/Schemas/`), the proxy JSON schema (`proxy/src/prompts.ts`), and
   the `MockLLMService` (`GoalsCore/LLM/MockLLMService.swift`). See the
   "How to add an LLM capability" recipe below.

---

## Common recipes (where to make changes)

**Add a screen:** new `View` under `App/Goals/Views/<Area>/`, a matching
`@Observable` view model under `App/Goals/ViewModels/`, wire it into
`RootView`/`MainTabView`. View models are created lazily in `.onAppear` and take
`AppContainer` from `@Environment(AppContainer.self)`. See `App/Goals/CLAUDE.md`.

**Add a new plan operation** (e.g. "split a milestone"): add a `case` to
`PlanOperation.Kind` (`GoalsCore/Schemas/PlanDiff.swift`), handle it in
`PlanMutator.apply`, validate it in `PlanValidator.validate`, add it to the
proxy schema (`proxy/src/prompts.ts` replan tool), teach `MockLLMService.replan`
to emit it where appropriate, and add tests in `PlanningTests.swift`.

**Add / change an LLM-backed capability:** the data contract is a Swift
`Codable` type in `GoalsCore/Schemas/` (or a method on `LLMService`). To change
it you touch exactly three spots — Swift type, proxy prompt+schema, mock — then
add a `GoalsCoreTests` case. Keep the proxy's `tool_choice` single-tool so output
stays schema-valid. See `proxy/CLAUDE.md`.

**Change scheduling behaviour:** it's all in `GoalsCore/Scheduling/Scheduler.swift`
+ `Availability.swift`. Pure functions — add/adjust a test in `SchedulerTests.swift`
and you can iterate without the app.

**Tune when adaptation fires:** `GoalsCore/Planning/AdaptationPolicy.swift`
(deterministic trigger rules) — cheap, testable, gates the expensive LLM call.

**Persistence change:** add/modify an `SD*` model + mapping in
`App/Goals/Persistence/SwiftDataModels.swift`, expose it through a repository
protocol + the `SwiftDataStore` impl in `Repositories.swift`, and register new
models in `AppSchema.models`.

---

## Conventions

- **Swift 6, strict concurrency.** `project.yml` sets
  `SWIFT_STRICT_CONCURRENCY: complete`. Repositories and services that touch
  SwiftData/UI are `@MainActor`. `GoalsCore` is `Sendable`-friendly value types.
- **MVVM-lite, no TCA.** Complex state lives in the pure `GoalsCore` domain layer
  where it's unit-testable; view models are thin glue.
- **Comments explain *why*, and reference the plan** (e.g. "docs/PLAN.md §5").
  Match the surrounding density; don't over-comment.
- **Tests are the spec for the domain layer.** New domain logic ⇒ new
  `GoalsCoreTests` case. The tests use a fixed UTC calendar (`Fixtures.calendar`)
  for determinism.
- **Commit when the user asks; branch off the default branch first.** Active
  feature branch: `claude/ios-ai-goals-system-hg0gf3`.

---

## Model & secrets policy (important for committed artifacts)

- When building AI features, default to the **latest, most capable Claude
  models**. The proxy currently calls `claude-opus-4-8` with adaptive thinking
  and forced structured output. Model IDs are pinned server-side in
  `proxy/src/index.ts`/`prompts.ts` so they change without an app release.
- **Never hardcode API keys.** The Anthropic key lives only as a Cloudflare
  secret (`wrangler secret put ANTHROPIC_API_KEY`). `Secrets.xcconfig` is
  git-ignored; only `Secrets.example.xcconfig` is committed.
- Don't put internal tooling identifiers, your own model identifier, or session
  IDs into source, comments, or commit messages.

---

## Where to read next

- **`docs/ARCHITECTURE.md`** — module-by-module responsibilities, data-flow
  walkthroughs (onboarding, completing a task, a replan), concurrency model,
  persistence strategy.
- **`docs/STATUS.md`** — exactly what's implemented vs stubbed vs not-started,
  known risks/unverified areas, and a prioritised next-tasks backlog mapped to
  the plan's phases. **Start here to pick up work.**
- **`docs/PLAN.md`** — the product & technical reasoning behind every decision.
