import Foundation

// MARK: - SeriesUnit

/// A stable, orderable unit of a concrete goal — a book chapter, a course
/// module, a program run. Identity is by `id`; `order` defines progression. The
/// Scheduler never sees these (they describe *what* a session is, not *when*);
/// the `Sequencer` walks them to stamp a `SessionSlice` onto each occurrence.
public struct SeriesUnit: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public var order: Int
    public var title: String
    public var detail: String?
    /// Set once the unit has actually been done. Lets a freshly-attached series
    /// start mid-way (e.g. "already on chapter 3") without falsifying history.
    public var isComplete: Bool

    public init(id: UUID = UUID(), order: Int, title: String,
                detail: String? = nil, isComplete: Bool = false) {
        self.id = id
        self.order = order
        self.title = title
        self.detail = detail
        self.isComplete = isComplete
    }
}

// MARK: - Per-kind specifics

/// A specific book the user is reading, with its chapters as ordered units.
public struct ReadingSpecifics: Codable, Sendable, Hashable {
    public var bookTitle: String
    public var author: String?
    public var chapters: [SeriesUnit]
    /// A date the user is aiming to finish by — a *target*, like `Goal.targetDate`,
    /// never a scheduled instant.
    public var targetFinish: CalendarDay?
    public var pagesPerSession: Int?

    public init(bookTitle: String, author: String? = nil, chapters: [SeriesUnit] = [],
                targetFinish: CalendarDay? = nil, pagesPerSession: Int? = nil) {
        self.bookTitle = bookTitle
        self.author = author
        self.chapters = chapters
        self.targetFinish = targetFinish
        self.pagesPerSession = pagesPerSession
    }

    /// Build chapters "Chapter 1 … Chapter n" when the user only knows the count.
    public static func numbered(bookTitle: String, author: String? = nil, chapterCount: Int,
                                targetFinish: CalendarDay? = nil) -> ReadingSpecifics {
        let chapters = (1...max(1, chapterCount)).map {
            SeriesUnit(order: $0 - 1, title: "Chapter \($0)")
        }
        return ReadingSpecifics(bookTitle: bookTitle, author: author,
                                chapters: chapters, targetFinish: targetFinish)
    }
}

/// A fallback for concrete goals that are an ordered list of units but not a
/// purpose-built kind (a backlog of lessons, a list of recipes to cook).
public struct GenericSpecifics: Codable, Sendable, Hashable {
    /// Singular noun for one unit ("lesson", "session").
    public var unitNoun: String
    public var units: [SeriesUnit]

    public init(unitNoun: String, units: [SeriesUnit] = []) {
        self.unitNoun = unitNoun
        self.units = units
    }
}

// MARK: - GoalSpecifics

/// The concrete "thing" a goal is about — the specific book + chapters, the
/// named program + routines. **Opaque to the Scheduler**, which never reads it:
/// it informs *what* a session is, not *when*. v1 ships `.reading` and
/// `.generic`; `.fitness` arrives with the fitness work.
///
/// Encoded with an explicit `kind` discriminator (not Swift's synthesized
/// `{"reading": {"_0": …}}` shape) so the wire format is stable as cases are
/// added and matches the proxy JSON schema.
public enum GoalSpecifics: Sendable, Hashable {
    case reading(ReadingSpecifics)
    case generic(GenericSpecifics)
}

public extension GoalSpecifics {
    /// The ordered units, uniformly, so callers (the `Sequencer`, detail views)
    /// never switch on the kind.
    var seriesUnits: [SeriesUnit] {
        switch self {
        case .reading(let r): return r.chapters
        case .generic(let g): return g.units
        }
    }

    /// Singular noun for one unit ("chapter", "lesson").
    var unitNoun: String {
        switch self {
        case .reading: return "chapter"
        case .generic(let g): return g.unitNoun
        }
    }

    /// A human display name for the concrete object ("Atomic Habits"), if any.
    var displayName: String? {
        switch self {
        case .reading(let r): return r.bookTitle
        case .generic: return nil
        }
    }

    /// Units completed so far (by their `isComplete` flag).
    var completedUnitCount: Int { seriesUnits.filter(\.isComplete).count }
    var totalUnitCount: Int { seriesUnits.count }
}

extension GoalSpecifics: Codable {
    private enum Kind: String, Codable { case reading, generic }
    private enum CodingKeys: String, CodingKey { case kind, reading, generic }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .reading: self = .reading(try c.decode(ReadingSpecifics.self, forKey: .reading))
        case .generic: self = .generic(try c.decode(GenericSpecifics.self, forKey: .generic))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .reading(let r):
            try c.encode(Kind.reading, forKey: .kind)
            try c.encode(r, forKey: .reading)
        case .generic(let g):
            try c.encode(Kind.generic, forKey: .kind)
            try c.encode(g, forKey: .generic)
        }
    }
}

// MARK: - TemplateDetail

/// How a template draws its sessions from the goal's `GoalSpecifics`. This is
/// *intent* on the template (adaptation may rewrite it), distinct from the
/// immutable `SessionSlice` stamped on each occurrence. `nil` (the default on
/// `TaskTemplate`) means an ordinary task with no concrete sub-structure.
///
/// `.rotating` is defined now (so the wire format is stable) but only used once
/// fitness routines land.
public enum TemplateDetail: Sendable, Hashable {
    /// Sessions walk the goal's series units in order (chapters, modules, runs).
    case sequential
    /// Sessions cycle through the listed routines in order.
    case rotating(routineIDs: [UUID])
}

extension TemplateDetail: Codable {
    private enum Kind: String, Codable { case sequential, rotating }
    private enum CodingKeys: String, CodingKey { case kind, routineIDs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .sequential: self = .sequential
        case .rotating: self = .rotating(routineIDs: try c.decode([UUID].self, forKey: .routineIDs))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .sequential:
            try c.encode(Kind.sequential, forKey: .kind)
        case .rotating(let ids):
            try c.encode(Kind.rotating, forKey: .kind)
            try c.encode(ids, forKey: .routineIDs)
        }
    }
}

// MARK: - SessionSlice

/// The concrete content of one scheduled session — "Chapter 4" — stamped onto a
/// `TaskOccurrence` by the `Sequencer`. Recorded as part of completed history so
/// the app knows exactly which unit was done; **never rewritten** by adaptation.
public struct SessionSlice: Codable, Sendable, Hashable {
    /// The `SeriesUnit.id` this session covers, when it maps to one.
    public var unitID: UUID?
    /// Short label shown in the UI ("Chapter 4", "Workout B").
    public var label: String
    public var detail: String?

    public init(unitID: UUID? = nil, label: String, detail: String? = nil) {
        self.unitID = unitID
        self.label = label
        self.detail = detail
    }
}
