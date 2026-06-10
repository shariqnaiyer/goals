import Foundation

/// Decides, deterministically, *whether* the LLM adapter (Layer 2) should be
/// invoked and *why* (docs/PLAN.md §5 "Triggers"). Keeping this as pure policy
/// means the expensive/non-deterministic LLM call is gated by cheap, testable
/// rules — daily life costs zero API calls.
public struct AdaptationPolicy {

    public var missStreakThreshold: Int

    public init(missStreakThreshold: Int = 3) {
        self.missStreakThreshold = missStreakThreshold
    }

    /// Evaluate triggers for a goal. Returns the highest-priority trigger to act
    /// on, or nil if no adaptation is warranted right now.
    public func evaluate(snapshot: PerformanceSnapshot,
                         schedulerOvercommitted: Bool) -> RevisionTrigger? {
        // Priority order: a structurally impossible schedule is the most urgent,
        // then sustained misses, then routine review (handled elsewhere on a
        // weekly cadence).
        if schedulerOvercommitted || snapshot.isOverBudget {
            return .overcommitted
        }
        if !snapshot.strugglingTemplates(threshold: missStreakThreshold).isEmpty {
            return .missedTasks
        }
        return nil
    }

    /// Whether the weekly review is due given the last review date.
    public func isWeeklyReviewDue(lastReview: Date?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let lastReview else { return true }
        let days = calendar.dateComponents([.day], from: lastReview, to: now).day ?? 0
        return days >= 7
    }
}
