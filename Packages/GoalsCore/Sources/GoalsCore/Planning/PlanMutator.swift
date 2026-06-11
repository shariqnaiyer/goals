import Foundation

/// Applies a (validated) `PlanDiff` to a `Plan`, purely. The app persists the
/// returned plan inside a transaction and re-runs the Scheduler afterwards
/// (docs/PLAN.md §5). No occurrence is touched here — only the *intent* layer
/// (goal, milestones, templates) changes; completed history is never rewritten.
public struct PlanMutator {

    public init() {}

    public func apply(_ diff: PlanDiff, to plan: Plan, calendar: Calendar = .current) -> Plan {
        var result = plan
        for op in diff.operations {
            apply(op, to: &result, calendar: calendar)
        }
        return result
    }

    private func apply(_ op: PlanOperation, to plan: inout Plan, calendar: Calendar) {
        switch op.kind {
        case .addTemplate:
            guard let proposed = op.newTemplate else { return }
            let milestoneID = proposed.milestoneKey.flatMap { UUID(uuidString: $0) }
            var windows: [Weekday: MinuteWindow] = [:]
            if let tod = proposed.preferredTimeOfDay {
                let start = tod.representativeWindowStart
                let window = MinuteWindow(start: start, end: min(start + proposed.effortMinutes, 24 * 60))
                let days = proposed.weekdays.isEmpty ? Array(Weekday.allCases) : proposed.weekdays
                for d in days { windows[d] = window }
            }
            plan.templates.append(TaskTemplate(
                goalID: plan.goal.id,
                milestoneID: milestoneID,
                title: proposed.title,
                effortMinutes: proposed.effortMinutes,
                recurrence: proposed.recurrence(),
                preferredWindows: windows,
                flexibility: proposed.flexibility,
                minimumViableVariant: proposed.minimumViableVariant))

        case .removeTemplate, .pauseTemplate:
            // Soft-deactivate rather than delete, so the change is reversible
            // from plan history and never orphans past occurrences.
            mutateTemplate(op.targetTemplateID, in: &plan) { $0.isActive = false }

        case .resumeTemplate:
            mutateTemplate(op.targetTemplateID, in: &plan) { $0.isActive = true }

        case .modifyTemplate:
            mutateTemplate(op.targetTemplateID, in: &plan) { t in
                if let title = op.newTitle { t.title = title }
                if let effort = op.newEffortMinutes { t.effortMinutes = effort }
                if let times = op.newTimesPerWeek {
                    t.recurrence = RecurrenceRule(cadence: .timesPerWeek,
                                                  weekdays: op.newWeekdays.map(Set.init) ?? t.recurrence.weekdays,
                                                  timesPerWeek: times,
                                                  interval: t.recurrence.interval)
                } else if let weekdays = op.newWeekdays {
                    t.recurrence = RecurrenceRule(cadence: .specificWeekdays,
                                                  weekdays: Set(weekdays),
                                                  timesPerWeek: t.recurrence.timesPerWeek,
                                                  interval: t.recurrence.interval)
                }
            }

        case .swapToMinimumViable:
            mutateTemplate(op.targetTemplateID, in: &plan) { t in
                if let mvv = t.minimumViableVariant {
                    t.title = mvv
                }
                // Heuristic: the minimum-viable variant is meaningfully lighter.
                t.effortMinutes = max(10, t.effortMinutes / 2)
            }

        case .addMilestone:
            guard let pm = op.newMilestone else { return }
            let order = pm.order >= 0 ? pm.order : (plan.milestones.map(\.order).max() ?? -1) + 1
            plan.milestones.append(Milestone(
                goalID: plan.goal.id,
                title: pm.title,
                order: order,
                targetDate: isoDay(pm.targetDate, calendar: calendar),
                completionCriteria: pm.completionCriteria))

        case .reorderMilestones:
            guard let ordered = op.orderedMilestoneIDs else { return }
            for (index, id) in ordered.enumerated() {
                mutateMilestone(id, in: &plan) { $0.order = index }
            }

        case .completeMilestone:
            mutateMilestone(op.targetMilestoneID, in: &plan) { $0.status = .completed }

        case .shiftMilestoneTargetDate:
            mutateMilestone(op.targetMilestoneID, in: &plan) {
                $0.targetDate = isoDay(op.newTargetDate, calendar: calendar)
            }

        case .shiftGoalTargetDate:
            plan.goal.targetDate = isoDay(op.newTargetDate, calendar: calendar)

        case .markUnitComplete:
            // Mark a concrete series unit (a chapter) done on the goal's specifics.
            // This is intent (the goal), not occurrence history; the Sequencer
            // re-sequences future sessions around it on the next reschedule.
            guard let unitID = op.targetUnitID else { return }
            plan.goal.specifics?.setUnit(unitID, complete: true)
        }
    }

    // MARK: - Helpers

    private func mutateTemplate(_ id: UUID?, in plan: inout Plan, _ body: (inout TaskTemplate) -> Void) {
        guard let id, let idx = plan.templates.firstIndex(where: { $0.id == id }) else { return }
        body(&plan.templates[idx])
    }

    private func mutateMilestone(_ id: UUID?, in plan: inout Plan, _ body: (inout Milestone) -> Void) {
        guard let id, let idx = plan.milestones.firstIndex(where: { $0.id == id }) else { return }
        body(&plan.milestones[idx])
    }

    private func isoDay(_ string: String?, calendar: Calendar) -> CalendarDay? {
        guard let string else { return nil }
        let f = DateFormatter()
        f.calendar = calendar
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: string).map { CalendarDay(date: $0, calendar: calendar) }
    }
}
