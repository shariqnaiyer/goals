# Plan: Deep, concreteness-driven onboarding + app redesign

## Context

Today the app's onboarding is a thin 3-turn chat that asks "what do you want to do?" + a
date, then generates a plan. The owner wants the opposite of thin: an onboarding that
**genuinely learns the user** (their life, daily reality, long- and short-term goals),
then **formalizes** each goal and **probes relentlessly for concreteness** so goals can be
decomposed into real recurring tasks. "I want to read" must become *Atomic Habits, 20
chapters, a chapter most nights*; "I want to be fit" must become *Couch-to-5K, 9 weeks, 3
runs/week*. The app must also capture enough concrete structure (the book and its chapters,
the workout routine and its sets) to later enable an "overseer" that schedules into calendar
gaps — that overseer is **out of scope here**, but the data model must make it possible.

This redesigns the onboarding flow and the app's information architecture around that
premise, while strictly honoring the core principle: **the LLM proposes structured
proposals; deterministic, testable Swift disposes** (all state mutation, scheduling, and the
concreteness decision). `GoalsCore` stays pure; the LLM never emits datetimes; the
template/occurrence split is preserved; no streaks/shame.

**Build is already green.** The repo had never been compiled. Getting it to build + run on a
simulator required 5 fixes (already applied to the working tree): a generic type nested in a
generic function (`LLMClient.swift`), an ambiguous closure in `CoachView.swift`, a
`Task`-returning closure in `GoalDetailView.swift`, `.cancelAction` → `.cancellationAction`
in `PlanCards.swift`, and missing `CFBundleIdentifier`/exec keys in `Info.plist`. The app now
installs and runs the onboarding chat on the offline `MockLLMService`. These should be
committed as the "Phase 0" baseline.

### Owner decisions (locked)
1. **Start with 1–3 goals**, not one — user picks which to activate now; enforce a combined
   weekly-budget cap so the schedule stays realistic. Remaining aspirations become backlog.
2. **Typed specifics**: purpose-built `reading` (book + chapters) and `fitness` (program +
   routines/sets) models, plus a `generic` "ordered units" fallback.
3. **Rename the Settings tab → "You"**, the home for the learned, editable profile.
4. (Engineering call) Replace `interview` with a new `onboardingTurn`; keep a short-lived
   `interview` shim during migration, then delete it so two onboarding paths never coexist.

---

## The new onboarding: a Swift-owned, 5-stage Guided Discovery Interview

One continuous card-based chat (reuse the existing onboarding chat surface + hybrid-chat
card renderer). The model proposes structured state each turn; **Swift owns stage
transitions, the concreteness gate, the capacity cap, and every DB write.** Turn style is
**inference-first**: the coach asks one sharp question, infers a confident draft, and renders
it as an **editable native card** the user fixes in a tap. Every probe ships 2–4 chips so an
undecided user always advances in one tap; the free-text composer is always the escape hatch.
A thin progress rail (pips, `Palette.accent`, never a %, never red) sits under the header.

> Fixes a real bug along the way: today the composer locks once a proposal appears
> (`OnboardingView.swift`), and `accept()` saves *untouched default* constraints
> (`OnboardingViewModel.swift:93`, `constraintDraft` is the init default and nothing edits it).

- **Stage 1 — GROUND (learn the person) [1–2 turns].** Swift-seeded opener replaces the
  current `start()` line. Model infers a `PersonSketch` (one-liner, daily shape, energy
  pattern, long-term theme) and reflects it back as an editable card. Advances when
  `oneLine` + `dailyShape` are non-empty; hard cap 2 turns (no interrogation).
- **Stage 2 — SURFACE (elicit + split goals) [1–2 turns].** Model proposes a **GoalSet
  card**: candidate aspirations, each tagged **Long-term / Short-term**, short-term ones shown
  as serving the long-term theme (`servesAspirationID`). User **multi-selects 1–3** to set up
  now (`focusAspirationIDs`); the rest persist as backlog. Long-term north-stars are captured
  as deferred data (a far/empty-target goal), not planned in v1.
