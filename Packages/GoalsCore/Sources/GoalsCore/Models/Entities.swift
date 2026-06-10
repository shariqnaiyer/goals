import Foundation

// MARK: - Goal

public enum GoalType: String, Codable, Sendable {
    /// A goal with a definite end state ("run a 10k", "ship the app").
    case outcome
    /// An ongoing practice with no terminal state ("meditate regularly").
    case habit
}

public enum GoalStatus: String, Codable, Sendable {
    case active, paused, completed, abandoned
}

/// The top-level user aspiration, decomposed into milestones and task templates.
public struct Goal: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public var title: String
    /// Captured at onboarding and replayed by the coach when motivation dips.
    public var motivationStatement: String
    public var type: GoalType
    public var successCriteria: String
    public var targetDate: CalendarDay?
    public var status: GoalStatus
    public var createdAt: Date
    public var archivedReason: String?
    /// Honest weekly time budget in minutes, captured at onboarding.
    public var weeklyBudgetMinutes: Int

    public init(id: UUID = UUID(),
                title: String,
                motivationStatement: String = "",
                type: GoalType,
                successCriteria: String = "",
                targetDate: CalendarDay? = nil,
                status: GoalStatus = .active,
                createdAt: Date = Date(),
                archivedReason: String? = nil,
                weeklyBudgetMinutes: Int = 0) {
        self.id = id
        self.title = title
        self.motivationStatement = motivationStatement
        self.type = type
        self.successCriteria = successCriteria
        self.targetDate = targetDate
        self.status = status
        self.createdAt = createdAt
        self.archivedReason = archivedReason
        self.weeklyBudgetMinutes = weeklyBudgetMinutes
    }
}

// MARK: - Milestone

public enum MilestoneStatus: String, Codable, Sendable {
    case upcoming, inProgress, completed
}

public struct Milestone: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public var goalID: UUID
    public var title: String
    public var order: Int
    public var targetDate: CalendarDay?
    public var completionCriteria: String
    public var status: MilestoneStatus

    public init(id: UUID = UUID(),
                goalID: UUID,
                title: String,
                order: Int,
                targetDate: CalendarDay? = nil,
                completionCriteria: String = "",
                status: MilestoneStatus = .upcoming) {
        self.id = id
        self.goalID = goalID
        self.title = title
        self.order = order
        self.targetDate = targetDate
        self.completionCriteria = completionCriteria
        self.status = status
    }
}

// MARK: - TaskTemplate

/// How free the Scheduler is to place a task in time.
public enum Flexibility: String, Codable, Sendable {
    /// Must occur at a specific window (e.g. a class).
    case fixed
    /// Prefers its windows but can be moved to fit availability.
    case flexible
    /// Any free slot is fine.
    case anytime
}

/// The recurring *intent* — e.g. "Run 5k, 3×/week, mornings preferred."
/// Adaptation rewrites templates; the Scheduler expands them into occurrences.
public struct TaskTemplate: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public var goalID: UUID
    public var milestoneID: UUID?
    public var title: String
    public var effortMinutes: Int
    public var recurrence: RecurrenceRule
    /// Preferred windows by weekday; the Scheduler honours these first.
    public var preferredWindows: [Weekday: MinuteWindow]
    public var flexibility: Flexibility
    /// A lighter fallback for bad days ("10-min walk" for "5k run"); drives
    /// the daily-minimum UI and adaptation's "shrink effort" operation.
    public var minimumViableVariant: String?
    /// `false` once adaptation or the user pauses just this template.
    public var isActive: Bool

    public init(id: UUID = UUID(),
                goalID: UUID,
                milestoneID: UUID? = nil,
                title: String,
                effortMinutes: Int,
                recurrence: RecurrenceRule,
                preferredWindows: [Weekday: MinuteWindow] = [:],
                flexibility: Flexibility = .flexible,
                minimumViableVariant: String? = nil,
                isActive: Bool = true) {
        self.id = id
        self.goalID = goalID
        self.milestoneID = milestoneID
        self.title = title
        self.effortMinutes = effortMinutes
        self.recurrence = recurrence
        self.preferredWindows = preferredWindows
        self.flexibility = flexibility
        self.minimumViableVariant = minimumViableVariant
        self.isActive = isActive
    }

    /// Estimated weekly load in minutes — input to the budget validator.
    public var weeklyLoadMinutes: Int {
        recurrence.occurrencesPerWeek * effortMinutes
    }
}

