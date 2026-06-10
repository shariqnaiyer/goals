# Goals — Product & Technical Plan

*A native iOS, AI-powered adaptive goals system.*

This document covers product vision, UX design, technical architecture, data model, the adaptation engine, privacy, iOS integrations, a phased roadmap, and risks/open questions. Where a decision was made on an assumption, the assumption is stated and the trade-off explained.

---

## 1. Product Vision & Principles

**One-liner:** A personal coach in your pocket that turns "I want to get fit / write a book / learn Spanish" into a living, adaptive plan — and renegotiates that plan with you the way a good human coach would, instead of guilt-tripping you with red overdue badges.

**Why this app can win:** existing goal/habit apps split into two failure modes. Trackers (Streaks, Habitify) make you do all the planning and punish lapses. Planners (Notion templates, coaching programs) produce static plans that decay the first week life intervenes. The differentiator here is the *renegotiation loop*: the system notices how you're actually doing and proposes realistic adjustments before you give up.

### Design principles

These four principles drive every decision in this document:

1. **The LLM proposes; deterministic code disposes.** All semantic work — understanding aspirations, decomposing goals, explaining replans — is LLM work. All state mutation, scheduling, and constraint enforcement is deterministic Swift. The LLM never writes directly to the database; it emits validated, structured *plan proposals* that the user approves and the engine applies.
2. **Forgiveness over streaks.** Missed tasks trigger adaptation, not shame. The core loop is "observe → renegotiate," not "track → nag." (This principle has a concrete consequence: no streak counters or gamification in the product — see §8.)
3. **Local-first.** Goals are intimate data. Everything lives on-device; the network is used only for LLM inference, with minimal context sent per request.
4. **Chat is a verb, not the app.** Structured UI (Today list, goal detail) is the primary surface; chat is the escape hatch for anything nuanced ("I sprained my ankle, fix my running plan").

### Assumptions about the product

- **Target user:** individual consumers pursuing self-improvement goals — fitness, learning, creative projects, career, habits. Not teams, not OKR tooling. Trade-off: a narrower market than productivity-at-large, but a coherent product voice; team features would pull every design decision in a different direction.
- **Monetization:** subscription after a free trial. LLM inference has real per-user marginal cost, so a one-time purchase price is untenable. Trade-off: subscriptions narrow the funnel; a generous free tier backed by on-device models is the v2+ mitigation (§3.3).
- **Platform:** iPhone-first. iPad/Mac are architecturally possible but not committed (§9).

---

## 2. Product Design & UX

### 2.1 Onboarding conversation — the make-or-break flow

Target: from first app open to a concrete, personally-tuned plan in **under 4 minutes**, feeling like a chat with a perceptive friend rather than a form.

The flow:

1. **Warm open, zero account.** No sign-up wall — local-first architecture makes this possible. One screen of value proposition, then straight into the conversation. Every additional pre-chat screen costs activation.
2. **Aspiration capture.** Fully freeform: *"What's something you've been wanting to do?"* The LLM asks at most **2–3 follow-up questions**, chosen dynamically to resolve the highest-value ambiguities:
   - Is this an *outcome* goal (run a marathon by October) or a *habit* goal (run regularly)?
   - Is there a real deadline, or is it open-ended?
   - What's the current level? ("Have you run before? How recently?")
   - What's the honest weekly time budget?

   The question cap is a hard product rule. Interview fatigue kills onboarding; a slightly under-specified plan that gets refined in week one beats a perfect plan the user never sees because they bailed at question seven.
3. **Constraint capture — conversational but structured.** *"When do you usually work? When do you sleep?"* — but the answers land in **inline structured cards** (chips, time-range pickers) inside the chat that the user can tap to correct. This hybrid avoids the classic chat-app failure where extracted facts are wrong *and invisible*: the user sees exactly what the system believes and fixes it with one tap instead of typing a correction.
4. **Plan proposal as an interactive artifact.** The LLM returns a structured draft — goal statement, success criteria, 2–4 milestones, the first week of tasks — rendered as **native, editable cards** inside the chat. The user can swap a task, slide effort down, or move a milestone date inline. Never a wall of generated text.
5. **Consent at the moment of value.** The notification permission prompt appears only *after* the plan exists, framed as "Want reminders for these?" — acceptance rates are dramatically higher when the user can see what they'd be reminded about. Calendar and Health permissions are deferred entirely to later contextual moments (§6).

