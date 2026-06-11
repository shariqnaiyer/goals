import SwiftUI
import GoalsCore

/// Google Calendar management: account, which calendars count as busy,
/// the export toggle, and sync status. Sync is best-effort and quiet —
/// errors read as gentle status lines, never blocking alerts.
struct GoogleCalendarDetailView: View {
    @Bindable var model: IntegrationsViewModel

    var body: some View {
        Form {
            accountSection
            if model.google.isConnected {
                busyCalendarsSection
                exportSection
                syncSection
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.bgGrouped.ignoresSafeArea())
        .tint(Palette.accent)
        .navigationTitle("Google Calendar")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.loadCalendars() }
        .refreshable { await model.syncNow() }
    }

    // MARK: Sections

    @ViewBuilder
    private var accountSection: some View {
        if model.google.isConnected {
            Section("Account") {
                LabeledContent("Signed in as",
                               value: model.googleState.accountLabel ?? "Google account")
                Button(role: .destructive) {
                    Task { await model.disconnectGoogle() }
                } label: {
                    Text("Disconnect").foregroundStyle(Palette.danger)
                }
                .disabled(model.isBusy)
            }
        } else {
            Section {
                Button {
                    Task { await model.connectGoogle() }
                } label: {
                    if model.isBusy {
                        ProgressView()
                    } else {
                        Text("Connect Google Calendar")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.isBusy || !Config.googleSignInAvailable)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } footer: {
                if !Config.googleSignInAvailable {
                    Text("Add a Google OAuth client ID to Secrets.xcconfig to enable this integration (see SETUP.md).")
                } else {
                    Text("I'll schedule your sessions around your real meetings, and can add them to a calendar of their own.")
                }
            }
        }
        if let error = model.errorMessage {
            Section {
                Text(error)
                    .font(AppFont.caption1)
                    .foregroundStyle(Palette.gentle)
            }
        }
    }

    private var busyCalendarsSection: some View {
        Section {
            if model.availableCalendars.isEmpty {
                Text("Loading calendars…")
                    .font(AppFont.caption1)
                    .foregroundStyle(Palette.textTertiary)
            }
            ForEach(model.availableCalendars) { calendar in
                Toggle(isOn: Binding(
                    get: { model.isBusyCalendar(calendar.id) },
                    set: { _ in Task { await model.toggleBusyCalendar(calendar.id) } })) {
                    Text(calendar.summary)
                        .lineLimit(1)
                }
            }
            Toggle(isOn: Binding(
                get: { model.googleSettings.includeAllDayEvents },
                set: { include in Task { await model.setIncludeAllDay(include) } })) {
                Text("Count all-day events as busy")
            }
        } header: {
            Text("Busy calendars")
        } footer: {
            Text("Events on these calendars block out time, so sessions are never planned over them.")
        }
    }

    private var exportSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { model.googleSettings.exportEnabled && model.googleSettings.goalsCalendarID != nil },
                set: { enabled in Task { await model.setExportEnabled(enabled) } })) {
                Text("Add my sessions to Google Calendar")
            }
            .disabled(model.isBusy)
        } header: {
            Text("Export")
        } footer: {
            Text("Sessions appear in a dedicated “Goals” calendar and move automatically when your plan adapts. Turning this off removes them.")
        }
    }

    private var syncSection: some View {
        Section {
            if let imported = model.googleState.lastImportAt {
                LabeledContent("Last imported", value: imported.formatted(.relative(presentation: .named)))
            }
            if let exported = model.googleState.lastExportAt {
                LabeledContent("Last exported", value: exported.formatted(.relative(presentation: .named)))
            }
            if let error = model.googleState.lastSyncError {
                Text(error)
                    .font(AppFont.caption1)
                    .foregroundStyle(Palette.gentle)
            }
            Button {
                Task { await model.syncNow() }
            } label: {
                HStack {
                    Text("Sync now")
                    if model.isBusy { Spacer(); ProgressView() }
                }
            }
            .disabled(model.isBusy)
        } header: {
            Text("Sync")
        }
    }
}
