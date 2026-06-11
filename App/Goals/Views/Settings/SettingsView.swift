import SwiftUI
import GoalsCore
import UniformTypeIdentifiers

/// Settings (docs/PLAN.md §2.2 #5, §7): editable constraints, the coaching mode,
/// and the privacy controls (export / erase) with a plain-spoken disclosure.
struct SettingsView: View {
    @Environment(AppContainer.self) private var app
    @State private var model: SettingsViewModel?
    @State private var profile: UserProfile = UserProfile()
    @State private var showEraseConfirm = false
    @State private var exportDocument: JSONDocument?
    @State private var showExporter = false

    var body: some View {
        NavigationStack {
            Group {
                if let model { form(model) } else { ProgressView() }
            }
            .navigationTitle("You")
            .background(Palette.bgGrouped.ignoresSafeArea())
        }
        .onAppear {
            if model == nil { model = SettingsViewModel(app: app) }
            profile = app.store.userProfile()
        }
    }

    @ViewBuilder
    private func form(_ model: SettingsViewModel) -> some View {
        @Bindable var model = model
        Form {
            if profile.person.isGrounded {
                Section {
                    profileRow("In a sentence", profile.person.oneLine)
                    profileRow("A typical day", profile.person.dailyShape)
                    if let energy = profile.person.energyPattern { profileRow("Energy", energy) }
                    if let theme = profile.person.longTermTheme { profileRow("The bigger picture", theme) }
                } header: {
                    Text("What I understand about you")
                } footer: {
                    Text(profile.backlog.isEmpty
                        ? "I keep this in mind when planning — and only ever send a summary to the coach, never your whole history."
                        : "Plus \(profile.backlog.count) idea\(profile.backlog.count == 1 ? "" : "s") I'm holding for later.")
                }
            }

            Section("Your day") {
                NavigationLink {
                    ConstraintEditorView(model: model)
                } label: {
                    Label {
                        Text("Work & sleep hours")
                    } icon: {
                        Image(systemName: "clock").foregroundStyle(Palette.textSecondary)
                    }
                }
                Stepper(value: $model.profile.maxDailyTaskMinutes, in: 30...360, step: 15) {
                    HStack {
                        Text("Max tasks per day")
                        Spacer()
                        Text(Format.duration(model.profile.maxDailyTaskMinutes))
                            .foregroundStyle(Palette.textSecondary).monospacedDigit()
                    }
                }
                .onChange(of: model.profile.maxDailyTaskMinutes) { _, _ in model.save() }
            }

            Section("Coaching") {
                LabeledContent("AI mode", value: model.usingLiveBackend ? "Live coach" : "Offline (on-device demo)")
            }

            Section("Connected apps") {
                NavigationLink {
                    IntegrationsView()
                } label: {
                    HStack {
                        Label {
                            Text("Integrations")
                        } icon: {
                            Image(systemName: "link").foregroundStyle(Palette.textSecondary)
                        }
                        Spacer()
                        Text(app.integrations.connectedCount > 0
                             ? "\(app.integrations.connectedCount) connected"
                             : "Connect your calendar")
                            .font(AppFont.caption1)
                            .foregroundStyle(Palette.textTertiary)
                    }
                }
            }

            Section {
                Button {
                    if let data = model.exportJSON() {
                        exportDocument = JSONDocument(data: data); showExporter = true
                    }
                } label: {
                    Label { Text("Export my data") } icon: {
                        Image(systemName: "square.and.arrow.up").foregroundStyle(Palette.accent)
                    }
                }
                Button(role: .destructive) { showEraseConfirm = true } label: {
                    Label { Text("Erase everything").foregroundStyle(Palette.danger) } icon: {
                        Image(systemName: "trash").foregroundStyle(Palette.danger)
                    }
                }
            } header: {
                Text("Your data")
            } footer: {
                Text("Everything lives on this device. Coaching sends only the relevant goal's summary and your progress — never your whole history, and nothing is stored on our servers.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.bgGrouped.ignoresSafeArea())
        .tint(Palette.accent)
        .confirmationDialog("Erase all goals and data?", isPresented: $showEraseConfirm) {
            Button("Erase everything", role: .destructive) { model.eraseAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes all goals, tasks and history on this device.")
        }
        .fileExporter(isPresented: $showExporter, document: exportDocument,
                      contentType: .json, defaultFilename: "goals-export") { _ in }
    }

    /// One legible, second-person line of what the coach learned.
    @ViewBuilder
    private func profileRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(AppFont.caption1).tracking(0.4).foregroundStyle(Palette.textTertiary)
            Text(value).font(AppFont.callout).foregroundStyle(Palette.textPrimary)
        }
        .padding(.vertical, 2)
    }
}

/// Per-weekday wake / sleep editor (work hours are a single weekday block in v1).
struct ConstraintEditorView: View {
    @Bindable var model: SettingsViewModel

    var body: some View {
        Form {
            ForEach(Weekday.allCases, id: \.self) { day in
                Section(day.rawValue.capitalized) {
                    timePicker("Wake", minute: Binding(
                        get: { model.wakeBinding(for: day) },
                        set: { model.setWake($0, for: day) }))
                    timePicker("Sleep", minute: Binding(
                        get: { model.bedtimeBinding(for: day) },
                        set: { model.setBedtime($0, for: day) }))
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.bgGrouped.ignoresSafeArea())
        .navigationTitle("Work & sleep")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { model.save() }
    }

    private func timePicker(_ label: String, minute: Binding<Int>) -> some View {
        DatePicker(label,
                   selection: Binding(
                    get: { dateFrom(minute: minute.wrappedValue) },
                    set: { minute.wrappedValue = minuteOf($0) }),
                   displayedComponents: .hourAndMinute)
    }
    private func dateFrom(minute: Int) -> Date {
        var c = DateComponents(); c.hour = minute / 60; c.minute = minute % 60
        return Calendar.current.date(from: c) ?? Date()
    }
    private func minuteOf(_ date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
}

/// A trivial JSON file document for `fileExporter`.
struct JSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