**Key UX decision — hybrid chat.** Every LLM action that changes state renders as a native, editable card (plan proposal, plan diff, schedule preview), not prose. Justification: pure-chat goal apps fail because state is invisible and corrections are laborious; pure-form apps fail because vague aspirations don't fit forms. The hybrid is meaningfully more engineering work (a card-rendering protocol inside the chat transcript) but it is the product's core differentiation and the foundation of trust in an AI that edits your plans.

### 2.2 Key screens

1. **Today** *(home, tab 1).* Today's tasks across all goals, ordered by scheduled window. One-tap complete, snooze, or skip-with-reason (the reason feeds adaptation). A **"daily minimum"** indicator shows the floor that keeps the plan alive on a bad day — completing just the minimum is presented as a win, not a partial failure. Pull down to peek at tomorrow.
2. **Goals** *(tab 2).* A card per goal showing milestone progress. Goal detail = milestone timeline, upcoming tasks, and **plan history** — every replan ever applied, each with the LLM's one-line rationale. Auditability is a feature: users trust an AI coach whose changes they can inspect and reverse.
3. **Coach** *(tab 3).* The chat. A persistent thread per goal plus one general thread. Used for check-ins, replans, "life happened" events (sick, travel, lost motivation), and changing or retiring goals.
4. **Weekly Review** *(surfaced via notification → sheet, not a tab).* A 60-second guided reflection: what got done, what the coach proposes to adjust and why, and one reflective question. This is where adaptation becomes *visible and consensual* rather than something the app silently does.
5. **Settings / Constraints.** Editable schedule profile (work hours per weekday, sleep window, blackout dates, max daily task minutes), notification preferences, data export, and one-tap erase.

### 2.3 Core loops

- **Daily:** morning notification with the day's 1–3 tasks → complete/skip in Today, from the notification action, or from the widget → a gentle evening nudge *only if nothing at all was logged*.
- **Weekly:** review notification → 60-second review sheet → accept/edit adaptation proposals.
- **Event-driven:** chat anytime; three consecutive misses on a recurring task triggers a proactive *"Should we make this easier?"* prompt rather than a fourth identical reminder.

---

## 3. Architecture & Tech Stack

### 3.1 Client

| Decision | Choice | Justification / trade-off |
|---|---|---|
| UI framework | **SwiftUI**, minimum **iOS 17** | Best-in-class native feel with the modern APIs this app needs: `@Observable`, interactive widgets, the scroll APIs required for a polished chat transcript. iOS 17+ covers the large majority of active devices in 2026 and cuts only very old hardware. UIKit is avoided except where SwiftUI is genuinely weak; we accept some custom work for the chat transcript view. |
| Language | **Swift 6, strict concurrency** | Greenfield codebase — no legacy cost to adopting strict concurrency, and it eliminates a whole class of bugs in an app with background scheduling work. |
| App architecture | **MVVM-lite + a pure domain layer** | Views ↔ `@Observable` view models ↔ domain services (`PlanEngine`, `Scheduler`, `CoachService`) ↔ repositories. Deliberately **not** TCA: it adds ceremony and onboarding friction for a small team, and the state that's genuinely complex (planning, scheduling, diff application) is isolated in a pure domain layer that's unit-testable without any UI framework at all. |
| Persistence | **SwiftData**, hidden behind repository protocols | Velocity for v1 plus a free CloudKit sync path later. Known risk: SwiftData is still maturing, and its CloudKit mode imposes constraints (optional fields, no unique constraints). Mitigation: **all** data access goes through `GoalRepository` / `TaskRepository` / `ChatRepository` protocols, so a swap to GRDB/SQLite is contained if we hit walls. This is the decision most likely to be revisited; the repository seam is the insurance policy. |
| Scheduling engine | **Pure Swift package, zero dependencies** | The deterministic interval scheduler (§5) is pure functions over value types — exhaustively unit-testable, property-testable, and identical in tests and production. |

