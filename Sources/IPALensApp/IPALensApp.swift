import IPALensCore
import SwiftUI

@main
struct IPALensApplication: App {
    init() {
        TemporaryDirectoryManager.removeStaleDirectories()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1_260, height: 780)
        .commands {
            IPALensCommands()
        }

        Settings {
            VStack(alignment: .leading, spacing: 12) {
                Text("IPALens")
                    .font(.title2.bold())
                Text("Native IPA Package Explorer for macOS")
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                Label("Runs entirely offline", systemImage: "network.slash")
                Label("Never modifies source packages", systemImage: "lock")
                Label("No accounts, uploads, or telemetry", systemImage: "eye.slash")
                Text("IPALens reports observable package evidence and does not make malware or safety claims.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(width: 420)
        }
    }
}

struct WindowAction {
    let perform: () -> Void
}

private struct OpenIPAActionKey: FocusedValueKey {
    typealias Value = WindowAction
}

private struct ExportReportActionKey: FocusedValueKey {
    typealias Value = WindowAction
}

private struct ExportEntryActionKey: FocusedValueKey {
    typealias Value = WindowAction
}

private struct CopyPathActionKey: FocusedValueKey {
    typealias Value = WindowAction
}

extension FocusedValues {
    var openIPAAction: WindowAction? {
        get { self[OpenIPAActionKey.self] }
        set { self[OpenIPAActionKey.self] = newValue }
    }

    var exportReportAction: WindowAction? {
        get { self[ExportReportActionKey.self] }
        set { self[ExportReportActionKey.self] = newValue }
    }

    var exportEntryAction: WindowAction? {
        get { self[ExportEntryActionKey.self] }
        set { self[ExportEntryActionKey.self] = newValue }
    }

    var copyPathAction: WindowAction? {
        get { self[CopyPathActionKey.self] }
        set { self[CopyPathActionKey.self] = newValue }
    }
}

struct IPALensCommands: Commands {
    @FocusedValue(\.openIPAAction) private var openIPAAction
    @FocusedValue(\.exportReportAction) private var exportReportAction
    @FocusedValue(\.exportEntryAction) private var exportEntryAction
    @FocusedValue(\.copyPathAction) private var copyPathAction

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open IPA…") { openIPAAction?.perform() }
                .keyboardShortcut("o")
                .disabled(openIPAAction == nil)
        }
        CommandGroup(after: .saveItem) {
            Button("Export Inspection Report…") { exportReportAction?.perform() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(exportReportAction == nil)
            Button("Export Selected File…") { exportEntryAction?.perform() }
                .disabled(exportEntryAction == nil)
        }
        CommandMenu("Package Entry") {
            Button("Copy Package Path") { copyPathAction?.perform() }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(copyPathAction == nil)
        }
    }
}
