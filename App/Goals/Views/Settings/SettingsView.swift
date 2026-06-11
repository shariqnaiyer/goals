import SwiftUI
import GoalsCore
import UniformTypeIdentifiers

/// Settings (docs/PLAN.md §2.2 #5, §7): editable constraints, the coaching mode,
/// and the privacy controls (export / erase) with a plain-spoken disclosure.
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
            .background(Palette.bgGrouped.ignoresSafeArea())
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