### 3.2 Backend: a thin proxy, nothing more

**Decision:** a minimal serverless proxy (e.g., Cloudflare Workers) between the app and the LLM API. **No user database. No stored conversations.**

*Why a backend at all:* an LLM API key cannot ship in the app binary. The proxy:

- holds the API key;
- authenticates devices via **App Attest** plus an anonymous device token (no account required);
- rate-limits and meters usage for subscription enforcement, paired with **StoreKit 2** transaction verification;
- pins **prompt and schema versions server-side**, so prompt fixes and model upgrades ship without an App Store release.

*Why only a proxy:* every server-side feature added — accounts, stored chat history, server-side scheduling — erodes the privacy story and adds permanent ops burden. When sync arrives (Phase 3), it uses **CloudKit**: Apple-hosted, private-database, end-to-end-encryptable, and no auth system for us to build or breach.

### 3.3 LLM strategy

**Decision: a cloud frontier model (Claude Sonnet-class) as primary, accessed via the proxy; Apple's on-device Foundation Models (iOS 26+) as a later tier for lightweight tasks.**

Goal decomposition, plan revision, and coach conversation need strong reasoning *and* reliable structured output — today that is a frontier-model job. On-device models are the right long-term home for classification-grade work (intent routing, check-in sentiment) and for a privacy/offline tier, but betting v1 quality on them would risk the core experience. Trade-off acknowledged: cloud inference means per-user cost and goal text leaving the device. Mitigations: minimal per-call context (§7), no server-side retention, and explicit disclosure during onboarding.

**Where the LLM is used — exhaustive list (everything else in the app is deterministic):**

1. **Onboarding interview** → emits a structured `GoalSpec`.
2. **Plan generation:** `GoalSpec` + constraints → `PlanProposal` (milestones; task templates with effort, frequency, preferred windows).
3. **Replanning:** performance summary + current plan → `PlanDiff` (add/remove/modify/reschedule operations) + a human-readable rationale.
4. **Coach chat:** conversation with scoped tool calls — read plan state, propose a `PlanDiff`, log a check-in. The tools are the only way chat can touch state.
5. **Weekly review narrative:** stats → a short reflective summary.

**Reliability mechanics — how LLM output stays trustworthy:**

- **Structured outputs everywhere.** Every state-affecting call uses tool-use / JSON-schema-constrained output, decoded into Swift types via `Codable`. A decode failure triggers one automatic repair round-trip (the error is fed back to the model), then a graceful fallback (apologize, offer manual editing). Never a crash, never silent corruption.
- **Semantic validation after syntactic.** A successfully decoded `PlanDiff` must pass a deterministic validator: every referenced entity ID resolves, total task load fits the user's weekly time budget, schedule windows fall inside availability, no milestone is orphaned. Invalid diffs are sent back to the model with the violation list (max 2 retries), then fall back gracefully.
- **Plan diffs, not plan rewrites.** The model returns *operations against the current plan*, never a fresh plan. Smaller outputs, far fewer hallucinated regressions of things the user hand-customized, and a trivially auditable plan history.
- **Apply is transactional and user-approved.** Diffs render as a preview card; nothing mutates until the user accepts. (Auto-accepting trivial reschedules becomes an opt-in setting later.)
- **Versioned prompts + an eval suite.** Prompts live server-side and are versioned. A regression suite of recorded onboarding transcripts and replan scenarios — with golden `PlanDiff` outputs and validator pass-rate thresholds — runs on every prompt or model change. This is built in **Phase 0** because it is the single highest-leverage early investment: the product lives or dies on plan quality.

---

## 4. Data Model

SwiftData entities (simplified; all access goes through repository protocols):

