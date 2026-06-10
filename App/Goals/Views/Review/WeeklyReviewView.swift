import SwiftUI
import GoalsCore

/// The weekly review (docs/PLAN.md §2.2 #4): a short, consensual reflection per
/// active goal — the narrative plus any proposed adjustment to accept or skip.
struct WeeklyReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: WeeklyReviewViewModel

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading {
                    ProgressView("Looking back on your week…")
                } else if model.reviews.isEmpty {
                    ContentUnavailableView("All caught up", systemImage: "checkmark.seal",
                                           description: Text("Nothing to review right now."))
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            ForEach(model.reviews) { review in
                                ReviewCard(review: review,
                                           onAccept: { model.accept(review) },
                                           onDismiss: { model.dismiss(review) })
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Your week")
            .navigationBarTitleDisplayMode(.inline)
            .background(Palette.screenBackground)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { model.markReviewed(); dismiss() }
                }
            }
        }
        .task { await model.load() }
    }
}

private struct ReviewCard: View {
    let review: WeeklyReviewViewModel.GoalReview
    var onAccept: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(review.title).font(.headline)
            Text(review.narrative).font(.subheadline)

            HStack(spacing: 16) {
                stat("Done", Format.percent(review.snapshot.overallCompletionRate))
                stat("Load", "\(review.snapshot.scheduledWeeklyMinutes / 60)h/wk")
            }
            .font(.caption)

            if let result = review.proposal, !result.diff.isEmpty {
                Divider()
                PlanDiffCard(
                    diff: result.diff,
                    onAccept: result.diff.isQuestionOnly ? nil : onAccept,
                    onDismiss: onDismiss,
                    onChoose: nil)
            } else {
                Button("Keep this plan", action: onDismiss)
                    .buttonStyle(.bordered)
            }
        }
        .card()
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading) {
            Text(value).font(.subheadline.bold())
            Text(label).foregroundStyle(.secondary)
        }
    }
}
