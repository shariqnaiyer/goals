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

        // Templates that walk the series in order.
        let sequentialTemplateIDs = Set(templates.compactMap { t -> UUID? in
            if case .sequential = t.detail { return t.id }
            return nil
        })
        guard !sequentialTemplateIDs.isEmpty else { return pending }

        // The units still to cover: not already complete, not already consumed,
        // in series order. This is the cursor the sessions draw from.
        var remaining = specifics.seriesUnits
            .filter { !$0.isComplete && !consumedUnitIDs.contains($0.id) }
            .sorted { $0.order < $1.order }
        guard !remaining.isEmpty else { return pending }

        // Walk the sequential occurrences in schedule order (day, then window) so
        // the earliest session gets the earliest unit. Non-sequential occurrences
        // and any sessions past the last unit are left untouched.
        let order = sequentialOrder(pending, sequentialTemplateIDs: sequentialTemplateIDs)
        var sliceByOccurrenceID: [UUID: SessionSlice] = [:]
        for occurrenceID in order {
            guard !remaining.isEmpty else { break }
            let unit = remaining.removeFirst()
            sliceByOccurrenceID[occurrenceID] = SessionSlice(
                unitID: unit.id, label: unit.title, detail: unit.detail)
        }

        return pending.map { occ in
            guard let slice = sliceByOccurrenceID[occ.id] else { return occ }
            var copy = occ
            copy.slice = slice
            return copy
        }
    }

    /// IDs of the occurrences belonging to a sequential template, in schedule
    /// order (earliest day/window first).
    private static func sequentialOrder(_ pending: [TaskOccurrence],
                                        sequentialTemplateIDs: Set<UUID>) -> [UUID] {
        pending
            .filter { $0.templateID.map(sequentialTemplateIDs.contains) ?? false }
            .sorted { a, b in
                if a.day != b.day { return a.day < b.day }
                return (a.window?.start ?? Int.max) < (b.window?.start ?? Int.max)
            }
            .map(\.id)
    }
}