- **Stage 3 — CONCRETIZE (the probe loop — the heart) [1–3 turns per selected goal].** For
  each selected aspiration in turn, probe **one concreteness dimension per turn**
  (`object` first), inferring the rest from the `PersonSketch` and offering chips. Loops until
  `ConcretenessCheck.isConcrete` passes for that goal, then moves to the next selected goal.
  Worked examples below.
- **Stage 4 — CONFIRM THE WEEK (constraints, pre-filled) [1 tap].** Model has inferred work
  hours / wake / bedtime / quiet hour from `dailyShape`. Render the **already-defined-but-unused
  `ChatArtifact.constraintDraft`** (`Chat.swift:10`) as an editable card. This is where the
  real `ConstraintProfile` is captured (closing the "saves defaults" bug).
- **Stage 5 — FORMALIZE (approval) [1 tap].** Swift confirms every selected goal passed the
  gate and the **combined weekly budget fits** (capacity check, below). It calls the existing
  `generatePlan(spec:profile:)` once per selected goal and renders each as an in-chat
  `.planProposal` artifact (`PlanProposalCard`), stacked, with a combined-load summary. The
  composer stays live so "make it 3 nights not 7" returns a revised card. **On Accept:** save
  the confirmed `ConstraintProfile`; persist `PersonSketch` + backlog to `SDUserProfile`;
  create each goal via `PlanEngine.createGoal(fromEdited:)`; `setCompletedOnboarding(true)`;
  request notifications; reschedule.

**Add-goal "+"** (already reuses the onboarding view from `GoalsListView`) enters at **Stage 3**
— person + constraints already known — so a later goal is a 1–2 turn flow.

### Worked concreteness examples
- **"I want to read"** → object probe (`Fiction` · `Learn` · `A specific book`) → book pick
  (`Atomic Habits` · `Pragmatic Programmer` · `I have one in mind`) → infer cadence from the
  9pm quiet hour. Produces `reading(book: "Atomic Habits", chapters: [Ch.1…Ch.20], currentIndex: 0)`.
- **"I want to get fit"** → object probe (`Build strength` · `Run without dying` · `Just move`)
  → current-vs-target reflection ("could you jog 5 min right now?" `No way`·`Maybe`·`Yeah`) →
  propose `Couch-to-5K`. Produces `fitness(program: "Couch to 5K", runs: [W1-R1…W9-R3])`,
  `successCriteria: "Run 5K continuously"`.
- **Undecided user:** the AI *proposes, not asks* — surfaces specific, defensible options
  grounded in what it learned; a soft ~6-turn cap on one dimension picks a sensible default and
  moves on.

---

## The concreteness engine (Swift decides, not the model)

New pure, unit-tested file **`GoalsCore/Planning/ConcretenessCheck.swift`**, mirroring the
validate-and-retry discipline `ReplanService` already uses:

```
ConcretenessDimension = object | startState | targetState | cadence | capacity
requiredDimensions(for:) → default {all five}; habit/ongoing relaxes targetState

isConcrete(aspiration) == true iff:
  1. requiredDimensions ⊆ aspiration.resolvedDimensions      (model reports coverage)
  2. object rule: kind ∈ {reading, course} ⇒ specifics != nil with non-empty name
  3. title refined (≠ rawWish) AND non-empty successCriteria
  4. weeklyBudgetMinutes > 0                                  (don't trust a flag w/ empty fields)
  5. an emittable cadence (RecurrenceRule expressible)

canFormalize(state) == every selected aspiration isConcrete
                       && person grounded
                       && combinedWeeklyBudget ≤ availableWeeklyCapacity(profile)
```

The model's `stage == .readyToFormalize` is **advisory**; `canFormalize` is **authoritative**.
If the model signals ready while a required dimension is open, Swift keeps the composer open and
feeds back a system note ("asp_read still missing: object, capacity") so the next turn probes
the gap — the model can never shortcut probing, and Swift independently re-checks fields so the
flags can't be gamed.

