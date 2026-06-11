import Foundation

/// A set of *operations against an existing plan* — the "diffs not rewrites"
/// strategy (docs/PLAN.md §3.3). The LLM emits a `PlanDiff`; it is then
/// semantically validated, previewed to the user, and applied transactionally.
///
/// A diff may carry zero operations and instead pose a `clarifyingQuestion` —
/// the model is encouraged to ask rather than guess when data is ambiguous.
public struct PlanDiff: Codable, Sendable, Hashable {
    /// One-line, human-readable rationale; surfaced in plan history.
    public var summary: String
    public var operations: [PlanOperation]
    public var clarifyingQuestion: String?
    public var clarifyingChoices: [String]

    public init(summary: String,
                operations: [PlanOperation] = [],
                clarifyingQuestion: String? = nil,
                clarifyingChoices: [String] = []) {
        self.summary = summary
        self.operations = operations
        self.clarifyingQuestion = clarifyingQuestion
        self.clarifyingChoices = clarifyingChoices
    }

    public var isQuestionOnly: Bool {
        operations.isEmpty && (clarifyingQuestion?.isEmpty == false)
    }

    public var isEmpty: Bool {
        operations.isEmpty && (clarifyingQuestion?.isEmpty ?? true)
    }
}

/// A single, self-describing operation. Modelled as a flat struct with a `kind`
/// discriminator and optional payload fields rather than a Swift enum with
/// associated values: a single object shape is far more reliable for
/// schema-constrained LLM generation, and trivially validated field-by-field.
public struct PlanOperation: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case addTemplate
        case removeTemplate
        case modifyTemplate
        case swapToMinimumViable
        case pauseTemplate
        case resumeTemplate
        case addMilestone
        case reorderMilestones
        case shiftGoalTargetDate
        case shiftMilestoneTargetDate
        case completeMilestone
        /// Mark a series unit (a book chapter, a module) done — advances the
        /// goal's concrete progress; the Scheduler re-sequences around it.
        case markUnitComplete
    }

    public var id: UUID
    public var kind: Kind
    public var targetTemplateID: UUID?
    public var targetMilestoneID: UUID?
    /// The `SeriesUnit.id` for `markUnitComplete`.
    public var targetUnitID: UUID?
    public var newTemplate: ProposedTemplate?
    public var newMilestone: ProposedMilestone?
    public var newEffortMinutes: Int?
    public var newTimesPerWeek: Int?
    public var newWeekdays: [Weekday]?
    public var newTitle: String?
    /// ISO `yyyy-MM-dd`.
    public var newTargetDate: String?
    public var orderedMilestoneIDs: [UUID]?
    /// Per-operation explanation shown on the diff card.
    public var note: String?

    public init(id: UUID = UUID(),
                kind: Kind,
                targetTemplateID: UUID? = nil,
                targetMilestoneID: UUID? = nil,
                targetUnitID: UUID? = nil,
                newTemplate: ProposedTemplate? = nil,
                newMilestone: ProposedMilestone? = nil,
                newEffortMinutes: Int? = nil,
                newTimesPerWeek: Int? = nil,
                newWeekdays: [Weekday]? = nil,
                newTitle: String? = nil,
                newTargetDate: String? = nil,
                orderedMilestoneIDs: [UUID]? = nil,
                note: String? = nil) {
        self.id = id
        self.kind = kind
        self.targetTemplateID = targetTemplateID
        self.targetMilestoneID = targetMilestoneID
        self.targetUnitID = targetUnitID
        self.newTemplate = newTemplate
        self.newMilestone = newMilestone
        self.newEffortMinutes = newEffortMinutes
        self.newTimesPerWeek = newTimesPerWeek
        self.newWeekdays = newWeekdays
        self.newTitle = newTitle
        self.newTargetDate = newTargetDate
        self.orderedMilestoneIDs = orderedMilestoneIDs
        self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, targetTemplateID, targetMilestoneID, targetUnitID, newTemplate, newMilestone
        case newEffortMinutes, newTimesPerWeek, newWeekdays, newTitle, newTargetDate
        case orderedMilestoneIDs, note
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // The model omits `id`; synthesise one so decoding never fails on it.
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.kind = try c.decode(Kind.self, forKey: .kind)
        self.targetTemplateID = try c.decodeIfPresent(UUID.self, forKey: .targetTemplateID)
        self.targetMilestoneID = try c.decodeIfPresent(UUID.self, forKey: .targetMilestoneID)
        self.targetUnitID = try c.decodeIfPresent(UUID.self, forKey: .targetUnitID)
        self.newTemplate = try c.decodeIfPresent(ProposedTemplate.self, forKey: .newTemplate)
        self.newMilestone = try c.decodeIfPresent(ProposedMilestone.self, forKey: .newMilestone)
        self.newEffortMinutes = try c.decodeIfPresent(Int.self, forKey: .newEffortMinutes)
        self.newTimesPerWeek = try c.decodeIfPresent(Int.self, forKey: .newTimesPerWeek)
        self.newWeekdays = try c.decodeIfPresent([Weekday].self, forKey: .newWeekdays)
        self.newTitle = try c.decodeIfPresent(String.self, forKey: .newTitle)
        self.newTargetDate = try c.decodeIfPresent(String.self, forKey: .newTargetDate)
        self.orderedMilestoneIDs = try c.decodeIfPresent([UUID].self, forKey: .orderedMilestoneIDs)
        self.note = try c.decodeIfPresent(String.self, forKey: .note)
    }

    /// A short, human-readable label for the diff preview card.
    public var displayLabel: String {
        if let note, !note.isEmpty { return note }
        switch kind {
        case .addTemplate: return "Add “\(newTemplate?.title ?? "task")”"
        case .removeTemplate: return "Remove a task"
        case .modifyTemplate: return "Adjust a task"
        case .swapToMinimumViable: return "Switch to the lighter version"
        case .pauseTemplate: return "Pause a task"
        case .resumeTemplate: return "Resume a task"
        case .addMilestone: return "Add milestone “\(newMilestone?.title ?? "")”"
        case .reorderMilestones: return "Reorder milestones"
        case .shiftGoalTargetDate: return "Move the goal date to \(newTargetDate ?? "")"
        case .shiftMilestoneTargetDate: return "Move a milestone date"
        case .completeMilestone: return "Mark a milestone complete"
        case .markUnitComplete: return "Mark done"
        }
    }
}
