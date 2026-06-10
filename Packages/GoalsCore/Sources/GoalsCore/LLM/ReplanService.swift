import Foundation

/// Orchestrates a single replanning request with the validate-and-retry loop
/// described in docs/PLAN.md §3.3: ask the model for a `PlanDiff`, validate it
/// deterministically, and on failure feed the violations back for up to
/// `maxRetries` attempts before giving up gracefully.
///
/// Pure of any UI/network specifics — it depends only on the `LLMService`
/// protocol and the `PlanValidator`, so it is fully unit-testable with a mock.
public struct ReplanService {

    public let llm: LLMService
    public let validator: PlanValidator
    public let maxRetries: Int

    public init(llm: LLMService, validator: PlanValidator, maxRetries: Int = 2) {
        self.llm = llm
        self.validator = validator
        self.maxRetries = maxRetries
    }

    public struct Result: Sendable {
        public var diff: PlanDiff
        /// The plan after applying the diff (for preview); equals input plan for
        /// question-only diffs.
        public var previewPlan: Plan
        public var trigger: RevisionTrigger
    }

    public func proposeRevision(plan: Plan,
                                snapshot: PerformanceSnapshot,
                                profile: ConstraintProfile,
                                trigger: RevisionTrigger,
                                userMessage: String? = nil) async throws -> Result {
        var priorViolations: [String] = []

        for _ in 0...maxRetries {
            let diff = try await llm.replan(plan: plan,
                                            snapshot: snapshot,
                                            trigger: trigger,
                                            userMessage: userMessage,
                                            priorViolations: priorViolations)

            // A question-only diff needs no semantic validation.
            if diff.isQuestionOnly {
                return Result(diff: diff, previewPlan: plan, trigger: trigger)
            }

            let violations = validator.validate(diff, against: plan, profile: profile)
            if violations.isEmpty {
                let preview = PlanMutator().apply(diff, to: plan, calendar: validator.calendar)
                return Result(diff: diff, previewPlan: preview, trigger: trigger)
            }
            priorViolations = violations.map(\.description)
        }

        throw LLMError.validationRejected(priorViolations)
    }
}
