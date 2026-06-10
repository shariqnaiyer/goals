import Foundation

/// Layer 1 of the adaptation design (docs/PLAN.md §5): a deterministic, pure
/// scheduler. Given task templates, the constraint profile and optional busy
/// intervals, it expands templates into concrete, windowed occurrences over a
/// rolling horizon using greedy placement — and, crucially, *refuses to
/// overload*: unplaceable demand surfaces as an `OvercommitSignal` that the app
/// routes to Layer 2 (the LLM adapter) instead of silently dropping tasks.
public struct Scheduler {

    public struct Input: Sendable {
        public var templates: [TaskTemplate]
        public var profile: ConstraintProfile
        /// Pre-existing commitments (work is already in the profile; this is for
        /// calendar events and already-scheduled/done occurrences).
        public var busyByDay: [CalendarDay: [MinuteWindow]]
        /// Best observed time-of-day per template, from `PerformanceSnapshot`.
        public var bestTimeHints: [UUID: TimeOfDay]
        public var startDay: CalendarDay
        public var horizonDays: Int
        /// Anchor for `.everyNDays` cadence (usually the goal start day).
        public var anchorDay: CalendarDay
        public var calendar: Calendar

        public init(templates: [TaskTemplate],
                    profile: ConstraintProfile,
                    busyByDay: [CalendarDay: [MinuteWindow]] = [:],
                    bestTimeHints: [UUID: TimeOfDay] = [:],
                    startDay: CalendarDay,
                    horizonDays: Int = 14,
                    anchorDay: CalendarDay,
                    calendar: Calendar = .current) {
            self.templates = templates
            self.profile = profile
            self.busyByDay = busyByDay
            self.bestTimeHints = bestTimeHints
            self.startDay = startDay
            self.horizonDays = horizonDays
            self.anchorDay = anchorDay
            self.calendar = calendar
        }
    }

    /// Raised when a template's desired occurrence couldn't be placed.
    public struct OvercommitSignal: Sendable, Hashable {
        public enum Reason: String, Sendable { case noFreeWindow, dailyCapReached, blackout }
        public var templateID: UUID
        public var day: CalendarDay
        public var reason: Reason
    }

    public struct Output: Sendable {
        public var occurrences: [TaskOccurrence]
        public var overcommit: [OvercommitSignal]
        public var isOvercommitted: Bool { !overcommit.isEmpty }
    }

    public init() {}

    public func schedule(_ input: Input) -> Output {
        let days = horizonDays(input)
        // 1. Expand templates → desired demands per day.
        var demandsByDay: [CalendarDay: [Demand]] = [:]
        for template in input.templates where template.isActive {
            for day in desiredDays(for: template, in: days, input: input) {
                demandsByDay[day, default: []].append(Demand(template: template))
            }
        }

        // 2. Mutable per-day free time, seeded from availability.
        var freeByDay: [CalendarDay: [MinuteWindow]] = [:]
        var usedMinutesByDay: [CalendarDay: Int] = [:]
        for day in days {
            let weekday = day.weekday(in: input.calendar)
            freeByDay[day] = Availability.freeWindows(
                day: day, weekday: weekday, profile: input.profile,
                busy: input.busyByDay[day] ?? [])
        }

        // 3. Greedy placement, day by day.
        var occurrences: [TaskOccurrence] = []
        var signals: [OvercommitSignal] = []

        for day in days {
            let weekday = day.weekday(in: input.calendar)
            let demands = prioritise(demandsByDay[day] ?? [], weekday: weekday, input: input)
            for demand in demands {
                let template = demand.template
                if input.profile.blackoutDays.contains(day) {
                    signals.append(.init(templateID: template.id, day: day, reason: .blackout))
                    continue
                }
                let used = usedMinutesByDay[day] ?? 0
                if used + template.effortMinutes > input.profile.maxDailyTaskMinutes {
                    signals.append(.init(templateID: template.id, day: day, reason: .dailyCapReached))
                    continue
                }
                let preferredStart = preferredStart(for: template, weekday: weekday, input: input)
                guard let placement = place(effort: template.effortMinutes,
                                            preferredStart: preferredStart,
                                            into: freeByDay[day] ?? [],
                                            fixed: template.flexibility == .fixed) else {
                    signals.append(.init(templateID: template.id, day: day, reason: .noFreeWindow))
                    continue
                }
                freeByDay[day] = placement.remainingFree
                usedMinutesByDay[day] = used + template.effortMinutes
                occurrences.append(TaskOccurrence(
                    templateID: template.id,
                    goalID: template.goalID,
                    title: template.title,
                    effortMinutes: template.effortMinutes,
                    day: day,
                    window: placement.window,
                    status: .pending))
            }
        }

        return Output(occurrences: occurrences.sorted(by: occurrenceOrder), overcommit: signals)
    }

    // MARK: - Demand expansion

    private struct Demand { let template: TaskTemplate }

    private func horizonDays(_ input: Input) -> [CalendarDay] {
        (0..<max(0, input.horizonDays)).map { input.startDay.adding(days: $0, calendar: input.calendar) }
    }

