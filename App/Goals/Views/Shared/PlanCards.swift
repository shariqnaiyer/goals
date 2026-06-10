import SwiftUI
import GoalsCore

/// The interactive plan proposal card shown during onboarding (docs/PLAN.md
/// §2.1 step 4): goal, milestones and the first tasks, each editable inline.
struct PlanProposalCard: View {
    let plan: Plan
    var onEditTemplate: (TaskTemplate) -> Void
    var onRemoveTemplate: (UUID) -> Void
    var onAccept: () -> Void
    var isWorking: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(plan.goal.title).font(.title3.bold())
                Text(plan.goal.successCriteria).font(.subheadline).foregroundStyle(.secondary)
            }

            if !plan.sortedMilestones.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Milestones").font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(plan.sortedMilestones) { milestone in
                        Label(milestone.title, systemImage: "flag.fill")
                            .font(.subheadline)
                            .labelStyle(.titleAndIcon)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Your first tasks").font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(plan.templates) { template in
                    EditableTemplateRow(template: template,
                                        onEdit: onEditTemplate,
                                        onRemove: { onRemoveTemplate(template.id) })
                }
            }

            Button(action: onAccept) {
                HStack {
                    if isWorking { ProgressView().tint(.white) }
                    Text(isWorking ? "Setting up…" : "Looks good — let's start")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isWorking)
        }
        .card()
    }
}

/// One editable task row: tap to adjust effort/frequency, swipe-style remove.
struct EditableTemplateRow: View {
    let template: TaskTemplate
    var onEdit: (TaskTemplate) -> Void
    var onRemove: () -> Void
    @State private var showingEditor = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(template.title).font(.subheadline.weight(.medium))
                Text("\(Format.cadence(template.recurrence)) · \(Format.duration(template.effortMinutes))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { showingEditor = true } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.borderless)
            Button(role: .destructive, action: onRemove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
        }
        .sheet(isPresented: $showingEditor) {
            TemplateEditor(template: template, onSave: onEdit)
        }
    }
}

/// A focused editor for a task's effort and weekly frequency.
struct TemplateEditor: View {
    @State var template: TaskTemplate
    var onSave: (TaskTemplate) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Effort") {
                    Stepper("\(Format.duration(template.effortMinutes))",
                            value: $template.effortMinutes, in: 5...180, step: 5)
                }
                Section("How often") {
                    Stepper("\(timesPerWeek)× per week",
                            value: bindingTimes, in: 1...14)
                }
            }
            .navigationTitle(template.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(template); dismiss() }
                }
                ToolbarItem(placement: .cancelAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var timesPerWeek: Int { template.recurrence.occurrencesPerWeek }
    private var bindingTimes: Binding<Int> {
        Binding(get: { timesPerWeek },
                set: { template.recurrence = .times($0, preferring: template.recurrence.weekdays) })
    }
}

/// Renders a `PlanDiff` as a reviewable card with accept/dismiss, or a
/// clarifying question with quick-choice chips (docs/PLAN.md §3.3).
struct PlanDiffCard: View {
    let diff: PlanDiff
    var onAccept: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onChoose: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if diff.isQuestionOnly {
                Text(diff.clarifyingQuestion ?? "")
                    .font(.subheadline)
                if let onChoose {
                    FlowChips(choices: diff.clarifyingChoices, action: onChoose)
                }
            } else {
                Label("Proposed change", systemImage: "wand.and.stars")
                    .font(.caption.bold()).foregroundStyle(.secondary)
                Text(diff.summary).font(.subheadline.weight(.medium))
                ForEach(diff.operations) { op in
                    Label(op.displayLabel, systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if onAccept != nil || onDismiss != nil {
                    HStack {
                        if let onDismiss {
                            Button("Not now", action: onDismiss).buttonStyle(.bordered)
                        }
                        if let onAccept {
                            Button("Apply", action: onAccept).buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
        }
        .card()
    }
}

/// Simple wrapping chip row for clarifying choices.
struct FlowChips: View {
    let choices: [String]
    let action: (String) -> Void
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack { chips }
            VStack(alignment: .leading) { chips }
        }
    }
    private var chips: some View {
        ForEach(choices, id: \.self) { choice in
            Button(choice) { action(choice) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}
