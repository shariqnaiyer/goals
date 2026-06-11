import Foundation

/// A deterministic, offline `LLMService`. It makes the app fully runnable with
/// no backend or API key (the plan's "works with the mock service" path), drives
/// SwiftUI previews, and gives the test suite a stable oracle. It uses simple
/// keyword heuristics to feel responsive without any network.
public struct MockLLMService: LLMService {

    public var calendar: Calendar
    public init(calendar: Calendar = .current) { self.calendar = calendar }

    // MARK: Onboarding (the Guided Discovery Interview stage machine)

    /// A deterministic, coverage-driven stage machine — the executable offline
    /// spec for the onboarding contract. Mirrors what the proxy prompt asks the
    /// real model to do: ground → surface → concretize (probe one dimension per
    /// turn, inferring the rest) → readyToFormalize. Swift's `ConcretenessCheck`,
    /// not this code, is authoritative about whether formalizing is allowed.
    public func onboardingTurn(state: OnboardingState,
                               latestUserText: String) async throws -> OnboardingTurnResult {
        var s = state
        s.turnCount += 1
        let text = latestUserText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch s.stage {
        case .grounding:        return ground(&s, text)
        case .surfacing:        return surface(&s, text)
        case .concretizing:     return concretize(&s, text)
        case .readyToFormalize: return readyResult(s)
        }
    }

    // MARK: Stage 1 — GROUND

    private func ground(_ s: inout OnboardingState, _ text: String) -> OnboardingTurnResult {
        if s.person.oneLine.isEmpty { s.person.oneLine = capitalizedFirst(condense(text)) }
        if s.person.dailyShape.isEmpty { s.person.dailyShape = derivedDailyShape(text) }
        if s.person.energyPattern == nil { s.person.energyPattern = derivedEnergy(text) }
        if s.person.longTermTheme == nil { s.person.longTermTheme = derivedTheme(text) }

        guard s.person.isGrounded else {
            return OnboardingTurnResult(
                state: s,
                assistantMessage: "Got it. What does a normal weekday actually look like for you?",
                stage: .grounding)
        }
        s.stage = .surfacing
        return OnboardingTurnResult(
            state: s,
            assistantMessage: "Here's what I'm picking up: \(s.person.oneLine). \(s.person.dailyShape) "
                + "What are one to three things you've been wanting to change?",
            stage: .surfacing)
    }

    // MARK: Stage 2 — SURFACE

    private func surface(_ s: inout OnboardingState, _ text: String) -> OnboardingTurnResult {
        if s.aspirations.isEmpty {
            s.aspirations = parseAspirations(from: text)
            guard !s.aspirations.isEmpty else {
                return OnboardingTurnResult(
                    state: s,
                    assistantMessage: "No wrong answers — even a vague itch counts. What's one thing you'd love to be different a few months from now?",
                    stage: .surfacing)
            }
            return OnboardingTurnResult(
                state: s,
                assistantMessage: "Here's how I'd frame these. Tap the one to three you want to start on now — the rest I'll keep for later.",
                choices: s.aspirations.map(\.title),
                stage: .surfacing)
        }

        // The view sets `focusAspirationIDs` from taps; if the user typed instead,
        // match the text to a title, else default to the first.
        if s.focusAspirationIDs.isEmpty {
            let lower = text.lowercased()
            if let matched = s.aspirations.first(where: {
                !lower.isEmpty && ($0.title.lowercased().contains(lower) || lower.contains($0.title.lowercased()))
            }) {
                s.focusAspirationIDs = [matched.id]
            } else {
                s.focusAspirationIDs = [s.aspirations[0].id]
            }
        }
        return beginConcretizing(&s, lead: "")
    }

    /// Point the probe loop at the first not-yet-concrete focus aspiration.
    private func beginConcretizing(_ s: inout OnboardingState, lead: String) -> OnboardingTurnResult {
        guard let next = s.focusAspirations.first(where: { !ConcretenessCheck.isConcrete($0) }) else {
            s.concretizingID = nil
            s.stage = .readyToFormalize
            return readyResult(s)
        }
        s.concretizingID = next.id
        s.stage = .concretizing
        let p = probe(for: next)
        return OnboardingTurnResult(state: s, assistantMessage: lead + p.message,
                                    choices: p.choices, stage: .concretizing)
    }

    // MARK: Stage 3 — CONCRETIZE (one dimension per turn, infer the rest)