    private func desiredDays(for template: TaskTemplate,
                             in days: [CalendarDay],
                             input: Input) -> [CalendarDay] {
        let rule = template.recurrence
        switch rule.cadence {
        case .specificWeekdays:
            return days.filter { rule.weekdays.contains($0.weekday(in: input.calendar)) }

        case .everyNDays:
            return days.filter { day in
                let offset = dayOffset(from: input.anchorDay, to: day, calendar: input.calendar)
                return offset >= 0 && offset % rule.interval == 0
            }

        case .once:
            // Place on the first non-blackout day in the horizon.
            return days.first { !input.profile.blackoutDays.contains($0) }.map { [$0] } ?? []

        case .timesPerWeek:
            return timesPerWeekDays(rule: rule, days: days, input: input)
        }
    }

    /// Spread `timesPerWeek` occurrences across each ISO week in the horizon,
    /// biased toward preferred weekdays and toward days with more free time
    /// (load smoothing).
    private func timesPerWeekDays(rule: RecurrenceRule,
                                  days: [CalendarDay],
                                  input: Input) -> [CalendarDay] {
        guard rule.timesPerWeek > 0 else { return [] }
        // Group horizon days into 7-day buckets from startDay.
        var buckets: [[CalendarDay]] = []
        var current: [CalendarDay] = []
        for (i, day) in days.enumerated() {
            current.append(day)
            if (i + 1) % 7 == 0 { buckets.append(current); current = [] }
        }
        if !current.isEmpty { buckets.append(current) }

        var result: [CalendarDay] = []
        for bucket in buckets {
            let candidates = bucket.filter { !input.profile.blackoutDays.contains($0) }
            let preferred = candidates.filter { rule.weekdays.contains($0.weekday(in: input.calendar)) }
            let pool = preferred.count >= rule.timesPerWeek ? preferred : candidates
            result.append(contentsOf: evenlySpaced(pool, count: min(rule.timesPerWeek, pool.count)))
        }
        return result
    }

    /// Pick `count` items spread as evenly as possible across `items`.
    private func evenlySpaced(_ items: [CalendarDay], count: Int) -> [CalendarDay] {
        guard count > 0, !items.isEmpty else { return [] }
        if count >= items.count { return items }
        var picked: [CalendarDay] = []
        let stride = Double(items.count) / Double(count)
        for i in 0..<count {
            let idx = min(items.count - 1, Int((Double(i) + 0.5) * stride))
            picked.append(items[idx])
        }
        return picked
    }

    // MARK: - Prioritisation & placement

    private func prioritise(_ demands: [Demand], weekday: Weekday, input: Input) -> [Demand] {
        demands.sorted { a, b in
            // Fixed tasks first (they have the least placement freedom).
            let af = a.template.flexibility == .fixed ? 0 : 1
            let bf = b.template.flexibility == .fixed ? 0 : 1
            if af != bf { return af < bf }
            // Then larger effort first, so big rocks find room before small ones.
            return a.template.effortMinutes > b.template.effortMinutes
        }
    }

    private func preferredStart(for template: TaskTemplate, weekday: Weekday, input: Input) -> Int? {
        if let window = template.preferredWindows[weekday] { return window.start }
        if let hint = input.bestTimeHints[template.id] { return hint.representativeWindowStart }
        return nil
    }

    private struct Placement { let window: MinuteWindow; let remainingFree: [MinuteWindow] }

    /// Find the best slot of `effort` minutes among `free`, nearest to
    /// `preferredStart` if given. For `fixed` tasks, only accept a slot that
    /// actually contains the preferred start.
    private func place(effort: Int,
                       preferredStart: Int?,
                       into free: [MinuteWindow],
                       fixed: Bool) -> Placement? {
        var best: (window: MinuteWindow, distance: Int, index: Int)?
        for (index, w) in free.enumerated() where w.durationMinutes >= effort {
            let slotStart: Int
            if let p = preferredStart {
                slotStart = min(max(p, w.start), w.end - effort)
            } else {
                slotStart = w.start
            }
            let distance = preferredStart.map { abs(slotStart - $0) } ?? 0
            if fixed, let p = preferredStart, !(slotStart == p) { continue }
            if best == nil || distance < best!.distance {
                best = (MinuteWindow(start: slotStart, end: slotStart + effort), distance, index)
            }
        }
        guard let chosen = best else { return nil }
        var remaining = free
        let original = remaining.remove(at: chosen.index)
        remaining.append(contentsOf: original.subtracting(chosen.window))
        return Placement(window: chosen.window, remainingFree: remaining.sorted())
    }

    // MARK: - Helpers

    private func dayOffset(from: CalendarDay, to: CalendarDay, calendar: Calendar) -> Int {
        let a = from.date(calendar: calendar)
        let b = to.date(calendar: calendar)
        return calendar.dateComponents([.day], from: a, to: b).day ?? 0
    }

    private func occurrenceOrder(_ a: TaskOccurrence, _ b: TaskOccurrence) -> Bool {
        if a.day != b.day { return a.day < b.day }
        let aStart = a.window?.start ?? Int.max
        let bStart = b.window?.start ?? Int.max
        return aStart < bStart
    }
}
