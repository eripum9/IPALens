import IPALensCore
import IPALensPluginKit
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
            IPALensSettingsView()
        }
    }
}

private struct IPALensSettingsView: View {
    var body: some View {
        TabView {
            VStack(alignment: .leading, spacing: 12) {
                Text("IPALens")
                    .font(.title2.bold())
                Text("Native App Package Explorer for macOS")
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                Label("Inspections stay on this Mac", systemImage: "lock")
                Label("Never modifies source packages", systemImage: "doc.badge.ellipsis")
                Label("GitHub access is used only for plugin actions", systemImage: "network")
                Text("IPALens reports observable package evidence and does not make malware or safety claims.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .tabItem { Label("General", systemImage: "gearshape") }

            PluginSettingsView()
                .tabItem { Label("Plugins", systemImage: "puzzlepiece.extension") }
        }
        .frame(width: 680, height: 520)
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
            Button("Open Package…") { openIPAAction?.perform() }
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
