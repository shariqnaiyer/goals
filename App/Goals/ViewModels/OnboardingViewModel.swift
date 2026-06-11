import Foundation
import Observation
import GoalsCore

/// Drives the Guided Discovery Interview (docs/PLAN.md — onboarding redesign):
/// ground → surface → concretize (probe loop) → confirm the week → formalize.
///
/// **Swift owns the flow.** The model (`onboardingTurn`) proposes an updated
/// `OnboardingState` each turn; this view model decides stage transitions, runs
/// `ConcretenessCheck` (the authoritative gate + capacity cap), and is the only
/// place goals get created. The composer stays available through every
/// conversational stage (fixing the old lock once a proposal appeared).
@MainActor
@Observable
final class OnboardingViewModel {
    enum Phase: Equatable {
        case grounding, surfacing, concretizing   // conversational — composer visible
        case confirmingConstraints                 // confirm the week
        case generatingPlan
        case reviewingProposal                     // editable plan card(s)
        case creating, finished
    }

    private let app: AppContainer
    private let threadID = "onboarding"

    var messages: [ChatMessage] = []
    var phase: Phase = .grounding
    var isAssistantTyping = false
    /// Chips for the latest coach turn (book choices, "most days", …).
    var currentChoices: [String] = []
    /// The model-held interview state, re-sent on every turn.
    var state = OnboardingState()
    /// Multi-select for the GoalSet card (1–3 to start now).
    var selectedAspirationIDs: Set<String> = []
    /// The week, surfaced for confirmation (fixes the old "saves defaults" bug).
    var constraintDraft: ConstraintProfile = .makeDefault()
    /// One editable plan per chosen goal.
    var editablePlans: [Plan] = []
    var errorMessage: String?

    init(app: AppContainer) {
        self.app = app
        self.constraintDraft = app.store.profile()
    }

    /// `addingGoal` enters mid-flow for an existing user: the person and the week
    /// are already known, so it skips grounding and starts at surfacing.
    func start(addingGoal: Bool = false) {
        guard messages.isEmpty else { return }
        if addingGoal {
            let existing = app.store.userProfile()
            if existing.person.isGrounded {
                state.person = existing.person
                state.stage = .surfacing
                phase = .surfacing
                appendAssistant("Good to see you back. What do you want to take on next? "
                    + "I'll keep what I already know about your week in mind.")
                return
            }
        }
        phase = .grounding
        appendAssistant("Hey — I'm your coach, and I learn fast, so this won't take long. "
            + "Tell me a bit about your life right now and what you've been wanting to change — ramble if you want.")
    }

