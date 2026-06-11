import Foundation

/// Runs **after** the deterministic `Scheduler`, leaving its `Input`/`Output`
/// untouched. The Scheduler decides *when* a session happens; the Sequencer
/// decides *what* it covers — it walks a goal's `GoalSpecifics` units (book
/// chapters, course modules) in order and stamps a `SessionSlice` onto each
/// pending occurrence of a `.sequential` template.
///
/// Pure and timezone-stable: it only orders occurrences by `CalendarDay` (and
/// window), never touching `Date`. A no-op when the goal has no specifics or no
/// sequential template, so legacy goals schedule exactly as before.
public enum Sequencer {

    /// Assign concrete slices to `pending` occurrences.
    ///
    /// - Parameters:
    ///   - pending: freshly scheduled (pending) occurrences for one goal.
    ///   - specifics: the goal's concrete object, if any.
    ///   - templates: the goal's templates (to find which are `.sequential`).
    ///   - consumedUnitIDs: `SeriesUnit.id`s already done in prior occurrences —
    ///     never reassigned, so completed history is honoured.
    /// - Returns: `pending`, with `slice` filled on sequential occurrences (input
    ///   order preserved).
    public static func assignSlices(pending: [TaskOccurrence],
                                    specifics: GoalSpecifics?,
                                    templates: [TaskTemplate],
                                    consumedUnitIDs: Set<UUID> = []) -> [TaskOccurrence] {
        guard let specifics else { return pending }

        var sliceByOccurrenceID: [UUID: SessionSlice] = [:]
        for template in templates {
            switch template.detail {
            case .sequential:
                assignSequential(template: template, pending: pending, specifics: specifics,
                                 consumedUnitIDs: consumedUnitIDs, into: &sliceByOccurrenceID)
            case .rotating(let routineIDs):
                assignRotating(template: template, pending: pending, specifics: specifics,
                               routineIDs: routineIDs, into: &sliceByOccurrenceID)
            case .none:
                continue
            }
        }
        guard !sliceByOccurrenceID.isEmpty else { return pending }

        return pending.map { occ in
            guard let slice = sliceByOccurrenceID[occ.id] else { return occ }
            var copy = occ
            copy.slice = slice
            return copy
        }
    }

    /// Walk the series units in order, earliest session → earliest unread unit.
    private static func assignSequential(template: TaskTemplate,
                                         pending: [TaskOccurrence],
                                         specifics: GoalSpecifics,
                                         consumedUnitIDs: Set<UUID>,
                                         into slices: inout [UUID: SessionSlice]) {
        var remaining = specifics.seriesUnits
            .filter { !$0.isComplete && !consumedUnitIDs.contains($0.id) }
            .sorted { $0.order < $1.order }
        guard !remaining.isEmpty else { return }
        for id in occurrenceOrder(pending, templateID: template.id) {
            guard !remaining.isEmpty else { break }
            let unit = remaining.removeFirst()
            slices[id] = SessionSlice(unitID: unit.id, label: unit.title, detail: unit.detail)
        }
    }

    /// Cycle through the routines in order, one per successive session.
    private static func assignRotating(template: TaskTemplate,
                                       pending: [TaskOccurrence],
                                       specifics: GoalSpecifics,
                                       routineIDs: [UUID],
                                       into slices: inout [UUID: SessionSlice]) {
        let byID = Dictionary(uniqueKeysWithValues: specifics.routines.map { ($0.id, $0) })
        // Honour the template's stated order; fall back to the specifics' order.
        let cycle = (routineIDs.isEmpty ? specifics.routines.map(\.id) : routineIDs)
            .compactMap { byID[$0] }
        guard !cycle.isEmpty else { return }
        for (i, id) in occurrenceOrder(pending, templateID: template.id).enumerated() {
            let routine = cycle[i % cycle.count]
            let detail = routine.exercises.map(\.displayLine).joined(separator: " · ")
            slices[id] = SessionSlice(unitID: routine.id, label: routine.name,
                                      detail: detail.isEmpty ? nil : detail)
        }
    }

    /// IDs of a template's occurrences in schedule order (earliest day/window first).
    private static func occurrenceOrder(_ pending: [TaskOccurrence], templateID: UUID) -> [UUID] {
        pending
            .filter { $0.templateID == templateID }
            .sorted { a, b in
                if a.day != b.day { return a.day < b.day }
                return (a.window?.start ?? Int.max) < (b.window?.start ?? Int.max)
            }
            .map(\.id)
    }
}