// MARK: - TaskOccurrence

public enum OccurrenceStatus: String, Codable, Sendable {
    case pending, done, skipped, rescheduled
}

/// A concrete, schedulable instance of a `TaskTemplate` on a given day/window.
/// The template/occurrence split lets adaptation rewrite *future* occurrences
/// without falsifying completed history (docs/PLAN.md §4).
public struct TaskOccurrence: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public var templateID: UUID?
    public var goalID: UUID
    public var title: String
    public var effortMinutes: Int
    public var day: CalendarDay
    public var window: MinuteWindow?
    public var status: OccurrenceStatus
    public var completedAt: Date?
    public var skipReason: String?
    /// 1...5 self-rated difficulty, optional, feeds adaptation.
    public var difficultyRating: Int?

    public init(id: UUID = UUID(),
                templateID: UUID?,
                goalID: UUID,
                title: String,
                effortMinutes: Int,
                day: CalendarDay,
                window: MinuteWindow? = nil,
                status: OccurrenceStatus = .pending,
                completedAt: Date? = nil,
                skipReason: String? = nil,
                difficultyRating: Int? = nil) {
        self.id = id
        self.templateID = templateID
        self.goalID = goalID
        self.title = title
        self.effortMinutes = effortMinutes
        self.day = day
        self.window = window
        self.status = status
        self.completedAt = completedAt
        self.skipReason = skipReason
        self.difficultyRating = difficultyRating
    }
}

// MARK: - ConstraintProfile

/// The user's availability and limits — single global profile in v1
/// (docs/PLAN.md §4 assumption).
///
/// Sleep is modelled as wake/bedtime minutes (not an absolute window) so the
/// Scheduler reasons about a simple same-day *awake* span `[wake, bedtime)` and
/// never has to handle a cross-midnight sleep block.
public struct ConstraintProfile: Codable, Sendable, Hashable {
    /// Work/busy windows the Scheduler must avoid, per weekday.
    public var workHours: [Weekday: MinuteWindow]
    /// Minute-of-day the user wakes, per weekday (default 07:00).
    public var wakeMinute: [Weekday: Int]
    /// Minute-of-day the user goes to sleep, per weekday (default 23:00).
    public var bedtimeMinute: [Weekday: Int]
    /// Whole days that are off-limits (holidays, known busy days).
    public var blackoutDays: Set<CalendarDay>
    /// Hard cap on scheduled task minutes per day — protects against overload.
    public var maxDailyTaskMinutes: Int

    public static let defaultWake = 7 * 60
    public static let defaultBedtime = 23 * 60

    public init(workHours: [Weekday: MinuteWindow] = [:],
                wakeMinute: [Weekday: Int] = [:],
                bedtimeMinute: [Weekday: Int] = [:],
                blackoutDays: Set<CalendarDay> = [],
                maxDailyTaskMinutes: Int = 120) {
        self.workHours = workHours
        self.wakeMinute = wakeMinute
        self.bedtimeMinute = bedtimeMinute
        self.blackoutDays = blackoutDays
        self.maxDailyTaskMinutes = maxDailyTaskMinutes
    }

    /// The awake span for a weekday, `[wake, bedtime)`.
    public func awakeWindow(_ day: Weekday) -> MinuteWindow {
        let wake = wakeMinute[day] ?? Self.defaultWake
        let bed = bedtimeMinute[day] ?? Self.defaultBedtime
        return MinuteWindow(start: wake, end: max(bed, wake))
    }

    /// A reasonable default: 9–5 weekday work, 07:00–23:00 awake, 2h/day cap.
    public static func makeDefault() -> ConstraintProfile {
        let work = MinuteWindow(startHour: 9, endHour: 17)
        var workHours: [Weekday: MinuteWindow] = [:]
        var wake: [Weekday: Int] = [:]
        var bed: [Weekday: Int] = [:]
        for day in Weekday.allCases {
            if !day.isWeekend { workHours[day] = work }
            wake[day] = defaultWake
            bed[day] = defaultBedtime
        }
        return ConstraintProfile(workHours: workHours,
                                 wakeMinute: wake,
                                 bedtimeMinute: bed,
                                 blackoutDays: [],
                                 maxDailyTaskMinutes: 120)
    }
}