**Capacity cap (the 1–3 goal guardrail):** `availableWeeklyCapacity(profile)` is derived
deterministically from the `ConstraintProfile`'s free minutes/week. If the selected goals'
combined `weeklyBudgetMinutes` exceeds it, `canFormalize` is false and the coach proposes
trimming (fewer sessions, or defer one goal to backlog) before formalizing. After plans are
generated and scheduled together, the Scheduler's existing `OvercommitSignal` is the final
backstop, surfaced gently at approval.

---

## Domain model changes (additive; near-zero migration)

The JSON-payload persistence pattern (lenient `try?` decode in `SwiftDataModels.swift`) means
new optional/defaulted fields decode on legacy rows with **no SwiftData migration**. All new
value types are pure (Foundation only) in `GoalsCore/Sources/GoalsCore/Models/`.

- **`UserProfile.swift` (new):** the durable "who they are," distinct from `ConstraintProfile`
  (availability) and `Goal` (wants). Holds `identityStatement`, `lifeContext: [LifeFact]`,
  `coreMotivations`, `energyByTimeOfDay`, `coachingPreferences` (tone + check-in *cadence*, not
  a streak), and `backlogAspirations: [AspirationDraft]`. Summarized — never dumped — into LLM
  context.
- **`GoalSpecifics.swift` (new):** the concrete object, a closed enum the **Scheduler never
  reads**:
  `GoalSpecifics = .reading(ReadingSpecifics) | .fitness(FitnessSpecifics) | .generic(GenericSpecifics)`
  where `ReadingSpecifics { bookTitle, author?, chapters: [SeriesUnit], targetFinish: CalendarDay?, pagesPerSession? }`,
  `FitnessSpecifics { baseline, target, programName?, routines: [Routine] }` with
  `Routine { name, exercises: [ExercisePrescription{name, sets, reps, note?}] }`, and
  `GenericSpecifics { unitNoun, units: [SeriesUnit] }`. `SeriesUnit { id, order, title, detail?, isComplete=false }`.
  `targetFinish` is a `CalendarDay` *target* like the existing `Goal.targetDate` — never a
  scheduled instant.
- **`Entities.swift` — `Goal`** gains three additive defaulted fields: `horizon: GoalHorizon = .longTerm`
  (`shortTerm|longTerm`), `parentGoalID: UUID? = nil` (short-term serves long-term — a
  self-link, **not** a new aggregate, so Scheduler/PlanEngine/repos stay single-shape), and
  `specifics: GoalSpecifics? = nil`.
- **`Entities.swift` — `TaskTemplate`** gains `detail: TemplateDetail? = nil`
  (`.sequential(seriesKind) | .rotating(routineIDs:) | .none`) — *intent*, adaptation may rewrite.
- **`Entities.swift` — `TaskOccurrence`** gains `slice: SessionSlice? = nil`
  (`{ unitID: UUID?, label, detail? }`) — *immutable history* stamped when done/skipped; never rewritten.
- **`Scheduling/Sequencer.swift` (new, pure):** runs **after** the Scheduler, leaving
  `Scheduler.Input/Output` untouched. `assignSlices(pending:specifics:templates:consumedUnitIDs:)`
  assigns each pending occurrence its next unread chapter / next routine in rotation and folds
  `slice.label` into `TaskOccurrence.title`, so every view that shows `title` keeps working.
  No-op when `specifics == nil`. Reads only `CalendarDay` ordering — no datetimes.
- **`Planning/PlanValidator.swift`:** add a rule rejecting `parentGoalID` cycles / a parent
  that points at a short-term goal.

**Migration safety:** when `GoalSpecifics` is first attached to a pre-existing goal, seed the
series cursor explicitly (user-set or unit 0) — never infer "done" from sliceless completed
history, or it would falsify progress. Add a decode-fallback test per changed type.

