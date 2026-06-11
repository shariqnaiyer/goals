import SwiftUI
import GoalsCore

/// The weekly review (docs/PLAN.md §2.2 #4): a short, consensual reflection per
/// active goal — the coach's narrative plus any proposed adjustment to accept or
/// keep. This is where adaptation becomes visible and chosen, not silent.
struct WeeklyReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: WeeklyReviewViewModel

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading {
                    VStack(spacing: Metric.s3) {
                        TypingIndicator()
                        Text("Looking back on your week…").font(AppFont.subhead).foregroundStyle(Palette.textTertiary)
                    }
                    .frame(maxHeight: .infinity)
                } else if model.reviews.isEmpty {
                    ContentUnavailableView("All caught up", systemImage: "checkmark.seal",
                                           description: Text("Nothing to review right now."))
                } else {
                    ScrollView {
                        VStack(spacing: Metric.s4) {
                            ForEach(model.reviews) { review in
                                ReviewCard(review: review,
                                           onAccept: { model.accept(review) },
                                           onDismiss: { model.dismiss(review) })
                            }
                        }
                        .padding(Metric.s4)
                    }
                }
            }
            .navigationTitle("Your week")
            .navigationBarTitleDisplayMode(.inline)
            .background(Palette.bgGrouped.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { model.markReviewed(); dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .task { await model.load() }
    }
}

private struct ReviewCard: View {
    let review: WeeklyReviewViewModel.GoalReview
    var onAccept: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metric.s3) {
            Text(review.title).font(AppFont.headline).foregroundStyle(Palette.textPrimary)
            Text(review.narrative).font(AppFont.body).foregroundStyle(Palette.textSecondary)

            HStack(spacing: Metric.s7) {
                stat("Done", Format.percent(review.snapshot.overallCompletionRate))
                stat("Load", "\(review.snapshot.scheduledWeeklyMinutes / 60)h/wk")
            }
            .padding(.top, 2)

            if let result = review.proposal, !result.diff.isEmpty {
                Divider().overlay(Palette.hairline)
                PlanDiffCardInline(
                    diff: result.diff,
                    onAccept: result.diff.isQuestionOnly ? nil : onAccept,
                    onDismiss: onDismiss)
            } else {
                Button("Keep this plan", action: onDismiss)
                    .buttonStyle(SecondaryButtonStyle(size: .medium, block: true))
                    .padding(.top, 2)
            }
        }
        .card()
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(AppFont.headline).foregroundStyle(Palette.textPrimary).monospacedDigit()
            Text(label).font(AppFont.caption1).foregroundStyle(Palette.textTertiary)
        }
    }
}

/// The diff content reused inside a review card (without its own card chrome).
private struct PlanDiffCardInline: View {
    let diff: PlanDiff
    var onAccept: (() -> Void)?
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metric.s2) {
            Text(diff.summary).font(AppFont.callout.weight(.medium)).foregroundStyle(Palette.textPrimary)
            ForEach(diff.operations) { op in
                HStack(alignment: .top, spacing: Metric.s2) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12)).foregroundStyle(Palette.accent).padding(.top, 1)
                    Text(op.displayLabel).font(AppFont.footnote).foregroundStyle(Palette.textSecondary)
                }
            }
            HStack(spacing: Metric.s2) {
                Button("Keep as is", action: onDismiss).buttonStyle(PlainFillButtonStyle(size: .small))
                if let onAccept {
                    Button("Apply", action: onAccept).buttonStyle(PrimaryButtonStyle(size: .small, block: false))
                }
                Spacer()
            }
            .padding(.top, 2)
        }
    }
}