| Entity | Key fields | Notes |
|---|---|---|
| **Goal** | id, title, motivationStatement, type (`outcome` \| `habit`), successCriteria, targetDate?, status (`active`/`paused`/`completed`/`abandoned`), createdAt, archivedReason? | The motivation statement (captured at onboarding) is replayed by the coach when motivation dips. |
| **Milestone** | goal ref, title, order, targetDate?, completionCriteria, status | 2–4 per goal, generated then user-edited. |
| **TaskTemplate** | goal/milestone ref, title, effortMinutes, recurrenceRule (RFC 5545-style), preferredWindows (weekday + time range), flexibility (`fixed`/`flexible`/`anytime`), minimumViableVariant? | The *recurring intent* — e.g., "Run 5k, 3×/week, mornings preferred." `minimumViableVariant` ("10-min walk") powers bad-day downgrades. |
| **TaskOccurrence** | template ref?, scheduledDate, scheduledWindow?, status (`pending`/`done`/`skipped`/`rescheduled`), completedAt?, skipReason?, userDifficultyRating? | The *schedulable instance*. The template/occurrence split is essential: adaptation rewrites **future** occurrences without falsifying history. |
| **ConstraintProfile** | work hours per weekday, sleep window, blackout dates, max daily task minutes, protected-calendar rules | Single global profile in v1. Assumption: per-goal constraint profiles are a rare need; revisit if users ask. |
| **PlanRevision** | goal ref, timestamp, trigger (`user_request`/`missed_tasks`/`weekly_review`/`goal_edited`/`overcommitted`), serialized `PlanDiff`, LLM rationale, accepted/rejected | The audit log that powers "plan history." Rejected diffs are kept too — they're useful signal. |
| **ChatMessage** | thread id (per-goal or general), role, text, attachedArtifact? (card payload), createdAt | Cards in the transcript are stored as typed payloads, re-rendered natively. |
| **PerformanceSnapshot** | per-template completion rate, completion-by-time-of-day, snooze count, load vs. budget; computed weekly, cached | The adaptation engine's input — and the **only** behavioral aggregate ever sent to the LLM. |

---

## 5. Adaptation & Constraint Handling — Mechanics

This is the technical heart of the app: a **two-layer design** separating placement from judgment.

### Layer 1 — deterministic Scheduler (pure Swift)

- **Input:** active task templates + `ConstraintProfile` + (when permission granted) EventKit busy intervals.
- **Output:** dated, time-windowed `TaskOccurrence`s over a rolling **14-day horizon**.
- **Algorithm:** for each day, compute availability windows (waking hours − work hours − calendar busy − blackouts), then place tasks **greedily** ordered by deadline pressure, the user's historically best time-of-day for that task type, and load smoothing across days — capped by max daily minutes.
- **Why greedy rather than an optimizer:** the problem is tiny (≤ ~10 tasks/day), greedy placement is fully explainable to the user ("it's here because mornings are free and you complete runs best before work"), and explainability beats marginal optimality in a trust-sensitive product.
- **Overcommitment is a signal, not a silent failure:** if demand exceeds availability, the scheduler refuses to overload the user and instead raises an `overcommitted` trigger for Layer 2.

### Layer 2 — LLM Adapter

- **Triggers:** weekly review (always); three consecutive misses on one template; the scheduler's `overcommitted` signal; a user goal edit; an explicit chat request.
- **Input:** the compact `PerformanceSnapshot`, a plan summary, and the trigger reason — not the raw history.
- **Output:** a `PlanDiff` proposing *semantic* changes the scheduler cannot make on its own — reduce frequency, shrink effort, swap a task for its `minimumViableVariant`, reorder milestones, push a target date — **or** a clarifying question for the user instead of a diff, when the data is ambiguous ("You've skipped every evening session but done all morning ones — should I move everything to mornings, or is something else going on?").
- The diff is validated (§3.3), previewed to the user, applied transactionally, and then **Layer 1 re-runs** to place the revised templates into concrete occurrences.

### Why two layers

"*When* does this task go?" is a constraint problem — fast, free, offline, deterministic. "*Should this plan get easier?*" is a judgment problem — that's the LLM. Mixing them (letting the LLM emit datetimes) produces constraint violations and burns tokens. The split means everyday rescheduling costs **zero API calls and works offline**, and the LLM is reserved for the calls where it adds real value.

