import Foundation

/// The durable "who they are," learned during onboarding and editable later —
/// distinct from `ConstraintProfile` (availability) and `Goal` (wants). Captured
/// so the coach can stay user-obsessed, and **summarised, never dumped** into LLM
/// context (docs/PLAN.md — privacy). Backlog aspirations are the goals surfaced
/// in onboarding but not chosen to start now.
public struct UserProfile: Codable, Sendable, Hashable {
    public var person: PersonSketch
    /// Surfaced-but-deferred goals, to revisit later (the "+" add-goal flow).
    public var backlog: [AspirationDraft]
    public var updatedAt: Date

    public init(person: PersonSketch = PersonSketch(),
                backlog: [AspirationDraft] = [],
                updatedAt: Date = Date()) {
        self.person = person
        self.backlog = backlog
        self.updatedAt = updatedAt
    }

    public var isEmpty: Bool { !person.isGrounded && backlog.isEmpty }
}