---

## LLM contract changes (kept in lockstep across 3 places)

Any change here moves together across **(1)** the Swift type in `GoalsCore/Schemas/` + `LLMService.swift`,
**(2)** the proxy JSON schema + prompt in `proxy/src/prompts.ts`, **(3)** `MockLLMService`, plus a
`GoalsCoreTests` oracle. Bump `PromptVersion.interview → "onboarding-v1"` and `schema → "schema-v2"`.

- **`LLMService.swift`:** replace `interview(history:draft:)` with
  `onboardingTurn(state: OnboardingState, latestUserText: String) async throws -> OnboardingTurnResult`
  (thin deprecated `interview` shim during migration). New `Codable, Sendable, Hashable` types
  (client-held state re-sent each call — proxy stays stateless, same pattern as today's `draft`):
  `OnboardingState { person: PersonSketch, aspirations: [AspirationDraft], focusAspirationIDs: [String], concretizingID: String?, stage: Stage, turnCount: Int }`,
  `OnboardingTurnResult { state, assistantMessage, choices: [String], stage }`,
  `PersonSketch`, `AspirationDraft { id, rawWish, title, horizon, type, servesAspirationID?, status, specifics: GoalSpecifics? }`,
  `ConcretenessDimension`, `Stage = grounding|surfacing|concretizing|readyToFormalize`.
- **`Schemas/GoalSpec.swift`:** widen **additively** (old decode still works) with
  `specifics: GoalSpecifics?`, `resolvedDimensions: [ConcretenessDimension]`, `horizon: GoalHorizon?`.
  Keep `isComplete` on the wire but demote it — `ConcretenessCheck` is authoritative.
- **`Schemas/PlanProposal.swift`:** `ProposedTemplate` gains `specifics: GoalSpecifics?` and
  `detail: TemplateDetail?`; extend `materialise(...)` (the single place new fields land in
  persisted state) to write them onto `Goal.specifics` / `TaskTemplate.detail`.
- **`proxy/src/prompts.ts` + `index.ts`:** replace the `interview` task with `onboardingTurn`
  (tool `record_onboarding_turn`); **rewrite the system prompt** from "as FEW questions as
  possible" to "probe until each goal is concrete enough to decompose; resolve `object` first;
  prefer concrete chips; infer schedule from the PersonSketch; signal `readyToFormalize` only
  when concrete," parameterized by `stage`. Expand `input_schema` (`additionalProperties:false`,
  accurate `required`); all date fields typed `["string","null"]` with `"yyyy-MM-dd or null"`
  (schema-enforces no datetimes). `GoalSpecifics`/specifics map to a discriminated union (a
  `kind` field + per-kind object), mirroring `PlanOperation`'s flat-shape choice. Add
  `case "onboardingTurn": return input;` to `shapeResult`; keep single-tool `tool_choice` and
  the `{ result }` envelope. `propose_plan` schema gains the additive `specifics`+`detail`.
- **`MockLLMService.swift`:** rebuild `interview` (the fixed 3-turn machine) as `onboardingTurn`
  — a deterministic, coverage-driven **stage machine** that is the executable offline spec
  (grounding → surfacing, reuse the existing `Theme` keyword logic to tag run/write/learn →
  concretize per selected goal, filling `reading`/`fitness` specifics → constraints →
  `readyToFormalize`). `generatePlan` mock emits `specifics`/`detail` on templates.
- **`App/Goals/Services/LLMClient.swift`:** replace the `interview` `Req`/`Res` with
  `onboardingTurn`; the existing decode-repair round-trip covers it.

---

## App IA redesign — four tabs: **Today / Goals / Coach / You**

The `RootView` 3-phase gate (`.welcome → .onboarding → .main`) and `onFinished` contract are
untouched. The only rename: **Settings → "You."**