### How changing goals is handled

- **Edit:** a chat conversation produces a `PlanDiff` with `trigger = goal_edited`; milestones and templates are revised in place, history preserved.
- **Pause:** freezes templates and silences notifications; nothing is deleted, resume is one tap.
- **Pivot** ("actually I want to train for a 10k, not lose weight"): creates a plan revision that preserves completed-milestone history under the evolved goal.
- **Abandon:** archives the goal with an optional exit reflection (which is genuinely useful input if the user later starts something similar).

Plan history makes every evolution inspectable and reversible.

---

## 6. iOS Integrations

| Integration | Phase | Design |
|---|---|---|
| **Notifications** (UserNotifications) | MVP | Local notifications scheduled by the Scheduler: a morning digest; per-task reminders at window start (opt-in per template); a gentle evening check *only if zero activity was logged*. Actionable: **Done / Snooze** directly from the notification. Hard cap ~3/day, and adaptation lowers frequency for users who ignore them — notification fatigue is the #1 churn risk for this category. |
| **Calendar** (EventKit) | Phase 2 | **Read-only first:** busy intervals feed the Scheduler. Permission is requested contextually ("Want me to schedule around your calendar?"), never at launch. Optional *write-back* of task blocks comes later — write-back invites sync-conflict pain and is deferred deliberately. |
| **Widgets** (WidgetKit) | Phase 2 | Lock-screen and home-screen "next task" + today's progress, with an interactive complete button (iOS 17 interactive widgets). |
| **HealthKit** | Phase 3 | Read **sleep** to learn the user's *actual* sleep window vs. their stated one, and **workouts** to auto-complete fitness tasks. Deferred because of privacy/review sensitivity and because stated sleep hours are good enough for v1 scheduling. Health data **never leaves the device and is never sent to the LLM** — only derived scheduling facts ("user is typically asleep by 23:30"). |
| **App Intents / Shortcuts / Siri** | Phase 3 | "What's next?", "Mark my run done." Cheap to add once the domain layer exists; App Intents also future-proofs for system-level Apple Intelligence surfacing. |
| **Live Activities** | Phase 3+ | An optional focus-session timer for time-boxed tasks. Nice-to-have, not core. |

---

## 7. Privacy

- **Local-first.** All goals, tasks, and chat live on-device (SwiftData with Data Protection `.completeUntilFirstUserAuthentication`). When CloudKit sync ships, it uses the user's private database with end-to-end-encrypted fields where feasible.
- **Minimal LLM context.** Each API call sends only: the relevant goal's summary, the compact performance snapshot, and the active conversation. Never the whole database, never other goals' content, never raw Health data.
- **No server retention.** The proxy is stateless; LLM API calls are made with retention disabled / zero-data-retention options where the provider offers them.
- **Plain disclosure.** Onboarding states clearly: "Your plan is generated by AI. Here's exactly what gets sent and what never leaves your phone."
- **Anonymous by default.** No account in v1; device-token auth via App Attest. Sign in with Apple appears only when sync ships, and only for sync.
- **User control.** Full JSON export and one-tap erase-everything in Settings.
- **Sensitive goals, handled honestly.** Users *will* enter mental-health and medical goals. The coach prompt carries guardrails — no medical or clinical advice, crisis-resource referral on risk signals — and App Store metadata avoids health-treatment claims.

---

## 8. Roadmap

### Phase 0 — Foundations (2–3 weeks, no UI)

- Prompt + JSON schema design for `GoalSpec`, `PlanProposal`, `PlanDiff`.
- **Eval harness** with recorded onboarding transcripts and replan scenarios; golden outputs and validator pass-rate thresholds.
- The **Scheduler** as a standalone pure Swift package with exhaustive unit/property tests.
- Proxy skeleton (auth, rate limiting, prompt versioning).

*Justification:* the product lives or dies on plan quality and schema reliability, and the cheapest place to iterate on both is before any UI exists.

### Phase 1 — MVP (6–8 weeks → TestFlight)

