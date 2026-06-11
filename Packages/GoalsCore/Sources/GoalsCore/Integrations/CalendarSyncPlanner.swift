import Foundation

/// What we want a session to look like on the external calendar, derived from
/// a pending `TaskOccurrence`.
public struct DesiredCalendarEvent: Sendable, Hashable {
    public let occurrenceID: UUID
    public let title: String
    public let day: CalendarDay
    public let window: MinuteWindow
    public let notes: String?

    public init(occurrenceID: UUID,
                title: String,
                day: CalendarDay,
                window: MinuteWindow,
                notes: String? = nil) {
        self.occurrenceID = occurrenceID
        self.title = title
        self.day = day
        self.window = window
        self.notes = notes
    }

    /// Content signature used to recognise "same session, new UUID" across
    /// reschedules (the scheduler regenerates pending occurrences with fresh
    /// IDs every run — see SchedulingCoordinator).
    public var contentKey: String {
        "\(day.year)-\(day.month)-\(day.day)|\(window.start)-\(window.end)|\(title)"
    }
}

/// One exported event we know about (the JSON payload of `SDSyncedEvent`).
public struct SyncedEventRecord: Codable, Sendable, Hashable {
    public var occurrenceID: UUID
    /// The provider's event ID (e.g. Google event id).
    public var eventID: String
    public var day: CalendarDay
    /// Content signature of what was last pushed.
    public var contentKey: String

    public init(occurrenceID: UUID, eventID: String, day: CalendarDay, contentKey: String) {
        self.occurrenceID = occurrenceID
        self.eventID = eventID
        self.day = day
        self.contentKey = contentKey
    }
}

/// The minimal set of provider operations to reconcile the calendar with the
/// current schedule, plus the records to persist afterwards.
public struct CalendarSyncPlan: Sendable {
    /// New events to insert.
    public var creates: [DesiredCalendarEvent]
    /// Existing events whose content changed — patch in place.
    public var updates: [(record: SyncedEventRecord, desired: DesiredCalendarEvent)]
    /// Events whose future occurrence vanished — delete from the calendar.
    public var deletes: [SyncedEventRecord]
    /// Events already correct (records may be re-keyed to fresh occurrence
    /// IDs); zero API calls, but persist these records.
    public var unchanged: [SyncedEventRecord]
    /// Past records to drop from the local store; the calendar events are left
    /// alone so history stays visible.
    public var prune: [SyncedEventRecord]
}

/// Pure diff between the desired schedule and the known synced state. The
/// crucial property: a reschedule that changes nothing semantically (but
/// regenerates every occurrence UUID) produces an all-`unchanged` plan —
/// zero provider API calls.
public enum CalendarSyncPlanner {

    public static func plan(desired: [DesiredCalendarEvent],
                            known: [SyncedEventRecord],
                            today: CalendarDay) -> CalendarSyncPlan {
        var unchanged: [SyncedEventRecord] = []
        var updates: [(record: SyncedEventRecord, desired: DesiredCalendarEvent)] = []
        var creates: [DesiredCalendarEvent] = []
        var deletes: [SyncedEventRecord] = []
        var prune: [SyncedEventRecord] = []

        // Pass 1 — match by occurrence ID (occurrence survived, maybe moved).
        var recordsByOccurrence = Dictionary(known.map { ($0.occurrenceID, $0) },
                                             uniquingKeysWith: { a, _ in a })
        var unmatchedDesired: [DesiredCalendarEvent] = []
        for d in desired {
            if let record = recordsByOccurrence.removeValue(forKey: d.occurrenceID) {
                if record.contentKey == d.contentKey {
                    unchanged.append(record)
                } else {
                    updates.append((record: record, desired: d))
                }
            } else {
                unmatchedDesired.append(d)
            }
        }

        // Pass 2 — adopt orphaned records by content (fresh UUID, same slot).
        // This is what makes deletePending churn free.
        var orphansByContent: [String: [SyncedEventRecord]] = Dictionary(
            grouping: recordsByOccurrence.values, by: { $0.contentKey })
        var stillUnmatched: [DesiredCalendarEvent] = []
        for d in unmatchedDesired {
            if var candidates = orphansByContent[d.contentKey], !candidates.isEmpty {
                var record = candidates.removeFirst()
                orphansByContent[d.contentKey] = candidates
                record.occurrenceID = d.occurrenceID
                unchanged.append(record)
            } else {
                stillUnmatched.append(d)
            }
        }

        // Pass 3 — leftovers. New desireds get created; leftover records are
        // deleted if the slot is still upcoming, pruned (store-only) if past.
        creates = stillUnmatched
        for record in orphansByContent.values.flatMap({ $0 }) {
            if record.day >= today {
                deletes.append(record)
            } else {
                prune.append(record)
            }
        }

        return CalendarSyncPlan(creates: creates,
                                updates: updates,
                                deletes: deletes,
                                unchanged: unchanged,
                                prune: prune)
    }
}
