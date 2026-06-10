import Foundation

/// A deterministic, offline `LLMService`. It makes the app fully runnable with
/// no backend or API key (the plan's "works with the mock service" path), drives
/// SwiftUI previews, and gives the test suite a stable oracle. It uses simple
/// keyword heuristics to feel responsive without any network.
public struct MockLLMService: LLMService {

    public var calendar: Calendar
    public init(calendar: Calendar = .current) { self.calendar = calendar }

    // MARK: Interview

    public func interview(history: [ChatMessage], draft: GoalSpec?) async throws -> InterviewResult {
        let userTurns = history.filter { $0.role == .user }
        let latest = userTurns.last?.text ?? ""
        let combined = userTurns.map(\.text).joined(separator: " ").lowercased()

        var spec = draft ?? GoalSpec(
            title: "", motivationStatement: "", type: .outcome, successCriteria: "",
            targetDate: nil, currentLevel: "", weeklyBudgetMinutes: 0,
            isComplete: false, nextQuestion: nil)

        // Turn 1: capture the aspiration.
        if spec.title.isEmpty, !latest.isEmpty {
            spec.title = derivedTitle(from: latest)
            spec.motivationStatement = latest
            spec.type = combined.contains("habit") || combined.contains("regular")
                || combined.contains("every day") ? .habit : .outcome
            spec.nextQuestion = "Love it. Is there a date you'd like to hit this by, or is it open-ended?"
            spec.isComplete = false
            return InterviewResult(spec: spec, assistantMessage: spec.nextQuestion!)
        }

        // Turn 2: deadline.
        if spec.targetDate == nil, spec.currentLevel.isEmpty {
            spec.targetDate = parseRoughDate(latest)
            spec.nextQuestion = "Got it. Where are you starting from today — total beginner, or some experience?"
            return InterviewResult(spec: spec, assistantMessage: spec.nextQuestion!)
        }

        // Turn 3: current level + time budget, then complete.
        if spec.currentLevel.isEmpty {
            spec.currentLevel = latest.isEmpty ? "beginner" : latest
        }
        spec.weeklyBudgetMinutes = parseWeeklyMinutes(combined) ?? 150
        spec.successCriteria = "Make consistent, visible progress toward: \(spec.title)."
        spec.isComplete = true
        spec.nextQuestion = nil
        return InterviewResult(
            spec: spec,
            assistantMessage: "Perfect — I've got enough to sketch a first plan. Here's what I'm thinking 👇")
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
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = cleaned.lowercased()
        for prefix in ["i want to ", "i'd like to ", "i would like to ", "i want ", "help me "] {
            if lower.hasPrefix(prefix) {
                let stripped = String(cleaned.dropFirst(prefix.count))
                return stripped.prefix(1).capitalized + stripped.dropFirst()
            }
        }
        return cleaned.prefix(1).capitalized + cleaned.dropFirst()
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
