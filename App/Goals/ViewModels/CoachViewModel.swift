import Foundation
import Observation
import GoalsCore

/// Backs the Coach chat (docs/PLAN.md §2.2 tab 3). A thread is either a goal's
/// UUID string or the general thread. Diffs proposed by the coach are rendered
/// as cards and applied through the `PlanEngine` on the user's tap.
@MainActor
@Observable
final class CoachViewModel {
    private let app: AppContainer
    let threadID: String
    let goalID: UUID?

    var messages: [ChatMessage] = []
    var isAssistantTyping = false
    var errorMessage: String?

    init(app: AppContainer, goalID: UUID?) {
        self.app = app
        self.goalID = goalID
        self.threadID = goalID?.uuidString ?? ChatMessage.generalThreadID
    }

    func load() {
        messages = app.coach.history(threadID: threadID)
        if messages.isEmpty {
            let opener = goalID != nil
                ? "How's it going with your goal? Tell me what's working or what's not, and we'll adjust."
                : "Hey! Ask me anything, tell me how a goal's going, or say what you'd like to change."
            app.coach.addSystemMessage(opener, threadID: threadID)
            messages = app.coach.history(threadID: threadID)
        }
    }

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isAssistantTyping = true
        defer { isAssistantTyping = false }
        do {
            _ = try await app.coach.send(trimmed, threadID: threadID, goalID: goalID)
        } catch {
            errorMessage = "Couldn't reach the coach just now."
        }
        load()
    }

    /// Apply a diff the coach proposed within a chat card.
    func applyDiff(_ diff: PlanDiff) {
        guard let goalID else { return }
        app.planEngine.apply(diff: diff, to: goalID, trigger: .userRequest)
        app.coach.addSystemMessage("Done — I've updated your plan. ✅", threadID: threadID)
        load()
    }

    func dismissDiff(_ diff: PlanDiff) {
        guard let goalID else { return }
        app.planEngine.recordRejected(diff: diff, goalID: goalID, trigger: .userRequest)
        app.coach.addSystemMessage("No worries — left things as they are.", threadID: threadID)
        load()
    }
}
