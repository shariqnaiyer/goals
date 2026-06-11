import Foundation

/// The contract for the multi-stage "Guided Discovery Interview" (docs/PLAN.md —
/// onboarding redesign). The model proposes an updated `OnboardingState` each
/// turn; **deterministic Swift owns stage transitions, the concreteness gate, the
/// capacity cap, and every DB write.** The whole state is client-held and re-sent
/// on every turn, so the proxy stays stateless (the same shape as the old
/// `draft` parameter).

// MARK: - Enums

public enum GoalHorizon: String, Codable, Sendable, Hashable {
    /// A near-term goal you start now (and which usually serves a long-term one).
    case shortTerm
    /// A north-star captured for context; not planned in v1.
    case longTerm
}

/// The facets a goal must pin down before it can be decomposed into real tasks.
public enum ConcretenessDimension: String, Codable, Sendable, Hashable, CaseIterable {
    /// The specific thing — the book, the program. ("read" → which book?)
    case object
    /// Where the user is now. ("could you jog 5 minutes right now?")
    case startState
    /// Where they're going. ("run a 5K nonstop")
    case targetState
    /// How often. ("most evenings", "3×/week")
    case cadence
    /// How much time per session / week.
    case capacity
}

public enum AspirationStatus: String, Codable, Sendable, Hashable {
    /// Surfaced but not yet concrete.
    case exploring
    /// Passed the concreteness gate.
    case concrete
    /// Captured as backlog, not being set up now.
    case deferred
}

/// The model's view of the flow. **Advisory** — the app's `ConcretenessCheck`
/// is authoritative about whether formalizing is allowed.
public enum OnboardingStage: String, Codable, Sendable, Hashable {
    case grounding       // learn the person
    case surfacing       // elicit + split goals
    case concretizing    // the probe loop
    case readyToFormalize
}

// MARK: - PersonSketch

/// What the coach has learned about the person — distinct from their goals
/// (`AspirationDraft`) and their availability (`ConstraintProfile`).
public struct PersonSketch: Codable, Sendable, Hashable {
    public var oneLine: String
    public var dailyShape: String
    public var energyPattern: String?
    public var longTermTheme: String?

    public init(oneLine: String = "", dailyShape: String = "",
                energyPattern: String? = nil, longTermTheme: String? = nil) {
        self.oneLine = oneLine
        self.dailyShape = dailyShape
        self.energyPattern = energyPattern
        self.longTermTheme = longTermTheme
    }

    /// Enough learned to move past grounding (and to anchor scheduling later).
    public var isGrounded: Bool {
        !oneLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !dailyShape.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - AspirationDraft

/// One candidate goal as it's elicited and made concrete during onboarding. Holds
/// everything the concreteness gate inspects and everything needed to build a
/// `GoalSpec` at formalize time.
public struct AspirationDraft: Identifiable, Codable, Sendable, Hashable {
    /// Stable string key the model references ("asp_read").
    public var id: String
    /// The user's verbatim wish ("I want to read").
    public var rawWish: String
    /// The refined, concrete title ("Finish Atomic Habits").
    public var title: String
    public var motivation: String
    public var type: GoalType
    public var horizon: GoalHorizon
    /// For a short-term goal, the long-term aspiration it advances.
    public var servesAspirationID: String?
    public var status: AspirationStatus
    /// The concrete object (the specific book + chapters), once pinned.
    public var specifics: GoalSpecifics?
    public var successCriteria: String
    public var weeklyBudgetMinutes: Int
    /// A cadence the Scheduler can express (`> 0` ⇒ cadence dimension is met).
    public var suggestedTimesPerWeek: Int
    /// Which dimensions the model reports as resolved. The gate re-checks the
    /// underlying fields independently, so these flags can't be gamed.
    public var resolvedDimensions: [ConcretenessDimension]

    public init(id: String,
                rawWish: String,
                title: String = "",
                motivation: String = "",
                type: GoalType = .outcome,
                horizon: GoalHorizon = .shortTerm,
                servesAspirationID: String? = nil,
                status: AspirationStatus = .exploring,
                specifics: GoalSpecifics? = nil,
                successCriteria: String = "",
                weeklyBudgetMinutes: Int = 0,
                suggestedTimesPerWeek: Int = 0,
                resolvedDimensions: [ConcretenessDimension] = []) {
        self.id = id
        self.rawWish = rawWish
        self.title = title
        self.motivation = motivation
        self.type = type
        self.horizon = horizon
        self.servesAspirationID = servesAspirationID
        self.status = status
        self.specifics = specifics
        self.successCriteria = successCriteria
        self.weeklyBudgetMinutes = weeklyBudgetMinutes
        self.suggestedTimesPerWeek = suggestedTimesPerWeek
        self.resolvedDimensions = resolvedDimensions
    }

    /// Build the `GoalSpec` this concrete aspiration formalizes into.
    public func toGoalSpec() -> GoalSpec {
        GoalSpec(title: title.isEmpty ? rawWish : title,
                 motivationStatement: motivation,
                 type: type,
                 successCriteria: successCriteria,
                 targetDate: nil,
                 currentLevel: "",
                 weeklyBudgetMinutes: weeklyBudgetMinutes,
                 isComplete: true,
                 nextQuestion: nil,
                 specifics: specifics)
    }
}

// MARK: - OnboardingState

public struct OnboardingState: Codable, Sendable, Hashable {
    public var person: PersonSketch
    public var aspirations: [AspirationDraft]
    /// The 1–3 the user chose to set up now.
    public var focusAspirationIDs: [String]
    /// Which focus aspiration the probe loop is on.
    public var concretizingID: String?
    public var stage: OnboardingStage
    public var turnCount: Int

    public init(person: PersonSketch = PersonSketch(),
                aspirations: [AspirationDraft] = [],
                focusAspirationIDs: [String] = [],
                concretizingID: String? = nil,
                stage: OnboardingStage = .grounding,
                turnCount: Int = 0) {
        self.person = person
        self.aspirations = aspirations
        self.focusAspirationIDs = focusAspirationIDs
        self.concretizingID = concretizingID
        self.stage = stage
        self.turnCount = turnCount
    }

    public func aspiration(_ id: String) -> AspirationDraft? {
        aspirations.first { $0.id == id }
    }

    /// The selected aspirations, in selection order.
    public var focusAspirations: [AspirationDraft] {
        focusAspirationIDs.compactMap { id in aspirations.first { $0.id == id } }
    }

    /// Backlog: surfaced but not selected to start now.
    public var backlogAspirations: [AspirationDraft] {
        aspirations.filter { !focusAspirationIDs.contains($0.id) }
    }

    public mutating func update(_ aspiration: AspirationDraft) {
        if let idx = aspirations.firstIndex(where: { $0.id == aspiration.id }) {
            aspirations[idx] = aspiration
        } else {
            aspirations.append(aspiration)
        }
    }
}

// MARK: - OnboardingTurnResult

/// What one `onboardingTurn` call returns: the updated state, the coach's next
/// line, the chips to offer, and the model's (advisory) stage.
public struct OnboardingTurnResult: Sendable, Hashable {
    public var state: OnboardingState
    public var assistantMessage: String
    public var choices: [String]
    public var stage: OnboardingStage

    public init(state: OnboardingState, assistantMessage: String,
                choices: [String] = [], stage: OnboardingStage) {
        self.state = state
        self.assistantMessage = assistantMessage
        self.choices = choices
        self.stage = stage
    }
}
