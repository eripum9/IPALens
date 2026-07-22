import AppKit
import Combine
import IPALensPluginKit
import SwiftUI
import UniformTypeIdentifiers

private struct AvailablePlugin: Identifiable {
    var id: String { source.id.uuidString + ":" + entry.id }
    let entry: PluginCatalogEntry
    let source: PluginSource
}

@MainActor
private final class PluginSettingsModel: ObservableObject {
    @Published var installed: [PluginInstallation] = []
    @Published var available: [AvailablePlugin] = []
    @Published var sources: [PluginSource] = []
    @Published var isRefreshing = false
    @Published var busyPluginID: String?
    @Published var errorMessage: String?
    @Published var sourceURLText = ""
    @Published var pendingSource: PluginSourceCandidate?
    @Published var pendingLocalURL: URL?

    private let manager = PluginManager.shared
    private var refreshTask: Task<Void, Never>?
    private var installTask: Task<Void, Never>?

    deinit {
        refreshTask?.cancel()
        installTask?.cancel()
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        refreshTask?.cancel()
        refreshTask = Task {
            do {
                installed = try await manager.installedPlugins()
                sources = try await manager.sources()
                let plugins = try await manager.availablePlugins()
                available = plugins.map { AvailablePlugin(entry: $0.0, source: $0.1) }
            } catch is CancellationError {
                // The user cancelled the download before activation.
            } catch {
                errorMessage = error.localizedDescription
            }
            isRefreshing = false
        }
    }

    func cancelOperation() {
        installTask?.cancel()
        installTask = nil
        busyPluginID = nil
    }

    func install(_ plugin: AvailablePlugin) {
        busyPluginID = plugin.entry.id
        installTask?.cancel()
        installTask = Task {
            do {
                _ = try await manager.install(entry: plugin.entry, from: plugin.source)
                installed = try await manager.installedPlugins()
            } catch is CancellationError {
                // The existing version remains active when a download is cancelled.
            } catch {
                errorMessage = error.localizedDescription
            }
            busyPluginID = nil
        }
    }

    func remove(_ installation: PluginInstallation) {
        busyPluginID = installation.id
        Task {
            do {
                try await manager.removePlugin(id: installation.id)
                installed = try await manager.installedPlugins()
            } catch {
                errorMessage = error.localizedDescription
            }
            busyPluginID = nil
        }
    }

    func inspectSource() {
        guard let url = URL(string: sourceURLText) else {
            errorMessage = PluginError.invalidURL.localizedDescription
            return
        }
        isRefreshing = true
        Task {
            do {
                pendingSource = try await manager.inspectThirdPartySource(url: url)
            } catch {
                errorMessage = error.localizedDescription
            }
            isRefreshing = false
        }
    }

