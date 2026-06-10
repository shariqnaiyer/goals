import Foundation

public enum ChatRole: String, Codable, Sendable {
    case user, assistant, system
}

/// A structured artifact attached to a chat message and rendered as a native,
/// editable card rather than prose (docs/PLAN.md §2.1 "hybrid chat").
public enum ChatArtifact: Codable, Sendable, Hashable {
    case constraintDraft(ConstraintProfile)
    case planProposal(PlanProposal)
    case planDiff(PlanDiff)
    case clarifyingChoices([String])
}

public struct ChatMessage: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    /// Thread key: a goal's UUID string, or "general".
    public var threadID: String
    public var role: ChatRole
    public var text: String
    public var artifact: ChatArtifact?
    public var createdAt: Date

    public init(id: UUID = UUID(),
                threadID: String,
                role: ChatRole,
                text: String,
                artifact: ChatArtifact? = nil,
                createdAt: Date = Date()) {
        self.id = id
        self.threadID = threadID
        self.role = role
        self.text = text
        self.artifact = artifact
        self.createdAt = createdAt
    }

    public static let generalThreadID = "general"
}

// MARK: - PlanRevision (audit log)

public enum RevisionTrigger: String, Codable, Sendable {
    case userRequest, missedTasks, weeklyReview, goalEdited, overcommitted, initialPlan
}

/// One entry in a goal's plan history — every applied or rejected diff, with the
/// LLM's rationale. Powers the auditable "plan history" UI (docs/PLAN.md §2.2).
public struct PlanRevision: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public var goalID: UUID
    public var timestamp: Date
    public var trigger: RevisionTrigger
    public var diff: PlanDiff
    public var rationale: String
    public var accepted: Bool

    public init(id: UUID = UUID(),
                goalID: UUID,
                timestamp: Date = Date(),
                trigger: RevisionTrigger,
                diff: PlanDiff,
                rationale: String,
                accepted: Bool) {
        self.id = id
        self.goalID = goalID
        self.timestamp = timestamp
        self.trigger = trigger
        self.diff = diff
        self.rationale = rationale
        self.accepted = accepted
    }
}
