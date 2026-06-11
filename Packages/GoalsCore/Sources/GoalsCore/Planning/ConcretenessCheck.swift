import Foundation

/// The deterministic gate that decides when an aspiration is concrete enough to
/// decompose into real tasks — "Swift disposes" applied to the interview itself
/// (docs/PLAN.md — onboarding redesign). The model's `readyToFormalize` is
/// advisory; `canFormalize` is authoritative. Crucially, this re-checks the
/// underlying fields (rules 2–5), so the model cannot game its
/// `resolvedDimensions` flags to escape the probe loop.
public enum ConcretenessCheck {

    /// Which dimensions a goal of this shape must resolve before formalizing.
    public static func requiredDimensions(for aspiration: AspirationDraft) -> Set<ConcretenessDimension> {
        switch aspiration.type {
        case .habit:
            // An ongoing practice has no terminal target — "a good week" suffices.
            return [.object, .startState, .cadence, .capacity]
        case .outcome:
            return [.object, .startState, .targetState, .cadence, .capacity]
        }
    }

    /// The required dimensions still unresolved — fed back to the model so the
    /// next turn probes exactly the gap (the override discipline).
    public static func missingDimensions(_ aspiration: AspirationDraft) -> [ConcretenessDimension] {
        let resolved = Set(aspiration.resolvedDimensions)
        return ConcretenessDimension.allCases.filter {
            requiredDimensions(for: aspiration).contains($0) && !resolved.contains($0)
        }
    }

    /// True iff the aspiration can be turned into a real, schedulable plan.
    public static func isConcrete(_ a: AspirationDraft) -> Bool {
        // 1. All required dimensions reported resolved.
        guard requiredDimensions(for: a).isSubset(of: Set(a.resolvedDimensions)) else { return false }
        // 2. Object rule: a series-based goal (reading/course) must name its object.
        if isSeriesBased(a) {
            guard let name = a.specifics?.displayName,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        }
        // 3. Refined title (≠ the raw wish) and a real success criterion.
        let title = a.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let wish = a.rawWish.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.caseInsensitiveCompare(wish) != .orderedSame else { return false }
        guard !a.successCriteria.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        // 4. A real capacity.
        guard a.weeklyBudgetMinutes > 0 else { return false }
        // 5. An emittable cadence.
        guard a.suggestedTimesPerWeek > 0 else { return false }
        return true
    }

    /// Whether the goal is an ordered series the app should track unit-by-unit
    /// (and therefore must name its object). Reading/course qualify; fitness and
    /// open practices may pass with a named program instead.
    static func isSeriesBased(_ a: AspirationDraft) -> Bool {
        if case .reading = a.specifics { return true }
        if case .generic = a.specifics { return false }
        let t = (a.rawWish + " " + a.title).lowercased()
        return t.contains("read") || t.contains("book") || t.contains("chapter")
            || t.contains("course") || t.contains("read through")
    }

    /// The combined weekly time the selected goals would demand.
    public static func combinedWeeklyMinutes(_ state: OnboardingState) -> Int {
        state.focusAspirations.reduce(0) { $0 + $1.weeklyBudgetMinutes }
    }

    /// The authoritative formalize gate: the person is grounded, 1–3 focus goals
    /// are chosen and each is concrete, and their combined load fits capacity.
    public static func canFormalize(_ state: OnboardingState, availableWeeklyMinutes: Int) -> Bool {
        guard state.person.isGrounded else { return false }
        let focus = state.focusAspirations
        guard (1...3).contains(focus.count) else { return false }
        guard focus.allSatisfy(isConcrete) else { return false }
        return combinedWeeklyMinutes(state) <= availableWeeklyMinutes
    }

    /// Why `canFormalize` is false, as short notes — surfaced to the user and fed
    /// back to the model.
    public static func blockers(_ state: OnboardingState, availableWeeklyMinutes: Int) -> [String] {
        var notes: [String] = []
        if !state.person.isGrounded { notes.append("still learning who you are") }
        let focus = state.focusAspirations
        if focus.isEmpty { notes.append("no goal chosen to start") }
        if focus.count > 3 { notes.append("pick at most 3 to start") }
        for a in focus where !isConcrete(a) {
            let missing = missingDimensions(a).map(\.rawValue).joined(separator: ", ")
            notes.append("“\(a.title.isEmpty ? a.rawWish : a.title)” still needs: \(missing.isEmpty ? "details" : missing)")
        }
        if combinedWeeklyMinutes(state) > availableWeeklyMinutes {
            notes.append("that's more time than your week has — trim a goal or its sessions")
        }
        return notes
    }
}
