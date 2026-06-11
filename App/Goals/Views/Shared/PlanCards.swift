import SwiftUI
import GoalsCore

/// A small uppercase group label used inside cards ("MILESTONES", "YOUR FIRST TASKS").
private struct GroupLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(AppFont.caption1.weight(.bold))
            .tracking(0.5)
            .foregroundStyle(Palette.textTertiary)
    }
}

/// The interactive plan proposal shown during onboarding (docs/PLAN.md §2.1
/// step 4): goal, milestones, and the first tasks — each editable inline.
struct PlanProposalCard: View {
    let plan: Plan
    var onEditTemplate: (TaskTemplate) -> Void
    var onRemoveTemplate: (UUID) -> Void
    var onAccept: () -> Void
    var isWorking: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Metric.s4) {
            VStack(alignment: .leading, spacing: Metric.s1) {
                Text(plan.goal.title).font(AppFont.title3).foregroundStyle(Palette.textPrimary)
                if !plan.goal.successCriteria.isEmpty {
                    Text(plan.goal.successCriteria).font(AppFont.subhead).foregroundStyle(Palette.textSecondary)
                }
            }

            if !plan.sortedMilestones.isEmpty {
                VStack(alignment: .leading, spacing: Metric.s2) {
                    GroupLabel(text: "Milestones")
                    ForEach(plan.sortedMilestones) { milestone in
                        HStack(spacing: 9) {
                            Image(systemName: "flag.fill").font(.system(size: 13)).foregroundStyle(Palette.accent)
                            Text(milestone.title).font(AppFont.subhead).foregroundStyle(Palette.textPrimary)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: Metric.s2) {
                GroupLabel(text: "Your first tasks")
                ForEach(plan.templates) { template in
                    EditableTemplateRow(template: template, onEdit: onEditTemplate,
                                        onRemove: { onRemoveTemplate(template.id) })
                }
            }

            Button(action: onAccept) {
                HStack(spacing: Metric.s2) {
                    if isWorking { ProgressView().tint(Palette.onAccent) }
                    Text(isWorking ? "Setting up…" : "Looks good — let's start")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isWorking)
        }
        .card()
    }
}

/// One editable task row inside the proposal: tap the slider to adjust, the
/// minus to remove. Sits in a quiet grouped well.
struct EditableTemplateRow: View {
    let template: TaskTemplate
    var onEdit: (TaskTemplate) -> Void
    var onRemove: () -> Void
    @State private var showingEditor = false

    var body: some View {
        HStack(spacing: Metric.s2) {
            VStack(alignment: .leading, spacing: 2) {
                Text(template.title).font(AppFont.subhead.weight(.medium)).foregroundStyle(Palette.textPrimary)
                Text("\(Format.cadence(template.recurrence)) · \(Format.duration(template.effortMinutes))")
                    .font(AppFont.caption1).foregroundStyle(Palette.textTertiary)
            }
            Spacer()
            Button { showingEditor = true } label: {
                Image(systemName: "slider.horizontal.3").foregroundStyle(Palette.textTertiary)
            }.buttonStyle(.plain)
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "minus.circle").foregroundStyle(Palette.textTertiary)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, Metric.s3).padding(.vertical, 10)
        .background(Palette.bgGrouped, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .sheet(isPresented: $showingEditor) { TemplateEditor(template: template, onSave: onEdit) }
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
                    Stepper("\(timesPerWeek)× per week", value: bindingTimes, in: 1...14)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.bgGrouped.ignoresSafeArea())
            .navigationTitle(template.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Save") { onSave(template); dismiss() } }
                ToolbarItem(placement: .cancelAction) { Button("Cancel") { dismiss() } }
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

/// Renders a `PlanDiff` as a reviewable card with Apply / Not now — or, for a
/// question-only diff, the coach's clarifying question with quick-choice chips.
/// Nothing mutates until the user taps Apply (docs/PLAN.md §3.3).
struct PlanDiffCard: View {
    let diff: PlanDiff
    var onAccept: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onChoose: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Metric.s3) {
            if diff.isQuestionOnly {
                Text(diff.clarifyingQuestion ?? "")
                    .font(AppFont.callout).foregroundStyle(Palette.textPrimary)
                if let onChoose {
                    FlowChips(choices: diff.clarifyingChoices, action: onChoose)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars").font(.system(size: 12, weight: .semibold))
                    Text("PROPOSED CHANGE").font(AppFont.caption1.weight(.semibold)).tracking(0.4)
                }
                .foregroundStyle(Palette.accentOnSoft)

                Text(diff.summary).font(AppFont.callout.weight(.medium)).foregroundStyle(Palette.textPrimary)

                VStack(alignment: .leading, spacing: 7) {
                    ForEach(diff.operations) { op in
                        HStack(alignment: .top, spacing: Metric.s2) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 12)).foregroundStyle(Palette.accent).padding(.top, 1)
                            Text(op.displayLabel).font(AppFont.footnote).foregroundStyle(Palette.textSecondary)
                        }
                    }
                }

                if onAccept != nil || onDismiss != nil {
                    HStack(spacing: Metric.s2) {
                        Spacer()
                        if let onDismiss {
                            Button("Not now", action: onDismiss)
                                .buttonStyle(PlainFillButtonStyle(size: .small))
                        }
                        if let onAccept {
                            Button("Apply", action: onAccept)
                                .buttonStyle(PrimaryButtonStyle(size: .small, block: false))
                        }
                    }
                }
            }
        }
        .card()
    }
}

/// Wrapping chip row for clarifying choices.
struct FlowChips: View {
    let choices: [String]
    let action: (String) -> Void
    var body: some View {
        FlexWrap(spacing: Metric.s2) {
            ForEach(choices, id: \.self) { choice in
                Button(choice) { action(choice) }
                    .buttonStyle(SecondaryButtonStyle(size: .small))
            }
        }
    }
}

/// A minimal flow layout so choice chips wrap to multiple lines gracefully.
struct FlexWrap: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
