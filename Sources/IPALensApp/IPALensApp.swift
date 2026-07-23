import AppKit
import IPALensCore
import IPALensPluginKit
import SwiftUI

private final class IPALensApplicationDelegate: NSObject, NSApplicationDelegate {
    private var isPreparingToTerminate = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isPreparingToTerminate else { return .terminateLater }
        isPreparingToTerminate = true
        DispatchQueue.global(qos: .userInitiated).async {
            PackageInspectionEngine.cleanupContainerSessionsForApplicationTermination()
            DispatchQueue.main.async {
                NSApplication.shared.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}

@main
struct IPALensApplication: App {
    @NSApplicationDelegateAdaptor(IPALensApplicationDelegate.self) private var applicationDelegate

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
            PluginStoreCommands()
        }

        Window("Plugins", id: "plugin-store") {
            PluginStoreView()
                .frame(minWidth: 900, minHeight: 640)
        }
        .defaultSize(width: 1_120, height: 760)

        Settings {
            IPALensSettingsView()
        }
    }
}

private struct IPALensSettingsView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
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
            Divider()
            Button {
                openWindow(id: "plugin-store")
            } label: {
                Label("Open Plugin Store", systemImage: "puzzlepiece.extension")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(width: 480, height: 340)
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

private struct PluginStoreCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button("Plugin Store…") {
                openWindow(id: "plugin-store")
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
        }
    }
}
