import XCTest
@testable import GoalsCore

final class PlanValidatorTests: XCTestCase {

    private let validator = PlanValidator(calendar: Fixtures.calendar)

    func testEmptyDiffIsRejected() {
        let plan = Fixtures.plan()
        let v = validator.validate(PlanDiff(summary: "noop"), against: plan, profile: .makeDefault())
        XCTAssertEqual(v.map(\.code), [.emptyDiff])
    }

    func testQuestionOnlyDiffIsValid() {
        let plan = Fixtures.plan()
        let diff = PlanDiff(summary: "ask", clarifyingQuestion: "Fewer or shorter sessions?")
        XCTAssertTrue(validator.validate(diff, against: plan, profile: .makeDefault()).isEmpty)
    }

    func testUnknownTemplateIsRejected() {
        let plan = Fixtures.plan()
        let diff = PlanDiff(summary: "x", operations: [
            PlanOperation(kind: .pauseTemplate, targetTemplateID: UUID())
        ])
        XCTAssertEqual(validator.validate(diff, against: plan, profile: .makeDefault()).map(\.code),
                       [.unknownTemplate])
    }

    func testOverBudgetIsRejected() {
        // Budget 60m/week, but add a template that pushes well past the 15% grace.
        let plan = Fixtures.plan(weeklyBudget: 60)
        let newTemplate = ProposedTemplate(title: "Extra", milestoneKey: nil, effortMinutes: 60,
                                           cadence: .specificWeekdays,
                                           weekdays: Array(Weekday.allCases), timesPerWeek: 0,
                                           intervalDays: 1, preferredTimeOfDay: nil,
                                           flexibility: .flexible, minimumViableVariant: nil)
        let diff = PlanDiff(summary: "add lots", operations: [
            PlanOperation(kind: .addTemplate, newTemplate: newTemplate)
        ])
        XCTAssertTrue(validator.validate(diff, against: plan, profile: .makeDefault())
            .contains { $0.code == .overBudget })
    }

    func testReorderMustBeExactPermutation() {
        let plan = Fixtures.plan()
        let diff = PlanDiff(summary: "reorder", operations: [
            PlanOperation(kind: .reorderMilestones, orderedMilestoneIDs: [UUID()])
        ])
        XCTAssertEqual(validator.validate(diff, against: plan, profile: .makeDefault()).map(\.code),
                       [.reorderMismatch])
    }
}

final class PlanMutatorTests: XCTestCase {

    private let mutator = PlanMutator()
    private let cal = Fixtures.calendar

    func testSwapToMinimumViableRenamesAndLightensTemplate() {
        let plan = Fixtures.plan()
        let template = plan.templates[0]
        let diff = PlanDiff(summary: "ease", operations: [
            PlanOperation(kind: .swapToMinimumViable, targetTemplateID: template.id)
        ])
        let result = mutator.apply(diff, to: plan, calendar: cal)
        XCTAssertEqual(result.templates[0].title, "10-minute walk")
        XCTAssertLessThan(result.templates[0].effortMinutes, template.effortMinutes)
    }

    func testPauseTemplateDeactivatesWithoutDeleting() {
        let plan = Fixtures.plan()
        let diff = PlanDiff(summary: "pause", operations: [
            PlanOperation(kind: .pauseTemplate, targetTemplateID: plan.templates[0].id)
        ])
        let result = mutator.apply(diff, to: plan, calendar: cal)
        XCTAssertEqual(result.templates.count, 1)
        XCTAssertFalse(result.templates[0].isActive)
        XCTAssertTrue(result.activeTemplates.isEmpty)
    }

    func testModifyTemplateReducesFrequency() {
        let plan = Fixtures.plan() // 3x/week
        let diff = PlanDiff(summary: "less", operations: [
            PlanOperation(kind: .modifyTemplate, targetTemplateID: plan.templates[0].id,
                          newTimesPerWeek: 2)
        ])
        let result = mutator.apply(diff, to: plan, calendar: cal)
        XCTAssertEqual(result.templates[0].recurrence.occurrencesPerWeek, 2)
    }

    func testAddMilestoneAppends() {
        let plan = Fixtures.plan()
        let pm = ProposedMilestone(key: "new", title: "Taper week", order: 5,
                                   completionCriteria: "Rest up", targetDate: nil)
        let diff = PlanDiff(summary: "add", operations: [
            PlanOperation(kind: .addMilestone, newMilestone: pm)
        ])
        let result = mutator.apply(diff, to: plan, calendar: cal)
        XCTAssertEqual(result.milestones.count, 2)
        XCTAssertTrue(result.milestones.contains { $0.title == "Taper week" })
    }
}
