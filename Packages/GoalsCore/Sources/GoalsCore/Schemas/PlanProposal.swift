import Foundation

/// The LLM's proposed decomposition of a `GoalSpec` into milestones and task
/// templates (docs/PLAN.md §3.3 use #2). Rendered as an editable card, then
/// materialised into domain entities by `PlanProposal.materialise`.
public struct PlanProposal: Codable, Sendable, Hashable {
    public var goalTitle: String
    public var successCriteria: String
    public var milestones: [ProposedMilestone]
    public var templates: [ProposedTemplate]

    public init(goalTitle: String,
                successCriteria: String,
                milestones: [ProposedMilestone],
                templates: [ProposedTemplate]) {
        self.goalTitle = goalTitle
        self.successCriteria = successCriteria
        self.milestones = milestones
        self.templates = templates
    }
}

public struct ProposedMilestone: Codable, Sendable, Hashable {
    /// A stable key the model uses to reference this milestone from templates.
    public var key: String
    public var title: String
    public var order: Int
    public var completionCriteria: String
    /// ISO `yyyy-MM-dd`, optional.
    public var targetDate: String?

    public init(key: String, title: String, order: Int,
                completionCriteria: String, targetDate: String?) {
        self.key = key
        self.title = title
        self.order = order
        self.completionCriteria = completionCriteria
        self.targetDate = targetDate
    }
}

public struct ProposedTemplate: Codable, Sendable, Hashable {
    public var title: String
    /// References a `ProposedMilestone.key`, or nil for goal-level tasks.
    public var milestoneKey: String?
    public var effortMinutes: Int
    public var cadence: RecurrenceRule.Cadence
    public var weekdays: [Weekday]
    public var timesPerWeek: Int
    public var intervalDays: Int
    public var preferredTimeOfDay: TimeOfDay?
    public var flexibility: Flexibility
    public var minimumViableVariant: String?

    public init(title: String,
                milestoneKey: String?,
                effortMinutes: Int,
                cadence: RecurrenceRule.Cadence,
                weekdays: [Weekday],
                timesPerWeek: Int,
                intervalDays: Int,
                preferredTimeOfDay: TimeOfDay?,
                flexibility: Flexibility,
                minimumViableVariant: String?) {
        self.title = title
        self.milestoneKey = milestoneKey
        self.effortMinutes = effortMinutes
        self.cadence = cadence
        self.weekdays = weekdays
        self.timesPerWeek = timesPerWeek
        self.intervalDays = intervalDays
        self.preferredTimeOfDay = preferredTimeOfDay
        self.flexibility = flexibility
        self.minimumViableVariant = minimumViableVariant
    }

    func recurrence() -> RecurrenceRule {
        RecurrenceRule(cadence: cadence,
                       weekdays: Set(weekdays),
                       timesPerWeek: timesPerWeek,
                       interval: intervalDays)
    }
}

public extension PlanProposal {
    /// Turn the proposal into a concrete `Plan` of domain entities, assigning
    /// real UUIDs and resolving milestone keys to milestone IDs.
    func materialise(spec: GoalSpec, calendar: Calendar, now: Date = Date()) -> Plan {
        let goal = Goal(title: goalTitle.isEmpty ? spec.title : goalTitle,
                        motivationStatement: spec.motivationStatement,
                        type: spec.type,
                        successCriteria: successCriteria.isEmpty ? spec.successCriteria : successCriteria,
                        targetDate: spec.targetCalendarDay(calendar: calendar),
                        status: .active,
                        createdAt: now,
                        weeklyBudgetMinutes: spec.weeklyBudgetMinutes)

        var keyToID: [String: UUID] = [:]
        let milestones = milestones.sorted { $0.order < $1.order }.map { pm -> Milestone in
            let id = UUID()
            keyToID[pm.key] = id
            return Milestone(id: id,
                             goalID: goal.id,
                             title: pm.title,
                             order: pm.order,
                             targetDate: isoDay(pm.targetDate, calendar: calendar),
                             completionCriteria: pm.completionCriteria,
                             status: pm.order == 0 ? .inProgress : .upcoming)
        }

        let templates = templates.map { pt -> TaskTemplate in
            var windows: [Weekday: MinuteWindow] = [:]
            if let tod = pt.preferredTimeOfDay {
                let start = tod.representativeWindowStart
                let window = MinuteWindow(start: start, end: min(start + pt.effortMinutes, 24 * 60))
                let days = pt.weekdays.isEmpty ? Array(Weekday.allCases) : pt.weekdays
                for d in days { windows[d] = window }
            }
            return TaskTemplate(goalID: goal.id,
                                milestoneID: pt.milestoneKey.flatMap { keyToID[$0] },
                                title: pt.title,
                                effortMinutes: pt.effortMinutes,
                                recurrence: pt.recurrence(),
                                preferredWindows: windows,
                                flexibility: pt.flexibility,
                                minimumViableVariant: pt.minimumViableVariant)
        }

        return Plan(goal: goal, milestones: milestones, templates: templates)
    }

    private func isoDay(_ string: String?, calendar: Calendar) -> CalendarDay? {
        guard let string else { return nil }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: string).map { CalendarDay(date: $0, calendar: calendar) }
    }
}
