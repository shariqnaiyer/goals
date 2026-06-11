import SwiftUI
import GoalsCore

/// The integrations catalog: connected services first-class, the roadmap
/// visible as "Coming soon". Google Calendar is the only live integration in
/// v1 (docs/PLAN.md — schedule around real commitments).
struct IntegrationsView: View {
    @Environment(AppContainer.self) private var app
    @State private var model: IntegrationsViewModel?

    var body: some View {
        Group {
            if let model { list(model) } else { ProgressView() }
        }
        .navigationTitle("Integrations")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if model == nil { model = IntegrationsViewModel(app: app) }
        }
    }

    @ViewBuilder
    private func list(_ model: IntegrationsViewModel) -> some View {
        Form {
            Section {
                ForEach(model.descriptors) { descriptor in
                    row(descriptor, status: model.status(for: descriptor.kind), model: model)
                }
            } footer: {
                Text("Your calendar events never leave this device — Goals only reads busy times to schedule around them, and only writes to a calendar it created.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.bgGrouped.ignoresSafeArea())
        .tint(Palette.accent)
    }

    @ViewBuilder
    private func row(_ descriptor: IntegrationDescriptor,
                     status: IntegrationStatus,
                     model: IntegrationsViewModel) -> some View {
        switch descriptor.kind {
        case .googleCalendar:
            NavigationLink {
                GoogleCalendarDetailView(model: model)
            } label: {
                label(descriptor, status: status)
            }
        default:
            label(descriptor, status: status)
                .opacity(0.45)
        }
    }

    private func label(_ descriptor: IntegrationDescriptor, status: IntegrationStatus) -> some View {
        HStack(spacing: Metric.s3) {
            Image(systemName: descriptor.systemImage)
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(descriptor.displayName)
                    .font(AppFont.body)
                    .foregroundStyle(Palette.textPrimary)
                Text(descriptor.subtitle)
                    .font(AppFont.caption1)
                    .foregroundStyle(Palette.textTertiary)
            }
            Spacer()
            statusText(status)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusText(_ status: IntegrationStatus) -> some View {
        switch status {
        case .connected:
            Text("Connected").font(AppFont.caption1).foregroundStyle(Palette.accent)
        case .notConnected:
            Text("Not connected").font(AppFont.caption1).foregroundStyle(Palette.textTertiary)
        case .needsSetup:
            Text("Setup required").font(AppFont.caption1).foregroundStyle(Palette.textTertiary)
        case .comingSoon:
            Text("Coming soon").font(AppFont.caption1).foregroundStyle(Palette.textTertiary)
        }
    }
}
