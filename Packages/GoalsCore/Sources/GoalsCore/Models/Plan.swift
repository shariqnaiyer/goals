import Foundation

/// An in-memory aggregate of everything that makes up one goal's plan.
///
/// This is the unit the validator, mutator and scheduler operate on. It is a
/// value type assembled from the repositories at the app edge, transformed
/// purely, then persisted back — keeping all planning logic side-effect free.
public struct Plan: Codable, Sendable, Hashable {
    public var goal: Goal
    public var milestones: [Milestone]
    public var templates: [TaskTemplate]

    public init(goal: Goal, milestones: [Milestone], templates: [TaskTemplate]) {
        self.goal = goal
        self.milestones = milestones
        self.templates = templates
    }

    public var activeTemplates: [TaskTemplate] { templates.filter(\.isActive) }

    /// Total estimated weekly load across active templates, in minutes.
    public var weeklyLoadMinutes: Int {
        activeTemplates.reduce(0) { $0 + $1.weeklyLoadMinutes }
    }

    public func milestone(_ id: UUID) -> Milestone? { milestones.first { $0.id == id } }
    public func template(_ id: UUID) -> TaskTemplate? { templates.first { $0.id == id } }

    public var sortedMilestones: [Milestone] { milestones.sorted { $0.order < $1.order } }
}