    private func concretize(_ s: inout OnboardingState, _ text: String) -> OnboardingTurnResult {
        guard let id = s.concretizingID, var asp = s.aspiration(id) else {
            s.stage = .readyToFormalize
            return readyResult(s)
        }

        applyProbeAnswer(&asp, text: text)
        // Safety net: never loop forever on one goal.
        if s.turnCount > 14 { forceConcrete(&asp) }
        s.update(asp)

        if !ConcretenessCheck.isConcrete(asp) {
            let p = probe(for: asp)
            return OnboardingTurnResult(state: s, assistantMessage: p.message,
                                        choices: p.choices, stage: .concretizing)
        }

        asp.status = .concrete
        s.update(asp)
        return beginConcretizing(&s, lead: "Love it. Now — ")
    }

    private func readyResult(_ s: OnboardingState) -> OnboardingTurnResult {
        OnboardingTurnResult(
            state: s,
            assistantMessage: "That's everything I need. Here's the plan — tweak anything, then we'll make it real. 👇",
            stage: .readyToFormalize)
    }

    // MARK: Plan generation

    public func generatePlan(spec: GoalSpec, profile: ConstraintProfile) async throws -> PlanProposal {
        let theme = Theme(title: spec.title)
        let weeklyMinutes = max(60, spec.weeklyBudgetMinutes)
        let sessionMinutes = min(60, max(20, weeklyMinutes / 3))

        let milestones = [
            ProposedMilestone(key: "m1", title: theme.milestone1, order: 0,
                              completionCriteria: "Establish the routine and basics.", targetDate: nil),
            ProposedMilestone(key: "m2", title: theme.milestone2, order: 1,
                              completionCriteria: "Build capability and consistency.", targetDate: spec.targetDate),
            ProposedMilestone(key: "m3", title: theme.milestone3, order: 2,
                              completionCriteria: spec.successCriteria, targetDate: spec.targetDate)
        ]

        // A concrete reading goal walks its chapters in order (the Sequencer
        // stamps "Chapter N" onto each session); other goals use the generic
        // two-template shape. Prefer the specifics onboarding already pinned down;
        // fall back to detecting one from the title.
        // A fitness goal rotates through its routines (the Sequencer stamps
        // "Workout A / B" with sets×reps onto each session).
        if case .fitness(let fitness)? = spec.specifics {
            let template = ProposedTemplate(
                title: fitness.programName ?? "Workout", milestoneKey: "m1",
                effortMinutes: min(50, max(20, sessionMinutes)), cadence: .timesPerWeek,
                weekdays: [.monday, .wednesday, .friday], timesPerWeek: 3, intervalDays: 1,
                preferredTimeOfDay: .earlyMorning, flexibility: .flexible,
                minimumViableVariant: "10-minute version",
                detail: .rotating(routineIDs: fitness.routines.map(\.id)))
            return PlanProposal(goalTitle: spec.title,
                                successCriteria: spec.successCriteria.isEmpty ? fitness.target : spec.successCriteria,
                                milestones: milestones,
                                templates: [template],
                                specifics: .fitness(fitness))
        }

        let providedReading: ReadingSpecifics? = {
            if case .reading(let r)? = spec.specifics { return r }
            return nil
        }()
        if let reading = providedReading ?? Self.readingSpecifics(forTitle: spec.title) {
            let nights: [Weekday] = [.monday, .tuesday, .wednesday, .thursday, .sunday]
            let templates = [
                ProposedTemplate(title: "Reading session", milestoneKey: "m1",
                                 effortMinutes: min(30, sessionMinutes), cadence: .timesPerWeek,
                                 weekdays: nights, timesPerWeek: 5, intervalDays: 1,
                                 preferredTimeOfDay: .evening, flexibility: .flexible,
                                 minimumViableVariant: "Read 2 pages",
                                 detail: .sequential)
            ]
            return PlanProposal(goalTitle: spec.title,
                                successCriteria: spec.successCriteria.isEmpty
                                    ? "Finish \(reading.bookTitle)." : spec.successCriteria,
                                milestones: milestones,
                                templates: templates,
                                specifics: .reading(reading))
        }

        let templates = [
            ProposedTemplate(title: theme.coreTask, milestoneKey: "m1",
                             effortMinutes: sessionMinutes, cadence: .timesPerWeek,
                             weekdays: [.monday, .wednesday, .friday], timesPerWeek: 3, intervalDays: 1,
                             preferredTimeOfDay: .earlyMorning, flexibility: .flexible,
                             minimumViableVariant: theme.minimumTask),
            ProposedTemplate(title: theme.supportTask, milestoneKey: "m1",
                             effortMinutes: 15, cadence: .specificWeekdays,
                             weekdays: [.sunday], timesPerWeek: 0, intervalDays: 1,
                             preferredTimeOfDay: .evening, flexibility: .anytime,
                             minimumViableVariant: nil)
        ]

        return PlanProposal(goalTitle: spec.title,
                            successCriteria: spec.successCriteria,
                            milestones: milestones,
                            templates: templates)
    }

