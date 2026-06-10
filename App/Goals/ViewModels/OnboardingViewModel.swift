import Foundation
import Observation
import GoalsCore

/// Drives the onboarding conversation (docs/PLAN.md §2.1): a short interview that
/// produces a `GoalSpec`, then an editable plan proposal and constraint card the
/// user confirms. Keeps the model to ≤3 follow-ups via the spec's `isComplete`.
@MainActor
@Observable
final class OnboardingViewModel {
    enum Phase: Equatable {
        case interviewing
        case generatingPlan
        case reviewingProposal
        case creating
        case finished
    }

    private let app: AppContainer
    private let threadID = "onboarding"

    var messages: [ChatMessage] = []
    var phase: Phase = .interviewing
    var isAssistantTyping = false
    var draftSpec: GoalSpec?
    var proposal: PlanProposal?
    var editablePlan: Plan?
    var constraintDraft: ConstraintProfile
    var errorMessage: String?

    init(app: AppContainer) {
        self.app = app
        self.constraintDraft = app.store.profile()
    }

    func start() {
        guard messages.isEmpty else { return }
        messages.append(ChatMessage(
            threadID: threadID, role: .assistant,
            text: "Hey! I'm your goals coach. What's something you've been wanting to do — big or small?"))
    }

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(ChatMessage(threadID: threadID, role: .user, text: trimmed))
        isAssistantTyping = true
        defer { isAssistantTyping = false }

        do {
            let result = try await app.llm.interview(history: messages, draft: draftSpec)
            draftSpec = result.spec
            messages.append(ChatMessage(threadID: threadID, role: .assistant, text: result.assistantMessage))
            if result.spec.isComplete {
                await generatePlan(spec: result.spec)
            }
        } catch {
            errorMessage = friendly(error)
        }
    }

    private func generatePlan(spec: GoalSpec) async {
        phase = .generatingPlan
        do {
            let proposal = try await app.llm.generatePlan(spec: spec, profile: constraintDraft)
            self.proposal = proposal
            self.editablePlan = proposal.materialise(spec: spec, calendar: app.clock.calendar,
                                                     now: app.clock.now())
            phase = .reviewingProposal
        } catch {
            errorMessage = friendly(error)
            phase = .interviewing
        }
    }

    /// Apply a user edit to a template's effort or frequency before accepting.
    func updateTemplate(_ template: TaskTemplate) {
        guard var plan = editablePlan,
              let idx = plan.templates.firstIndex(where: { $0.id == template.id }) else { return }
        plan.templates[idx] = template
        editablePlan = plan
    }

    func removeTemplate(_ id: UUID) {
        editablePlan?.templates.removeAll { $0.id == id }
    }

    /// Confirm the plan: persist constraints, create the goal, finish onboarding.
    func accept() async {
        guard var plan = editablePlan else { return }
        phase = .creating
        plan.goal.weeklyBudgetMinutes = draftSpec?.weeklyBudgetMinutes ?? plan.goal.weeklyBudgetMinutes
        app.store.save(constraintDraft)
        app.planEngine.createGoal(fromEdited: plan)
        app.store.setCompletedOnboarding(true)
        _ = await app.notifications.requestAuthorization()
        app.scheduling.reschedule(goalID: plan.goal.id)
        phase = .finished
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
