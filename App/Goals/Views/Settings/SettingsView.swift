import SwiftUI
import GoalsCore
import UniformTypeIdentifiers

/// Settings (docs/PLAN.md §2.2 #5, §7): editable constraints, notification
/// control, the privacy disclosure, and data export / erase.
struct SettingsView: View {
    @Environment(AppContainer.self) private var app
    @State private var model: SettingsViewModel?
    @State private var showEraseConfirm = false
    @State private var exportDocument: JSONDocument?
    @State private var showExporter = false

    var body: some View {
        NavigationStack {
            Group {
                if let model { form(model) } else { ProgressView() }
            }
            .navigationTitle("Settings")
            .background(Palette.screenBackground)
        }
        .onAppear { if model == nil { model = SettingsViewModel(app: app) } }
    }

    @ViewBuilder
    private func form(_ model: SettingsViewModel) -> some View {
        @Bindable var model = model
        Form {
            Section("Your day") {
                NavigationLink {
                    ConstraintEditorView(model: model)
                } label: {
                    Label("Work & sleep hours", systemImage: "clock")
                }
                Stepper("Max \(Format.duration(model.profile.maxDailyTaskMinutes)) of tasks per day",
                        value: $model.profile.maxDailyTaskMinutes, in: 30...360, step: 15)
                    .onChange(of: model.profile.maxDailyTaskMinutes) { _, _ in model.save() }
            }

            Section("Coaching") {
                LabeledContent("AI mode", value: model.usingLiveBackend ? "Live coach" : "Offline (on-device demo)")
            }

            Section {
                Button {
                    if let data = model.exportJSON() {
                        exportDocument = JSONDocument(data: data)
                        showExporter = true
                    }
                } label: { Label("Export my data", systemImage: "square.and.arrow.up") }

                Button(role: .destructive) { showEraseConfirm = true } label: {
                    Label("Erase everything", systemImage: "trash")
                }
            } header: {
                Text("Your data")
            } footer: {
                Text("Everything lives on this device. Coaching sends only the relevant goal's summary and your progress — never your whole history, and nothing is stored on our servers.")
            }
        }
        .confirmationDialog("Erase all goals and data?", isPresented: $showEraseConfirm) {
            Button("Erase everything", role: .destructive) { model.eraseAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes all goals, tasks and history on this device.")
        }
        .fileExporter(isPresented: $showExporter,
                      document: exportDocument,
                      contentType: .json,
                      defaultFilename: "goals-export") { _ in }
    }
}

/// Per-weekday wake/bedtime + work-hours editor.
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
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