- Onboarding chat → first plan (the full hybrid-card experience — this is not cuttable).
- Today screen; goal detail with plan history; check-in chat with plan-diff cards.
- Deterministic scheduling with manually entered constraints.
- Local notifications (digest + reminders).
- **Manual adaptation only:** the user asks → a diff is proposed. No automatic triggers yet.
- **Single active goal limit** — cuts all multi-goal balancing complexity from v1.

**Explicitly cut from v1:** automatic adaptation triggers; Calendar and HealthKit; widgets; sync/accounts; multiple simultaneous goals; Apple Watch; visual themes; **streaks/gamification** (conflicts with the forgiveness principle — likely a permanent cut); **social features** (permanent cut).

### Phase 2 — The adaptive coach (≈6 weeks → App Store launch)

- Automatic adaptation triggers + the weekly review flow (the headline feature).
- EventKit read integration.
- Interactive widgets.
- Multiple active goals with cross-goal load balancing in the Scheduler.
- Subscription + paywall (post-trial), StoreKit 2.

### Phase 3 — Depth (ongoing)

- HealthKit sleep/workout signals.
- CloudKit sync + Sign in with Apple.
- App Intents / Shortcuts / Siri.
- On-device model tier for lightweight calls and an offline coach fallback.
- Live Activities; iPad exploration if demand shows.

---

## 9. Risks, Edge Cases, Open Questions

### Key risks

1. **LLM cost per active user.** Mitigations: diffs not rewrites; zero-API-call daily scheduling; prompt caching; the on-device tier later. Subscription pricing must be modeled against measured tokens/user/week from TestFlight before launch.
2. **Onboarding latency.** Multi-second LLM turns land exactly where first impressions form. Mitigations: streaming responses, optimistic card skeletons, and a strict model-size/latency budget per call type.
3. **Plan quality variance.** A bad generated plan in week one is fatal to trust. The Phase 0 eval suite is the control; plan-history transparency is the backstop.
4. **Notification fatigue → churn.** Adaptive frequency, hard caps, and "quiet weeks" when engagement drops — paradoxically, backing off retains users.
5. **The week-3 motivation cliff** (product risk, not technical). The forgiveness/renegotiation loop *is* the bet on this; **D21 retention is the north-star metric** for the TestFlight period.
6. **SwiftData maturity.** The repository seam contains the blast radius of a migration to GRDB if needed.
7. **App Review.** Avoid medical claims; comply with AI-disclosure expectations; the subscription paywall must follow current StoreKit rules.

### Edge cases to design for

- **Timezone travel and DST:** store local-date + time-window (not UTC instants) for occurrences; reschedule on timezone change.
- **Shift workers / irregular schedules:** the per-weekday constraint profile handles rotating-but-regular shifts; truly irregular schedules fall back to `anytime` flexibility with a daily-minutes cap.
- **Offline:** everything works except chat and replanning — those queue with a visible badge. Daily scheduling is local and unaffected.
- **Zero availability:** if constraints leave no room, the overcommitted flow produces an honest conversation — "this goal needs ~5 hours/week you don't currently have; shrink the goal or free the time?" — rather than a silently impossible plan.
- **Adversarial/jailbreak chat input:** proxy-side moderation plus strictly scoped tools mean the worst case is a silly chat message, never data damage — the LLM cannot mutate state except through validated, user-approved diffs.
- **Device migration before sync exists:** JSON export/import; encrypted iCloud device backup covers the common case.

### Open questions (deliberately not blocking Phase 0/1)

1. **Pricing and trial length** — needs real per-user token cost data from TestFlight.
2. **Coach personality** — one strong, warm, direct voice vs. configurable tones. Leaning: one voice first; configurability later.
3. **Goal templates** ("Couch to 5k") vs. pure generative planning — templates could raise the quality floor and cut token cost; explore in Phase 2.
4. **iPad/Mac** — the architecture doesn't preclude Catalyst/native Mac, but no commitment until iPhone retention is proven.
5. **Weekly review: interrupt or optional?** A mandatory-ish review drives the adaptation loop but risks feeling naggy — A/B in TestFlight.
