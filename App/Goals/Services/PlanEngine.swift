import Foundation
import GoalsCore

/// The application-level orchestrator that ties the pure planning logic to
/// persistence and rescheduling (docs/PLAN.md §3.1 "domain PlanEngine layer").
/// Every plan mutation flows through here so it is always: validated → applied
/// → persisted (transactionally) → rescheduled → recorded in plan history.
@MainActor
final class PlanEngine {
    private let goals: GoalRepository
    private let revisions: RevisionRepository
    private let constraints: ConstraintRepository
    private let performance: PerformanceService
    private let scheduling: SchedulingCoordinator
    private let llm: LLMService
    private let clock: Clock

    init(goals: GoalRepository,
         revisions: RevisionRepository,
         constraints: ConstraintRepository,
         performance: PerformanceService,
         scheduling: SchedulingCoordinator,
         llm: LLMService,
         clock: Clock) {
        self.goals = goals
        self.revisions = revisions
        self.constraints = constraints
        self.performance = performance
        self.scheduling = scheduling
        self.llm = llm
        self.clock = clock
    }

    private var validator: PlanValidator { PlanValidator(calendar: clock.calendar) }

    // MARK: Goal creation

    /// Generate and persist a brand-new plan from a completed onboarding spec.
    func createGoal(from spec: GoalSpec) async throws -> Plan {
        let profile = constraints.profile()
        let proposal = try await llm.generatePlan(spec: spec, profile: profile)
        let plan = proposal.materialise(spec: spec, calendar: clock.calendar, now: clock.now())
        goals.save(plan: plan)
        revisions.add(PlanRevision(goalID: plan.goal.id, trigger: .initialPlan,
                                   diff: PlanDiff(summary: "Created your starting plan."),
                                   rationale: "Initial plan generated from onboarding.",
                                   accepted: true))
        scheduling.reschedule(goalID: plan.goal.id)
        return plan
    }

    /// Persist an edited proposal (when the user tweaks the onboarding card before accepting).
    func createGoal(fromEdited plan: Plan) {
        goals.save(plan: plan)
        revisions.add(PlanRevision(goalID: plan.goal.id, trigger: .initialPlan,
                                   diff: PlanDiff(summary: "Created your starting plan."),
                                   rationale: "Initial plan (user-edited) accepted.",
                                   accepted: true))
        scheduling.reschedule(goalID: plan.goal.id)
    }

    // MARK: Adaptation

    /// Ask the LLM (with validate-and-retry) for a revision proposal to preview.
    func proposeRevision(goalID: UUID,
                         trigger: RevisionTrigger,
                         userMessage: String? = nil) async throws -> ReplanService.Result {
        guard let plan = goals.plan(for: goalID) else { throw LLMError.notConfigured }
        let snapshot = performance.snapshot(for: plan)
        let service = ReplanService(llm: llm, validator: validator)
        return try await service.proposeRevision(plan: plan, snapshot: snapshot,
                                                 profile: constraints.profile(),
                                                 trigger: trigger, userMessage: userMessage)
    }

    /// Apply a previewed diff the user accepted, then persist + reschedule.
    func apply(diff: PlanDiff, to goalID: UUID, trigger: RevisionTrigger) {
        guard let plan = goals.plan(for: goalID) else { return }
        guard validator.validate(diff, against: plan, profile: constraints.profile()).isEmpty else {
            return
        }
        let updated = PlanMutator().apply(diff, to: plan, calendar: clock.calendar)
        goals.save(plan: updated)
        revisions.add(PlanRevision(goalID: goalID, trigger: trigger, diff: diff,
                                   rationale: diff.summary, accepted: true))
        scheduling.reschedule(goalID: goalID)
    }

    /// Record that the user rejected a proposed diff (kept in history as signal).
    func recordRejected(diff: PlanDiff, goalID: UUID, trigger: RevisionTrigger) {
        revisions.add(PlanRevision(goalID: goalID, trigger: trigger, diff: diff,
                                   rationale: diff.summary, accepted: false))
    }

    // MARK: Lifecycle changes (docs/PLAN.md §5 "changing goals")

    func setStatus(_ status: GoalStatus, for goalID: UUID, reason: String? = nil) {
        guard var goal = goals.goal(goalID) else { return }
        goal.status = status
        if let reason { goal.archivedReason = reason }
        goals.updateGoal(goal)
        scheduling.reschedule(goalID: goalID) // clears pending if paused/abandoned
    }
}
