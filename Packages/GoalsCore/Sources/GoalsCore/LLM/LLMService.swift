import Foundation

/// The boundary to the language model (docs/PLAN.md §3.3). Concrete conformances
/// live in the app (a networking client to the proxy) and in tests/previews
/// (`MockLLMService`). Keeping this protocol in the pure core means all
/// orchestration logic — the validation-retry loop, adaptation triggering — is
/// testable without a network.
public protocol LLMService: Sendable {

    /// Onboarding turn (use #1) — one step of the multi-stage Guided Discovery
    /// Interview. The whole `OnboardingState` is client-held and re-sent each
    /// turn (the proxy is stateless); the model returns an updated state, the
    /// coach's next line, and chips. Whether the app may formalize is decided by
    /// `ConcretenessCheck`, not the model's `stage`.
    func onboardingTurn(state: OnboardingState, latestUserText: String) async throws -> OnboardingTurnResult

    /// Goal decomposition (use #2).
    func generatePlan(spec: GoalSpec, profile: ConstraintProfile) async throws -> PlanProposal

    /// Replanning (use #3). Returns a `PlanDiff` of operations against `plan`,
    /// or a question-only diff when the situation is ambiguous.
    func replan(plan: Plan,
                snapshot: PerformanceSnapshot,
                trigger: RevisionTrigger,
                userMessage: String?,
                priorViolations: [String]) async throws -> PlanDiff

    /// Coach conversation turn (use #4). May attach a proposed `PlanDiff`.
    func coachTurn(plan: Plan?,
                   snapshot: PerformanceSnapshot?,
                   history: [ChatMessage],
                   userMessage: String) async throws -> CoachReply

    /// Weekly review narrative (use #5).
    func reviewNarrative(snapshot: PerformanceSnapshot, plan: Plan) async throws -> String
}


public struct CoachReply: Sendable, Hashable {
    public var message: String
    public var proposedDiff: PlanDiff?
    public init(message: String, proposedDiff: PlanDiff? = nil) {
        self.message = message
        self.proposedDiff = proposedDiff
    }
}

public enum LLMError: Error, Sendable, Equatable {
    /// The model's output could not be decoded even after a repair round-trip.
    case decodingFailed(String)
    /// A proposed diff failed validation after the retry budget was exhausted.
    case validationRejected([String])
    case transport(String)
    /// No backend configured (no API base / key). The app falls back to the
    /// mock service or surfaces an offline state.
    case notConfigured
    case offline
}

/// Prompt and schema versions are pinned and surfaced so the proxy can route to
/// the correct server-side prompt (docs/PLAN.md §3.2) and the eval suite can key
/// golden outputs by version.
public enum PromptVersion {
    public static let onboarding = "onboarding-v1"
    public static let planGeneration = "plan-generation-v1"
    public static let replan = "replan-v1"
    public static let coach = "coach-v1"
    public static let review = "review-v1"
    public static let schema = "schema-v2"
}
