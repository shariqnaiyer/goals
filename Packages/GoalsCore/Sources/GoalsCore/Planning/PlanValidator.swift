import Foundation

/// Deterministic semantic validation of an LLM-proposed `PlanDiff`
/// (docs/PLAN.md §3.3 "semantic validation after syntactic"). A diff that
/// fails validation is rejected back to the model with the violation list,
/// never applied. This is the guardrail that keeps the LLM honest.
public struct PlanValidator {

    public struct Violation: Sendable, Hashable, CustomStringConvertible {
        public enum Code: String, Sendable {
            case unknownTemplate, unknownMilestone, unknownUnit, badEffort, badFrequency
            case badDate, reorderMismatch, overBudget, emptyDiff, missingPayload
        }
        public var code: Code
        public var detail: String
        public var description: String { "\(code.rawValue): \(detail)" }
    }

    public var calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// Validate `diff` against `plan` and `profile`. Returns an empty array if
    /// the diff is safe to preview/apply.
    public func validate(_ diff: PlanDiff, against plan: Plan, profile: ConstraintProfile) -> [Violation] {
        var violations: [Violation] = []

        if diff.isEmpty {
            violations.append(.init(code: .emptyDiff, detail: "Diff has no operations and no question."))
            return violations
        }
        // A question-only diff is always valid.
        if diff.isQuestionOnly { return [] }

        let templateIDs = Set(plan.templates.map(\.id))
        let milestoneIDs = Set(plan.milestones.map(\.id))

        for op in diff.operations {
            switch op.kind {
            case .removeTemplate, .swapToMinimumViable, .pauseTemplate, .resumeTemplate, .modifyTemplate:
                if let id = op.targetTemplateID {
                    if !templateIDs.contains(id) {
                        violations.append(.init(code: .unknownTemplate, detail: "No template \(id)."))
                    }
                } else {
                    violations.append(.init(code: .missingPayload, detail: "\(op.kind.rawValue) needs targetTemplateID."))
                }
                if let effort = op.newEffortMinutes, effort <= 0 {
                    violations.append(.init(code: .badEffort, detail: "effort must be > 0."))
                }
                if let times = op.newTimesPerWeek, times < 0 || times > 21 {
                    violations.append(.init(code: .badFrequency, detail: "timesPerWeek out of range."))
                }

            case .addTemplate:
                guard let t = op.newTemplate else {
                    violations.append(.init(code: .missingPayload, detail: "addTemplate needs newTemplate."))
                    continue
                }
                if t.effortMinutes <= 0 {
                    violations.append(.init(code: .badEffort, detail: "new template effort must be > 0."))
                }
                if let key = t.milestoneKey, let uuid = UUID(uuidString: key), !milestoneIDs.contains(uuid) {
                    violations.append(.init(code: .unknownMilestone, detail: "milestoneKey \(key) not found."))
                }

            case .addMilestone:
                if op.newMilestone == nil {
                    violations.append(.init(code: .missingPayload, detail: "addMilestone needs newMilestone."))
                }

            case .completeMilestone, .shiftMilestoneTargetDate:
                if let id = op.targetMilestoneID {
                    if !milestoneIDs.contains(id) {
                        violations.append(.init(code: .unknownMilestone, detail: "No milestone \(id)."))
                    }
                } else {
                    violations.append(.init(code: .missingPayload, detail: "\(op.kind.rawValue) needs targetMilestoneID."))
                }
                if op.kind == .shiftMilestoneTargetDate { validateDate(op.newTargetDate, into: &violations) }

            case .shiftGoalTargetDate:
                validateDate(op.newTargetDate, into: &violations)

            case .reorderMilestones:
                let provided = Set(op.orderedMilestoneIDs ?? [])
                if provided != milestoneIDs {
                    violations.append(.init(code: .reorderMismatch,
                                            detail: "reorder must list exactly the existing milestone IDs."))
                }

            case .markUnitComplete:
                if let id = op.targetUnitID {
                    let unitIDs = Set(plan.goal.specifics?.seriesUnits.map(\.id) ?? [])
                    if !unitIDs.contains(id) {
                        violations.append(.init(code: .unknownUnit, detail: "No series unit \(id)."))
                    }
                } else {
                    violations.append(.init(code: .missingPayload, detail: "markUnitComplete needs targetUnitID."))
                }
            }
        }

        // Budget check: simulate the apply and compare weekly load to the budget.
        if violations.isEmpty {
            let applied = PlanMutator().apply(diff, to: plan, calendar: calendar)
            let budget = plan.goal.weeklyBudgetMinutes
            if budget > 0 {
                // Allow a 15% grace so a single tweak isn't blocked by a rounding edge.
                let ceiling = Int(Double(budget) * 1.15)
                if applied.weeklyLoadMinutes > ceiling {
                    violations.append(.init(code: .overBudget,
                        detail: "Resulting weekly load \(applied.weeklyLoadMinutes)m exceeds budget \(budget)m."))
                }
            }
        }

        return violations
    }

    private func validateDate(_ string: String?, into violations: inout [Violation]) {
        guard let string else {
            violations.append(.init(code: .missingPayload, detail: "date operation needs newTargetDate."))
            return
        }
        let f = DateFormatter()
        f.calendar = calendar
        f.dateFormat = "yyyy-MM-dd"
        if f.date(from: string) == nil {
            violations.append(.init(code: .badDate, detail: "\(string) is not yyyy-MM-dd."))
        }
    }
}