    // MARK: Conversational turns

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await runTurn(trimmed, userBubble: trimmed)
    }

    /// Tapping a chip is just sending that text.
    func choose(_ choice: String) async { await send(choice) }

    private func runTurn(_ userText: String, userBubble: String?) async {
        if let userBubble { messages.append(ChatMessage(threadID: threadID, role: .user, text: userBubble)) }
        currentChoices = []
        isAssistantTyping = true
        defer { isAssistantTyping = false }
        do {
            let result = try await app.llm.onboardingTurn(state: state, latestUserText: userText)
            apply(result)
        } catch {
            errorMessage = friendly(error)
        }
    }

    private func apply(_ result: OnboardingTurnResult) {
        state = result.state
        appendAssistant(result.assistantMessage)
        currentChoices = result.choices

        switch result.stage {
        case .grounding:    phase = .grounding
        case .surfacing:    phase = .surfacing
        case .concretizing: phase = .concretizing
        case .readyToFormalize:
            // The model's "ready" is advisory — Swift's gate is authoritative.
            if ConcretenessCheck.canFormalize(state, availableWeeklyMinutes: constraintDraft.weeklyCapacityMinutes) {
                phase = .confirmingConstraints
            } else {
                phase = .concretizing
                let notes = ConcretenessCheck.blockers(state, availableWeeklyMinutes: constraintDraft.weeklyCapacityMinutes)
                if let first = notes.first {
                    appendAssistant("Before I lock this in — \(first). Let's sort that.")
                }
            }
        }
    }

    // MARK: Stage 2 — choosing which goals to start now

    /// Whether the GoalSet selection card should be shown.
    var isChoosingGoals: Bool {
        phase == .surfacing && !state.aspirations.isEmpty && state.focusAspirationIDs.isEmpty
    }

    func toggleAspiration(_ id: String) {
        if selectedAspirationIDs.contains(id) {
            selectedAspirationIDs.remove(id)
        } else if selectedAspirationIDs.count < 3 {
            selectedAspirationIDs.insert(id)
        }
    }

    var canStartSelected: Bool { (1...3).contains(selectedAspirationIDs.count) }

    func startWithSelected() async {
        guard canStartSelected else { return }
        // Preserve the surfaced order.
        let ordered = state.aspirations.map(\.id).filter { selectedAspirationIDs.contains($0) }
        state.focusAspirationIDs = ordered
        let titles = state.focusAspirations.map(\.title).joined(separator: ", ")
        await runTurn("", userBubble: "Let's start with: \(titles).")
    }

    // MARK: Stage 4 — confirm the week, then generate plans

    func confirmConstraints() async {
        phase = .generatingPlan
        app.store.save(constraintDraft)
        do {
            var plans: [Plan] = []
            for aspiration in state.focusAspirations {
                let spec = aspiration.toGoalSpec()
                let proposal = try await app.llm.generatePlan(spec: spec, profile: constraintDraft)
                plans.append(proposal.materialise(spec: spec,
                                                  calendar: app.clock.calendar,
                                                  now: app.clock.now()))
            }
            editablePlans = plans
            phase = .reviewingProposal
        } catch {
            errorMessage = friendly(error)
            phase = .confirmingConstraints
        }
    }

    /// Combined weekly load of the chosen goals, for the confirmation summary.
    var combinedWeeklyMinutes: Int { ConcretenessCheck.combinedWeeklyMinutes(state) }

    // MARK: Editing the proposals

    func updateTemplate(planID: UUID, _ template: TaskTemplate) {
        guard let pi = editablePlans.firstIndex(where: { $0.goal.id == planID }),
              let ti = editablePlans[pi].templates.firstIndex(where: { $0.id == template.id }) else { return }
        editablePlans[pi].templates[ti] = template
    }

    func removeTemplate(planID: UUID, _ id: UUID) {
        guard let pi = editablePlans.firstIndex(where: { $0.goal.id == planID }) else { return }
        editablePlans[pi].templates.removeAll { $0.id == id }
    }

    // MARK: Stage 5 — formalize

    func accept() async {
        guard !editablePlans.isEmpty else { return }
        phase = .creating
        app.store.save(constraintDraft)
        // Persist the learned person + backlog, merging with any prior profile so
        // adding a goal never wipes earlier context.
        let existing = app.store.userProfile()
        let person = state.person.isGrounded ? state.person : existing.person
        var backlog = existing.backlog
        for aspiration in state.backlogAspirations where !backlog.contains(where: { $0.id == aspiration.id }) {
            backlog.append(aspiration)
        }
        app.store.save(UserProfile(person: person, backlog: backlog, updatedAt: app.clock.now()))
        for plan in editablePlans {
            app.planEngine.createGoal(fromEdited: plan)
        }
        app.store.setCompletedOnboarding(true)
        _ = await app.notifications.requestAuthorization()
        for plan in editablePlans {
            app.scheduling.reschedule(goalID: plan.goal.id)
        }
        phase = .finished
    }

    // MARK: Helpers

    private func appendAssistant(_ text: String) {
        messages.append(ChatMessage(threadID: threadID, role: .assistant, text: text))
    }

    private func friendly(_ error: Error) -> String {
        if let llm = error as? LLMError {
            switch llm {
            case .offline, .transport: return "I'm having trouble connecting. Mind trying again?"
            default: return "Something went sideways on my end — let's try that again."
            }
        }
        return "Something went sideways on my end — let's try that again."
    }
}