    /// Heuristically detect a reading goal from its title and build a concrete
    /// `ReadingSpecifics` (the specific book + numbered chapters). Returns nil for
    /// non-reading goals so they keep the generic plan shape.
    static func readingSpecifics(forTitle title: String) -> ReadingSpecifics? {
        let t = title.lowercased()
        let mentionsWriting = t.contains("write") || t.contains("writing")
            || t.contains("author") || t.contains("blog") || t.contains("journal")
        let mentionsReading = t.contains("read") || t.contains("chapter") || t.contains("pages")
            || ((t.contains("book") || t.contains("novel")) && !mentionsWriting)
        guard mentionsReading && !mentionsWriting else { return nil }

        var name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["finish reading ", "read the book ", "read through ", "get through ",
                       "finish ", "reading ", "read "] {
            if name.lowercased().hasPrefix(prefix) {
                name = String(name.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        if name.isEmpty || ["more", "books", "a book"].contains(name.lowercased()) {
            name = "your book"
        }
        // "20 chapters" → 20, else a sensible default.
        let count = firstNumber(in: t, near: ["chapter"]) ?? 12
        return ReadingSpecifics.numbered(bookTitle: name, chapterCount: count)
    }

    private static func firstNumber(in text: String, near keywords: [String]) -> Int? {
        guard keywords.contains(where: { text.contains($0) }) else { return nil }
        return text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.first
    }

    // MARK: Replan

    public func replan(plan: Plan,
                       snapshot: PerformanceSnapshot,
                       trigger: RevisionTrigger,
                       userMessage: String?,
                       priorViolations: [String]) async throws -> PlanDiff {
        // If the user explicitly asked something ambiguous, ask back.
        if let msg = userMessage?.lowercased(),
           msg.contains("?") && !msg.contains("easier") && !msg.contains("less") {
            return PlanDiff(
                summary: "Clarifying what you'd like to change.",
                clarifyingQuestion: "Happy to adjust — do you want fewer sessions, shorter sessions, or a later target date?",
                clarifyingChoices: ["Fewer sessions", "Shorter sessions", "Later target date"])
        }

        // Otherwise ease the most-struggled template.
        let struggling = snapshot.strugglingTemplates().sorted { $0.currentMissStreak > $1.currentMissStreak }
        if let worst = struggling.first, let template = plan.template(worst.templateID) {
            if template.minimumViableVariant != nil {
                return PlanDiff(
                    summary: "You've missed “\(template.title)” a few times — switching to the lighter version to rebuild momentum.",
                    operations: [PlanOperation(kind: .swapToMinimumViable,
                                               targetTemplateID: template.id,
                                               note: "Switch “\(template.title)” to its minimum version")])
            }
            let reduced = max(1, template.recurrence.occurrencesPerWeek - 1)
            return PlanDiff(
                summary: "Dialing “\(template.title)” back to \(reduced)×/week so it's sustainable.",
                operations: [PlanOperation(kind: .modifyTemplate,
                                           targetTemplateID: template.id,
                                           newTimesPerWeek: reduced,
                                           note: "Reduce “\(template.title)” to \(reduced)×/week")])
        }

        // Over budget but no single struggler: trim the largest template.
        if snapshot.isOverBudget, let biggest = plan.activeTemplates.max(by: { $0.weeklyLoadMinutes < $1.weeklyLoadMinutes }) {
            let reduced = max(1, biggest.recurrence.occurrencesPerWeek - 1)
            return PlanDiff(
                summary: "This is a bit more than your weekly budget — trimming “\(biggest.title)”.",
                operations: [PlanOperation(kind: .modifyTemplate,
                                           targetTemplateID: biggest.id,
                                           newTimesPerWeek: reduced,
                                           note: "Reduce “\(biggest.title)” to \(reduced)×/week")])
        }

        return PlanDiff(summary: "Things look on track — no changes needed.")
    }

    // MARK: Coach

    public func coachTurn(plan: Plan?,
                          snapshot: PerformanceSnapshot?,
                          history: [ChatMessage],
                          userMessage: String) async throws -> CoachReply {
        let msg = userMessage.lowercased()
        if let plan, msg.contains("easier") || msg.contains("too much") || msg.contains("overwhelm") {
            if let t = plan.activeTemplates.first {
                let diff = PlanDiff(
                    summary: "Making things lighter this week.",
                    operations: [PlanOperation(kind: .swapToMinimumViable, targetTemplateID: t.id,
                                               note: "Lighter version of “\(t.title)”")])
                return CoachReply(message: "Totally fair. Here's a lighter version — want me to apply it?",
                                  proposedDiff: diff)
            }
        }
        if msg.contains("done") || msg.contains("finished") || msg.contains("did") {
            return CoachReply(message: "Nice work — that's logged. Keeping the momentum going 💪")
        }
        if let plan {
            return CoachReply(message: "Here for it. You're working toward “\(plan.goal.title)”. What's on your mind?")
        }
        return CoachReply(message: "Tell me what you'd like to work on and I'll help you shape it into a plan.")
    }

    // MARK: Review

    public func reviewNarrative(snapshot: PerformanceSnapshot, plan: Plan) async throws -> String {
        let rate = Int(snapshot.overallCompletionRate * 100)
        let done = snapshot.templates.reduce(0) { $0 + $1.completed }
        if rate >= 70 {
            return "Strong week — you completed \(done) sessions (\(rate)%). The plan's working; let's keep the same shape."
        } else if rate >= 30 {
            return "A mixed week — \(done) sessions done (\(rate)%). Life happens; I've got a small tweak to make next week more doable."
        } else {
            return "Tough week, and that's okay (\(rate)% done). Let's make the plan lighter so it meets you where you are."
        }
    }

    // MARK: - Heuristics

    private func derivedTitle(from text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = cleaned.lowercased()
        for prefix in ["i want to ", "i'd like to ", "i would like to ", "i want ", "help me "] {
            if lower.hasPrefix(prefix) {
                cleaned = String(cleaned.dropFirst(prefix.count))
                break
            }
        }
        return capitalizedFirst(cleaned)
    }

    private func capitalizedFirst(_ string: String) -> String {
        guard let first = string.first else { return string }
        return String(first).uppercased() + String(string.dropFirst())
    }

    private func parseRoughDate(_ text: String) -> String? {
        let lower = text.lowercased()
        guard !lower.contains("open") && !lower.contains("no ") && !lower.isEmpty else { return nil }
        // Default to ~12 weeks out when a deadline is implied but unspecified.
        let target = calendar.date(byAdding: .day, value: 84, to: Date()) ?? Date()
        let day = CalendarDay(date: target, calendar: calendar)
        return String(format: "%04d-%02d-%02d", day.year, day.month, day.day)
    }

    private func parseWeeklyMinutes(_ text: String) -> Int? {
        if let hours = firstInt(in: text, near: ["hour", "hr", "hrs", "hours"]) { return hours * 60 }
        if let mins = firstInt(in: text, near: ["minute", "min", "mins"]) { return mins }
        return nil
    }

    private func firstInt(in text: String, near keywords: [String]) -> Int? {
        guard keywords.contains(where: { text.contains($0) }) else { return nil }
        let numbers = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        return numbers.first
    }

    // MARK: - Onboarding heuristics

    private func condense(_ text: String) -> String {
        let firstClause = text.split(whereSeparator: { ".!?".contains($0) }).first.map(String.init) ?? text
        return String(firstClause.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
    }

    private func derivedDailyShape(_ text: String) -> String {
        let l = text.lowercased()
        var parts: [String] = []
        if l.contains("work") || l.contains("job") || l.contains("9-") || l.contains("9 to") { parts.append("workdays are full") }
        if l.contains("kid") || l.contains("child") || l.contains("family") { parts.append("family time in the evenings") }
        if l.contains("night") || l.contains("evening") || l.contains("pm") || l.contains("after") { parts.append("quietest once the day winds down") }
        if parts.isEmpty {
            return text.split(separator: " ").count >= 4 ? "balancing a busy schedule." : ""
        }
        return parts.joined(separator: ", ") + "."
    }

    private func derivedEnergy(_ text: String) -> String? {
        let l = text.lowercased()
        if l.contains("morning") { return "more energy in the mornings" }
        if l.contains("night") || l.contains("evening") { return "comes alive in the evenings" }
        return nil
    }

    private func derivedTheme(_ text: String) -> String? {
        let l = text.lowercased()
        if l.contains("health") || l.contains("fit") || l.contains("strong") { return "feeling healthier" }
        if l.contains("calm") || l.contains("headspace") || l.contains("stress") || l.contains("mindful") { return "more headspace" }
        if l.contains("learn") || l.contains("grow") || l.contains("career") { return "growing" }
        return nil
    }

    private func parseAspirations(from text: String) -> [AspirationDraft] {
        let separators = CharacterSet(charactersIn: ",;\n")
        var phrases = text.components(separatedBy: separators)
            .flatMap { $0.components(separatedBy: " and ") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 3 }
        if phrases.isEmpty, text.count >= 3 { phrases = [text] }
        return phrases.prefix(4).enumerated().map { (i, phrase) in
            let l = phrase.lowercased()
            let type: GoalType = (l.contains("habit") || l.contains("daily") || l.contains("every day")
                                  || l.contains("meditat") || l.contains("regular")) ? .habit : .outcome
            let horizon: GoalHorizon = (l.contains("career") || l.contains("become")
                                        || l.contains("someday") || l.contains("long-term")) ? .longTerm : .shortTerm
            return AspirationDraft(id: "asp_\(i)", rawWish: phrase, title: derivedTitle(from: phrase),
                                   motivation: phrase, type: type, horizon: horizon)
        }
    }

    private struct Probe { let message: String; let choices: [String] }

    /// The question for the first unresolved dimension of `asp` — chips first, so
    /// an undecided user always advances in one tap.
    private func probe(for asp: AspirationDraft) -> Probe {
        guard let dim = ConcretenessCheck.missingDimensions(asp).first else {
            return Probe(message: "Anything you'd tweak before I draft this?", choices: [])
        }
        switch dim {
        case .object:
            if isReadingAspiration(asp) {
                return Probe(message: "Which book's been on your list? A few that build momentum:",
                             choices: ["Atomic Habits", "The Pragmatic Programmer", "I have one in mind"])
            }
            return Probe(message: "“\(asp.rawWish)” can go a few ways — what's the version that'd feel like a win?",
                         choices: themedObjectChoices(asp))
        case .startState:
            return Probe(message: "Quick gut check so I don't overshoot — where are you starting from?",
                         choices: ["Total beginner", "A little experience", "Getting back into it"])
        case .targetState:
            return Probe(message: "And what would actually count as success here?", choices: [])
        case .cadence:
            return Probe(message: "How many days a week feels realistic?",
                         choices: ["A couple", "Most days", "Every day"])
        case .capacity:
            return Probe(message: "Roughly how long can each session be?",
                         choices: ["15 minutes", "30 minutes", "An hour"])
        }
    }

    /// Resolve the first unresolved dimension of `asp` from the user's answer,
    /// inferring the rest where a confident default exists (the inference-first move).
    private func applyProbeAnswer(_ asp: inout AspirationDraft, text: String) {
        guard let dim = ConcretenessCheck.missingDimensions(asp).first else { return }
        let lower = text.lowercased()
        switch dim {
        case .object:
            if isReadingAspiration(asp) {
                let book = bookName(from: text)
                asp.specifics = .reading(.numbered(bookTitle: book, chapterCount: 12))
                asp.title = "Finish \(book)"
                asp.successCriteria = "Finish \(book)."
                asp.type = .outcome
                // Infer the rest from a typical quiet-evening reader.
                if asp.suggestedTimesPerWeek == 0 { asp.suggestedTimesPerWeek = 5 }
                if asp.weeklyBudgetMinutes == 0 { asp.weeklyBudgetMinutes = 105 }
                resolve(&asp, .object, .startState, .targetState, .cadence, .capacity)
            } else if isFitnessAspiration(asp) {
                // Pin a concrete program + the routines the user will rotate through.
                let fitness = Self.fitnessSpecifics(forChoice: text)
                asp.specifics = .fitness(fitness)
                asp.title = fitness.programName ?? "Get fit"
                asp.type = .outcome
                resolve(&asp, .object)
            } else {
                if !text.isEmpty { asp.title = capitalizedFirst(text) }
                if asp.title.caseInsensitiveCompare(asp.rawWish) == .orderedSame || asp.title.isEmpty {
                    asp.title = capitalizedFirst(asp.rawWish) + " — concretely"
                }
                resolve(&asp, .object)
            }
        case .startState:
            if asp.motivation.isEmpty { asp.motivation = text }
            resolve(&asp, .startState)
        case .targetState:
            asp.successCriteria = text.isEmpty
                ? "Make visible progress on \(asp.title)."
                : capitalizedFirst(text)
            resolve(&asp, .targetState)
        case .cadence:
            asp.suggestedTimesPerWeek = parseTimesPerWeek(lower) ?? defaultTimes(for: asp)
            resolve(&asp, .cadence)
        case .capacity:
            let perSession = parseWeeklyMinutes(lower) ?? 30
            asp.weeklyBudgetMinutes = perSession * max(1, asp.suggestedTimesPerWeek)
            resolve(&asp, .capacity)
        }
    }

    /// Last-resort default fill so the probe loop always terminates.
    private func forceConcrete(_ asp: inout AspirationDraft) {
        if asp.title.isEmpty || asp.title.caseInsensitiveCompare(asp.rawWish) == .orderedSame {
            asp.title = capitalizedFirst(asp.rawWish.isEmpty ? "My goal" : asp.rawWish) + " — a first plan"
        }
        if asp.successCriteria.isEmpty { asp.successCriteria = "Make steady progress on \(asp.title)." }
        if asp.suggestedTimesPerWeek == 0 { asp.suggestedTimesPerWeek = defaultTimes(for: asp) }
        if asp.weeklyBudgetMinutes == 0 { asp.weeklyBudgetMinutes = asp.suggestedTimesPerWeek * 30 }
        resolve(&asp, .object, .startState, .targetState, .cadence, .capacity)
    }

    private func resolve(_ asp: inout AspirationDraft, _ dims: ConcretenessDimension...) {
        var set = Set(asp.resolvedDimensions)
        dims.forEach { set.insert($0) }
        asp.resolvedDimensions = ConcretenessDimension.allCases.filter { set.contains($0) }
    }

    private func isReadingAspiration(_ asp: AspirationDraft) -> Bool {
        if case .reading = asp.specifics { return true }
        let t = (asp.rawWish + " " + asp.title).lowercased()
        return t.contains("read") || t.contains("book") || t.contains("chapter")
    }

    private func isFitnessAspiration(_ asp: AspirationDraft) -> Bool {
        if case .fitness = asp.specifics { return true }
        let t = (asp.rawWish + " " + asp.title).lowercased()
        return t.contains("fit") || t.contains("run") || t.contains("strength")
            || t.contains("gym") || t.contains("workout") || t.contains("exercise") || t.contains("move")
    }

    /// Build concrete fitness specifics (a named program + the routines to rotate)
    /// from the user's object choice. Strength → A/B routines with sets×reps;
    /// running → a Couch-to-5K-style rotation; otherwise a simple movement plan.
    static func fitnessSpecifics(forChoice choice: String) -> FitnessSpecifics {
        let c = choice.lowercased()
        if c.contains("strength") || c.contains("strong") || c.contains("muscle") || c.contains("lift") {
            let a = Routine(name: "Workout A", exercises: [
                ExercisePrescription(name: "Squat", sets: 5, reps: "5"),
                ExercisePrescription(name: "Bench press", sets: 5, reps: "5"),
                ExercisePrescription(name: "Barbell row", sets: 5, reps: "5")])
            let b = Routine(name: "Workout B", exercises: [
                ExercisePrescription(name: "Squat", sets: 5, reps: "5"),
                ExercisePrescription(name: "Overhead press", sets: 5, reps: "5"),
                ExercisePrescription(name: "Deadlift", sets: 1, reps: "5")])
            return FitnessSpecifics(baseline: "Starting out", target: "Stronger lifts, 3×/week",
                                    programName: "Strength 5×5", routines: [a, b])
        }
        if c.contains("run") || c.contains("5k") || c.contains("jog") {
            let runs = [
                Routine(name: "Run A — intervals", exercises: [
                    ExercisePrescription(name: "Walk/run intervals", sets: 1, reps: "20 min")]),
                Routine(name: "Run B — steady", exercises: [
                    ExercisePrescription(name: "Easy jog", sets: 1, reps: "25 min")]),
                Routine(name: "Run C — long", exercises: [
                    ExercisePrescription(name: "Long easy run", sets: 1, reps: "30 min")])]
            return FitnessSpecifics(baseline: "Can't run 5 min nonstop yet", target: "Run 5K continuously",
                                    programName: "Couch to 5K", routines: runs)
        }
        let move = Routine(name: "Daily movement", exercises: [
            ExercisePrescription(name: "Brisk walk", sets: 1, reps: "20 min")])
        return FitnessSpecifics(baseline: "Mostly sedentary", target: "Move every day",
                                programName: "Daily movement", routines: [move])
    }

    private func themedObjectChoices(_ asp: AspirationDraft) -> [String] {
        let t = asp.rawWish.lowercased()
        if t.contains("fit") || t.contains("run") || t.contains("strong") || t.contains("gym") {
            return ["Build strength", "Run without dying", "Just move daily"]
        }
        if t.contains("learn") || t.contains("language") || t.contains("spanish") || t.contains("code") {
            return ["Conversational basics", "Pass a test", "Use it for real"]
        }
        return ["Get started small", "Build a steady habit", "Hit a clear milestone"]
    }

    private func bookName(from text: String) -> String {
        var name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["read the book ", "the book ", "reading ", "read "] {
            if name.lowercased().hasPrefix(prefix) { name = String(name.dropFirst(prefix.count)) }
        }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”"))
        if name.isEmpty || ["i have one in mind", "a specific book", "more", "books"].contains(name.lowercased()) {
            return "Atomic Habits"
        }
        return capitalizedFirst(name)
    }

    private func parseTimesPerWeek(_ lower: String) -> Int? {
        if lower.contains("every day") || lower.contains("daily") { return 7 }
        if lower.contains("most") { return 5 }
        if lower.contains("couple") || lower.contains("two") { return 2 }
        if lower.contains("three") { return 3 }
        if let n = lower.split(whereSeparator: { !$0.isNumber }).compactMap({ Int($0) }).first {
            return min(7, max(1, n))
        }
        return nil
    }

    private func defaultTimes(for asp: AspirationDraft) -> Int {
        if isReadingAspiration(asp) || asp.type == .habit { return 5 }
        return 3
    }
}

/// Picks plausible milestone/task wording from the goal title so the mock plan
/// reads naturally across common goal categories.
private struct Theme {
    let coreTask: String
    let supportTask: String
    let minimumTask: String
    let milestone1: String
    let milestone2: String
    let milestone3: String

    init(title: String) {
        let t = title.lowercased()
        if t.contains("run") || t.contains("5k") || t.contains("10k") || t.contains("marathon") || t.contains("fit") {
            coreTask = "Run / training session"; supportTask = "Plan next week's runs"
            minimumTask = "10-minute easy walk"
            milestone1 = "Build a base"; milestone2 = "Extend distance"; milestone3 = "Race-ready"
        } else if t.contains("write") || t.contains("book") || t.contains("novel") || t.contains("blog") {
            coreTask = "Writing session"; supportTask = "Outline & review"
            minimumTask = "Write 100 words"
            milestone1 = "Find the routine"; milestone2 = "Draft the bulk"; milestone3 = "Revise & finish"
        } else if t.contains("learn") || t.contains("spanish") || t.contains("language") || t.contains("study") || t.contains("code") {
            coreTask = "Study / practice session"; supportTask = "Review & flashcards"
            minimumTask = "5-minute review"
            milestone1 = "Foundations"; milestone2 = "Practical fluency"; milestone3 = "Real-world use"
        } else if t.contains("meditat") || t.contains("mindful") || t.contains("sleep") || t.contains("habit") {
            coreTask = "Practice session"; supportTask = "Weekly reflection"
            minimumTask = "2-minute version"
            milestone1 = "Get started"; milestone2 = "Make it stick"; milestone3 = "Make it effortless"
        } else {
            coreTask = "Focused work session"; supportTask = "Plan & reflect"
            minimumTask = "5-minute starter step"
            milestone1 = "Get going"; milestone2 = "Build momentum"; milestone3 = "Reach the goal"
        }
    }
}
