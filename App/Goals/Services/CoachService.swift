import Foundation
import GoalsCore

/// Drives the Coach chat (docs/PLAN.md §2.2 tab 3, §3.3 use #4). Persists the
/// conversation, calls the LLM with only the relevant goal summary + compact
/// snapshot (privacy: §7), and returns the assistant message — which may carry a
/// proposed `PlanDiff` rendered as a native card.
@MainActor
final class CoachService {
    private let chat: ChatRepository
    private let goals: GoalRepository
    private let performance: PerformanceService
    private let llm: LLMService
    private let clock: Clock

    init(chat: ChatRepository,
         goals: GoalRepository,
         performance: PerformanceService,
         llm: LLMService,
         clock: Clock) {
        self.chat = chat
        self.goals = goals
        self.performance = performance
        self.llm = llm
        self.clock = clock
    }

    func history(threadID: String) -> [ChatMessage] {
        chat.messages(threadID: threadID)
    }

    /// Send a user message and get the assistant's reply, persisting both.
    /// `goalID` scopes the conversation to a goal (nil = general thread).
    @discardableResult
    func send(_ text: String, threadID: String, goalID: UUID?) async throws -> ChatMessage {
        let userMessage = ChatMessage(threadID: threadID, role: .user, text: text, createdAt: clock.now())
        chat.add(userMessage)

        let plan = goalID.flatMap { goals.plan(for: $0) }
        let snapshot = plan.map { performance.snapshot(for: $0) }
        let history = chat.messages(threadID: threadID)

        let reply = try await llm.coachTurn(plan: plan, snapshot: snapshot,
                                            history: history, userMessage: text)

        let artifact: ChatArtifact? = reply.proposedDiff.map { .planDiff($0) }
        let assistantMessage = ChatMessage(threadID: threadID, role: .assistant,
                                           text: reply.message, artifact: artifact,
                                           createdAt: clock.now())
        chat.add(assistantMessage)
        return assistantMessage
    }

    func addSystemMessage(_ text: String, threadID: String, artifact: ChatArtifact? = nil) {
        chat.add(ChatMessage(threadID: threadID, role: .assistant, text: text,
                             artifact: artifact, createdAt: clock.now()))
    }
}
