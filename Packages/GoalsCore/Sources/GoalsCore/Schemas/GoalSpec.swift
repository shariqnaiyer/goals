import Foundation

/// The structured result of the onboarding interview (docs/PLAN.md §3.3 use #1).
///
/// The LLM emits this via constrained tool-use; the app decodes it with
/// `Codable`. It is intentionally close to plain English so the model fills it
/// reliably, while still being machine-validated before anything is created.
public struct GoalSpec: Codable, Sendable, Hashable {
    public var title: String
    public var motivationStatement: String
    public var type: GoalType
    public var successCriteria: String
    /// ISO-8601 `yyyy-MM-dd`, or nil for open-ended goals.
    public var targetDate: String?
    public var currentLevel: String
    public var weeklyBudgetMinutes: Int
    /// Whether the interview gathered enough to generate a plan. **Advisory** in
    /// the redesigned onboarding — `ConcretenessCheck` is authoritative.
    public var isComplete: Bool
    /// If `isComplete` is false, the single best next question to ask.
    public var nextQuestion: String?
    /// The concrete object this goal is about (the specific book + chapters),
    /// carried from onboarding into plan generation. Optional so old specs decode.
    public var specifics: GoalSpecifics?
    /// Long- vs short-term, carried from the aspiration into the created goal.
    public var horizon: GoalHorizon?

    public init(title: String,
                motivationStatement: String,
                type: GoalType,
                successCriteria: String,
                targetDate: String?,
                currentLevel: String,
                weeklyBudgetMinutes: Int,
                isComplete: Bool,
                nextQuestion: String?,
                specifics: GoalSpecifics? = nil,
                horizon: GoalHorizon? = nil) {
        self.title = title
        self.motivationStatement = motivationStatement
        self.type = type
        self.successCriteria = successCriteria
        self.targetDate = targetDate
        self.currentLevel = currentLevel
        self.weeklyBudgetMinutes = weeklyBudgetMinutes
        self.isComplete = isComplete
        self.nextQuestion = nextQuestion
        self.specifics = specifics
        self.horizon = horizon
    }

    public func targetCalendarDay(calendar: Calendar) -> CalendarDay? {
        guard let targetDate else { return nil }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        guard let date = f.date(from: targetDate) else { return nil }
        return CalendarDay(date: date, calendar: calendar)
    }
}