- **Today** (`TodayView.swift`): `TaskRow` gains a **concrete subtitle** from the occurrence's
  `slice` ("Read — *Atomic Habits*" / "Chapter 4 · ~18 pages"; "Workout B · Squat 5×5"). Rows
  with no slice render exactly as today (graceful fallback). Tap → **`TaskDetailSheet` (new,
  `.medium`)**: the per-session checklist, one-tap "do the minimum" (`minimumViableVariant`),
  skip-with-reason. Completion still routes through `TaskActionService` — no new mutation path.
- **Goals** (`GoalsListView.swift` / `GoalDetailView.swift`): `GoalCard` gains a one-line
  concrete hint ("*Atomic Habits* · 6 of 20 chapters") via `GProgressBar`; `GoalDetailView`
  inserts a **"Where you are"** section (`SectionLabel` + `CardGroup`) reading out the concrete
  object — **`ReadingDetailView`** (chapter list, sage-checked completed units, "currently on
  ch.4") or **`RoutineDetailView`** (named routines, sets×reps, what's next). Editing concrete
  state (mark a chapter done, swap a routine) goes **through `PlanEngine`** (propose→validate→
  apply), never a direct DB write. Long-term/short-term grouping + backlog surface here.
- **Coach** (`CoachView.swift`): unchanged renderer — but extend its artifact switch (today
  only `.planDiff`) to also render `.planProposal` / `.constraintDraft` / `.clarifyingChoices`,
  so onboarding and the coach share one hybrid-chat renderer.
- **You** (new `YouView` shell, merges Settings): **`ProfileView`** ("What I understand about
  you") renders the `UserProfile` as warm, second-person, *editable* cards (each with a quiet
  "that's not quite right" affordance; edits flow back as a validated structured update); the
  existing `ConstraintEditorView` moves here as "Life & constraints"; "Your weeks" gives a
  permanent door to past + current `WeeklyReview` (the auto-present logic stays); "Your data"
  (export/erase/privacy) moves verbatim.

**Persistence (App layer):** add `@Model SDUserProfile` (id "default", `payload: Data`) to
`SwiftDataModels.swift` and register in `AppSchema.models` (8 → 9 types) — copy the
`SDConstraintProfile` singleton exactly. Add a `UserProfileRepository` protocol + `SwiftDataStore`
impl in `Repositories.swift` mirroring `ConstraintRepository`; expose `app.userProfile`;
`bootstrap()` ensures a default empty profile. Goal/Template/Occurrence changes need **no SD
change** (they ride existing payloads).

---

## Implementation phases (each keeps `swift test` + Xcode build green)

- **Phase 0 — Baseline (essentially done).** Commit the 5 compile/Info.plist fixes; confirm
  `swift test` (29 tests) + Xcode build + app launch. Update `docs/STATUS.md`.
- **Phase 1 — Thin vertical slice: a reading goal, end-to-end, mock-only.** GoalsCore: add
  `GoalSpecifics.reading` + `SeriesUnit` + `TemplateDetail` + `SessionSlice`; add `Goal.specifics`,
  `TaskTemplate.detail`, `TaskOccurrence.slice` (all defaulted); `ConcretenessCheck` (reading
  required dims); `Sequencer.assignSlices` (sequential); extend `ProposedTemplate` + `materialise`.
  Tests for gate + sequencer + materialise. App: `SchedulingCoordinator.reschedule` calls
  `Sequencer` after `Scheduler().schedule` (compute `consumedUnitIDs` from completed slices);
  `TaskRow` shows `slice.label`; `MockLLMService.generatePlan` emits a reading object for
  "read"/"book" titles. Result: a "read Atomic Habits" goal created the *old* way now shows
  "Chapter 1, 2…" on Today + "Where you are" in detail. Shippable.
- **Phase 2 — Onboarding contract + stage machine (3-place sync), mock-only.** GoalsCore:
  `OnboardingState` family; widen `GoalSpec`; `onboardingTurn` (+ `interview` shim); rebuild
  `MockLLMService` as the stage machine; full scripted `GoalsCoreTests` run reaching
  `readyToFormalize`. App: rebuild `OnboardingViewModel` around the Swift-owned stage enum +
  `canFormalize` gate (multi-select 1–3, per-goal concretize loop, capacity cap); composer
  always visible except creating/finished; render `.planProposal`/`.constraintDraft`/
  `.clarifyingChoices` inline; PersonSketch + GoalSet cards; persist `SDUserProfile`; save
  confirmed `ConstraintProfile`; `LLMClient.onboardingTurn`. Proxy: rewrite prompt + schema,
  bump versions (ships independently; app works offline regardless). Result: full deep
  onboarding works offline.
- **Phase 3 — Fitness + generic specifics; horizon/parent; full IA.** GoalsCore:
  `GoalSpecifics.fitness/.generic`, `Routine`/`ExercisePrescription`, `TemplateDetail.rotating`,
  `Sequencer` rotation; `Goal.horizon`/`parentGoalID` + `PlanValidator` cycle rule. App:
  `YouView` shell + move Settings rows; `ProfileView`; `RoutineDetailView`; `TaskDetailSheet`;
  backlog/horizon sections; add-goal "+" enters at Stage 3.
- **Phase 4 — Polish (optional).** A `PlanOperation.Kind` like `advanceSeries`/`markUnitComplete`
  for "you're ahead, skip to ch.6" (full recipe: case → PlanMutator → PlanValidator → proxy →
  mock → test); re-run-profile-as-life-changes flow.

---

## Risks to watch

- **3-place schema sync is the central gate.** Drift between the Swift type, `prompts.ts`
  (`required`/`additionalProperties:false`), and `MockLLMService` silently diverges live vs
  offline. Mitigation: move all three together per phase + a full-run `GoalsCoreTests` oracle.
- **Discriminated-union Codable ↔ JSON schema** (`GoalSpecifics`) is the most error-prone
  serialization point; round-trip tests are the gate. This code has never compiled — treat the
  first `swift test` as the real check.
- **Datetime leakage:** every date stays `yyyy-MM-dd` string; the onboarding validator rejects
  non-`yyyy-MM-dd`.
- **Overcommit from 1–3 goals:** enforce the deterministic capacity cap in `canFormalize`
  *before* formalizing; the Scheduler's `OvercommitSignal` is the backstop. No streaks/shame
  anywhere; amber for minimums, never red.
- **Privacy:** `UserProfile` is summarized into minimal LLM context (relevant goal summary +
  compact snapshot + active conversation), never dumped; proxy stays storeless.

---

## Verification

- **Domain layer (primary gate):** `cd Packages/GoalsCore && swift test`. New executable-spec
  tests: `ConcretenessCheck` truth table (incl. gate never passes with an open required
  dimension, and the override path where the model says ready but Swift rejects); reading-theme
  → reading specifics with units; `Sequencer` walks a series and never reassigns consumed units;
  `materialise` writes specifics/horizon; full scripted `onboardingTurn` run reaching
  `readyToFormalize`; multi-goal capacity cap; decode-fallback per changed type.
- **App build:** `cd App && xcodegen generate && xcodebuild -scheme Goals -destination
  'platform=iOS Simulator,name=iPhone 17 Pro' build`.
- **End-to-end on simulator:** install + launch, then drive onboarding with the working UI
  harness (`/tmp/tap.py` re-fetches the simulator window bounds before each tap; hardware
  keyboard on; `osascript ... keystroke` for text) — walk Ground → Surface (pick 1–3) →
  Concretize ("read" → Atomic Habits chapters; "fit" → C25K) → Confirm constraints → accept,
  screenshotting each stage via `xcrun simctl io booted screenshot`. Confirm Today shows
  concrete chapter/routine subtitles and "Where you are" reads out progress.
- **Proxy (optional, live path):** `cd proxy && npm install && npm run typecheck`; deploy and
  set `LLM_PROXY_BASE_URL` in `Secrets.xcconfig` to exercise the real model. App works offline
  on the mock without it.