    func trustPendingSource() {
        guard let candidate = pendingSource else { return }
        Task {
            do {
                _ = try await manager.trustThirdPartySource(candidate)
                sourceURLText = ""
                pendingSource = nil
                refresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func removeSource(_ source: PluginSource) {
        Task {
            do {
                try await manager.removeSource(id: source.id)
                refresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func chooseLocalPlugin() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ipalensplugin") ?? .zip]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Local plugins are not reviewed or controlled by the IPALens project."
        if panel.runModal() == .OK {
            pendingLocalURL = panel.url
        }
    }

    func importPendingLocalPlugin() {
        guard let url = pendingLocalURL else { return }
        Task {
            do {
                _ = try await manager.importLocalPackage(url: url, allowUnsigned: true)
                pendingLocalURL = nil
                refresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func installedVersion(for pluginID: String) -> String? {
        installed.first { $0.id == pluginID }?.manifest.version
    }
}

struct PluginSettingsView: View {
    @StateObject private var model = PluginSettingsModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Plugins").font(.title2.bold())
                    Text("Add platform support without adding executable plugin code.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isRefreshing { ProgressView().controlSize(.small) }
                Button("Check for Updates", action: model.refresh)
                    .disabled(model.isRefreshing)
            }
            .padding()

            List {
                Section("Built In") {
                    pluginRow(
                        name: "iOS App Support",
                        publisher: "IPALens Project",
                        detail: "Version 1 · Built in · Cannot be removed\nCapability: IPA archives · No network required",
                        trailing: AnyView(Text("Built In").foregroundStyle(.secondary))
                    )
                }

                Section("Available and Installed") {
                    if model.available.isEmpty && model.installed.isEmpty && !model.isRefreshing {
                        Text("No plugin catalog entries are currently available.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.available) { plugin in
                        let installation = model.installed.first { $0.id == plugin.entry.id }
                        let installedVersion = installation?.manifest.version
                        let hasUpdate = installedVersion.map {
                            plugin.entry.version.compare($0, options: .numeric) == .orderedDescending
                        } ?? false
                        let actionTitle = installedVersion == nil ? "Install" : hasUpdate ? "Update" : "Installed"
                        let status = installedVersion == nil ? "Available" : hasUpdate ? "Update available" : "Installed"
                        let capabilities = plugin.entry.capabilities.map(\.displayName).joined(separator: ", ")
                        let origin = plugin.entry.artifactURL.host ?? plugin.source.name
                        pluginRow(
                            name: plugin.entry.name,
                            publisher: plugin.entry.publisher,
                            detail: "Status: \(status) · Version \(plugin.entry.version) · \(ByteCountFormatter.string(fromByteCount: plugin.entry.downloadSize, countStyle: .file))\nOrigin: \(origin) · \(plugin.source.trust == .official ? "Official" : "Third-party") · Signature verified by catalog\nCapabilities: \(capabilities)\nKey: \(plugin.source.keyFingerprint)",
                            trailing: AnyView(
                                HStack {
                                    if model.busyPluginID == plugin.entry.id {
                                        ProgressView().controlSize(.small)
                                        Button("Cancel", role: .cancel, action: model.cancelOperation)
                                    }
                                    Button(actionTitle) {
                                        model.install(plugin)
                                    }
                                    .disabled((installedVersion != nil && !hasUpdate) || model.busyPluginID != nil)
                                    if let installation {
                                        Button("Remove", role: .destructive) { model.remove(installation) }
                                            .disabled(model.busyPluginID != nil)
                                    }
                                }
                            )
                        )
                    }
                    ForEach(model.installed.filter { installation in
                        !model.available.contains { $0.entry.id == installation.id }
                    }) { installation in
                        pluginRow(
                            name: installation.manifest.name,
                            publisher: installation.manifest.publisher,
                            detail: "Version \(installation.manifest.version) · \(installation.sourceName)\nSignature state: \(trustDescription(installation.trust))\nCapabilities: \(installation.manifest.capabilities.map(\.displayName).joined(separator: ", "))",
                            trailing: AnyView(
                                Button("Remove", role: .destructive) { model.remove(installation) }
                                    .disabled(model.busyPluginID != nil)
                            )
                        )
                    }
                }

                Section("Plugin Sources") {
                    ForEach(model.sources) { source in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.name)
                                Text(source.catalogURL.absoluteString)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Text(source.keyFingerprint)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Text(source.trust == .official ? "Official" : "Third-Party")
                                .font(.caption)
                                .foregroundStyle(source.trust == .official ? .green : .orange)
                            if source.trust == .thirdParty {
                                Button("Remove", role: .destructive) { model.removeSource(source) }
                            }
                        }
                    }
                    HStack {
                        TextField("https://example.com/catalog-v1.json", text: $model.sourceURLText)
                        Button("Add Source", action: model.inspectSource)
                            .disabled(model.sourceURLText.isEmpty || model.isRefreshing)
                    }
                    Text("Third-party sources are not reviewed or controlled by the IPALens project.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Section("Local Plugins") {
                    Button("Import Local Plugin…", action: model.chooseLocalPlugin)
                    Text("Local plugins can be unsigned. Review their origin before importing them.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .task { model.refresh() }
        .alert("Plugin Error", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "An unknown plugin error occurred.")
        }
        .alert("Trust Third-Party Source?", isPresented: Binding(
            get: { model.pendingSource != nil },
            set: { if !$0 { model.pendingSource = nil } }
        )) {
            Button("Trust Source", action: model.trustPendingSource)
            Button("Cancel", role: .cancel) { model.pendingSource = nil }
        } message: {
            if let source = model.pendingSource {
                Text("\(source.name) is not controlled by the IPALens project. Verify this key fingerprint before trusting it:\n\n\(source.keyFingerprint)")
            }
        }
        .alert("Import Unreviewed Local Plugin?", isPresented: Binding(
            get: { model.pendingLocalURL != nil },
            set: { if !$0 { model.pendingLocalURL = nil } }
        )) {
            Button("Import", action: model.importPendingLocalPlugin)
            Button("Cancel", role: .cancel) { model.pendingLocalURL = nil }
        } message: {
            Text("This local plugin is not controlled by the IPALens project. IPALens will validate its data-only package, but cannot verify an unsigned publisher.")
        }
    }

    private func pluginRow(name: String, publisher: String, detail: String, trailing: AnyView) -> some View {
        HStack {
            Image(systemName: "puzzlepiece.extension")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).fontWeight(.medium)
                Text(publisher).font(.caption).foregroundStyle(.secondary)
                Text(detail).font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            trailing
        }
        .padding(.vertical, 3)
    }

    private func trustDescription(_ trust: PluginTrust) -> String {
        switch trust {
        case .builtIn: "Built in"
        case .official: "Official signature verified"
        case .thirdParty: "Pinned third-party signature verified"
        case .localSigned: "Local signature verified"
        case .localUnsigned: "Unsigned local import"
        }
    }
}
