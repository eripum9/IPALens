import AppKit
import Combine
import IPALensPluginKit
import SwiftUI
import UniformTypeIdentifiers

private struct AvailablePlugin: Identifiable, Hashable {
    var id: String { source.id.uuidString + ":" + entry.id }
    let entry: PluginCatalogEntry
    let source: PluginSource
}

private enum PluginStoreDestination: String, CaseIterable, Identifiable {
    case discover = "Discover"
    case updates = "Updates"
    case sources = "Plugin Sources"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .discover: "sparkles.rectangle.stack.fill"
        case .updates: "arrow.triangle.2.circlepath.circle.fill"
        case .sources: "network"
        }
    }
}

private enum PluginActionState {
    case builtIn
    case download
    case update
    case uninstall
}

private struct PluginStoreItem: Identifiable, Hashable {
    let id: String
    let available: AvailablePlugin?
    let installation: PluginInstallation?
    let isBuiltIn: Bool

    var pluginID: String {
        available?.entry.id ?? installation?.id ?? "com.eripum9.ipalens.platform.ios"
    }

    var name: String {
        if isBuiltIn { return "iOS App Support" }
        return available?.entry.name ?? installation?.manifest.name ?? "Unknown Plugin"
    }

    var maker: String {
        if isBuiltIn { return "IPALens Project" }
        return available?.entry.publisher ?? installation?.manifest.publisher ?? "Unknown Maker"
    }

    var provider: String {
        if isBuiltIn { return "Included with IPALens" }
        return available?.source.name ?? installation?.sourceName ?? "Unknown Provider"
    }

    var providerDomain: String? {
        available?.source.catalogURL.host
    }

    var summary: String {
        let value: String
        if isBuiltIn {
            value = "Browse and inspect iOS IPA packages using IPALens’ built-in platform definition."
        } else {
            value = available?.entry.description ?? installation?.manifest.description ?? ""
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? PluginPackageDetails.missingReadmeText
            : value
    }

    var displayedVersion: String {
        if isBuiltIn { return "Built In" }
        return available?.entry.version ?? installation?.manifest.version ?? "Unknown"
    }

    var installedVersion: String? { installation?.manifest.version }
    var downloadSize: Int64? { available?.entry.downloadSize }

    var trustDescription: String {
        if isBuiltIn { return "Built into IPALens" }
        switch available?.source.trust ?? installation?.trust {
        case .official: return "Official · Signature Verified"
        case .thirdParty: return "Third-Party · Pinned Signature"
        case .localSigned: return "Local · Signature Verified"
        case .localUnsigned: return "Local · Unsigned"
        case .builtIn: return "Built into IPALens"
        case nil: return "Provider Unknown"
        }
    }

    var actionState: PluginActionState {
        if isBuiltIn { return .builtIn }
        guard let installation else { return .download }
        guard let available else { return .uninstall }
        return available.entry.version.compare(
            installation.manifest.version,
            options: .numeric
        ) == .orderedDescending ? .update : .uninstall
    }

    var hasUpdate: Bool { actionState == .update }

    static let builtIn = PluginStoreItem(
        id: "built-in-ios",
        available: nil,
        installation: nil,
        isBuiltIn: true
    )
}

@MainActor
private final class PluginStoreModel: ObservableObject {
    @Published var installed: [PluginInstallation] = []
    @Published var available: [AvailablePlugin] = []
    @Published var sources: [PluginSource] = []
    @Published var items: [PluginStoreItem] = [.builtIn]
    @Published var destination: PluginStoreDestination? = .discover
    @Published var selectedItemID: String?
    @Published var details: PluginPackageDetails?
    @Published var isLoadingDetails = false
    @Published var isRefreshing = false
    @Published var busyPluginID: String?
    @Published var operationProgress: Double?
    @Published var errorMessage: String?
    @Published var sourceURLText = ""
    @Published var pendingSource: PluginSourceCandidate?
    @Published var pendingLocalURL: URL?

    private let manager = PluginManager.shared
    private var refreshTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var detailGeneration = UUID()
    private var detailCache: [String: PluginPackageDetails] = [:]

    deinit {
        refreshTask?.cancel()
        operationTask?.cancel()
        detailTask?.cancel()
    }

    var selectedItem: PluginStoreItem? {
        guard let selectedItemID else { return nil }
        return items.first { $0.id == selectedItemID }
    }

    var updateItems: [PluginStoreItem] {
        items.filter(\.hasUpdate)
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                async let installedPlugins = manager.installedPlugins()
                async let pluginSources = manager.sources()
                async let catalogPlugins = manager.availablePlugins()
                installed = try await installedPlugins
                sources = try await pluginSources
                available = try await catalogPlugins.map { AvailablePlugin(entry: $0.0, source: $0.1) }
                rebuildItems()
            } catch is CancellationError {
                // Closing the store cancels catalog work without changing installed plugins.
            } catch {
                errorMessage = error.localizedDescription
            }
            isRefreshing = false
        }
    }

    func open(_ item: PluginStoreItem) {
        selectedItemID = item.id
        loadDetails(for: item)
    }

    func closeDetails() {
        selectedItemID = nil
        details = nil
        detailTask?.cancel()
    }

    func performPrimaryAction(for item: PluginStoreItem) {
        switch item.actionState {
        case .builtIn:
            return
        case .download, .update:
            install(item)
        case .uninstall:
            uninstall(item)
        }
    }

    func cancelOperation() {
        operationTask?.cancel()
        operationTask = nil
        busyPluginID = nil
        operationProgress = nil
    }

    func inspectSource() {
        guard let url = URL(string: sourceURLText) else {
            errorMessage = PluginError.invalidURL.localizedDescription
            return
        }
        isRefreshing = true
        Task { [weak self] in
            guard let self else { return }
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
        Task { [weak self] in
            guard let self else { return }
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
        Task { [weak self] in
            guard let self else { return }
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
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await manager.importLocalPackage(url: url, allowUnsigned: true)
                pendingLocalURL = nil
                try await reloadInstalledPlugins()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func rebuildItems() {
        var rebuilt: [PluginStoreItem] = [.builtIn]
        rebuilt.append(contentsOf: available.map { plugin in
            PluginStoreItem(
                id: plugin.id,
                available: plugin,
                installation: installed.first { $0.id == plugin.entry.id },
                isBuiltIn: false
            )
        })
        let advertisedIDs = Set(available.map { $0.entry.id })
        rebuilt.append(contentsOf: installed.filter { !advertisedIDs.contains($0.id) }.map { installation in
            PluginStoreItem(
                id: "installed:\(installation.id)",
                available: nil,
                installation: installation,
                isBuiltIn: false
            )
        })
        items = rebuilt
        if let selectedItemID, !items.contains(where: { $0.id == selectedItemID }) {
            self.selectedItemID = nil
            details = nil
        }
    }

    private func install(_ item: PluginStoreItem) {
        guard let available = item.available else { return }
        operationTask?.cancel()
        busyPluginID = item.pluginID
        operationProgress = 0
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await manager.install(
                    entry: available.entry,
                    from: available.source,
                    progress: { [weak self] fraction in
                        Task { @MainActor [weak self] in
                            guard self?.busyPluginID == item.pluginID else { return }
                            self?.operationProgress = fraction
                        }
                    }
                )
                detailCache.removeAll()
                try await reloadInstalledPlugins()
                if let refreshedItem = items.first(where: { $0.id == item.id }) {
                    loadDetails(for: refreshedItem)
                }
            } catch is CancellationError {
                // Atomic installation keeps the previous version active.
            } catch {
                errorMessage = error.localizedDescription
            }
            busyPluginID = nil
            operationProgress = nil
        }
    }

    private func uninstall(_ item: PluginStoreItem) {
        guard item.installation != nil else { return }
        operationTask?.cancel()
        busyPluginID = item.pluginID
        operationProgress = nil
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await manager.removePlugin(id: item.pluginID)
                detailCache.removeAll()
                try await reloadInstalledPlugins()
                if let refreshedItem = items.first(where: { $0.id == item.id }) {
                    loadDetails(for: refreshedItem)
                } else {
                    closeDetails()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            busyPluginID = nil
            operationProgress = nil
        }
    }

    private func reloadInstalledPlugins() async throws {
        installed = try await manager.installedPlugins()
        rebuildItems()
    }

    private func loadDetails(for item: PluginStoreItem) {
        detailTask?.cancel()
        let cacheKey = item.id + ":" + item.displayedVersion
        if let cached = detailCache[cacheKey] {
            details = cached
            isLoadingDetails = false
            return
        }
        let generation = UUID()
        detailGeneration = generation
        isLoadingDetails = true
        details = nil
        detailTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded: PluginPackageDetails
                if item.isBuiltIn {
                    loaded = Self.builtInDetails
                } else if let installation = item.installation, !item.hasUpdate {
                    loaded = try await manager.packageDetails(for: installation)
                } else if let available = item.available {
                    do {
                        loaded = try await manager.packageDetails(entry: available.entry, from: available.source)
                    } catch {
                        if let installation = item.installation {
                            loaded = try await manager.packageDetails(for: installation)
                        } else {
                            throw error
                        }
                    }
                } else if let installation = item.installation {
                    loaded = try await manager.packageDetails(for: installation)
                } else {
                    throw PluginError.pluginNotFound
                }
                guard detailGeneration == generation, selectedItemID == item.id else { return }
                detailCache[cacheKey] = loaded
                details = loaded
            } catch is CancellationError {
                return
            } catch {
                guard detailGeneration == generation else { return }
                errorMessage = error.localizedDescription
            }
            if detailGeneration == generation {
                isLoadingDetails = false
            }
        }
    }

    private static let builtInDetails = PluginPackageDetails(
        manifest: PluginManifestV1(
            id: "com.eripum9.ipalens.platform.ios",
            name: "iOS App Support",
            version: "1",
            publisher: "IPALens Project",
            description: "Built-in support for iOS IPA packages.",
            capabilities: [.applicationBundle, .zipArchive],
            platform: .iOS
        ),
        readme: """
        # iOS App Support

        iOS package inspection is included with IPALens and works offline. It provides the file browser, metadata, signing, entitlement, privacy, framework, extension, binary, audio, video, and source-code previews used for IPA packages.

        The built-in definition cannot be removed and never executes application code.
        """,
        hasReadme: true,
        permissions: [
            .init(
                id: "user-selected-files",
                kind: .userSelectedFiles,
                title: "Files and Folders",
                explanation: "Reads only IPA packages and export locations selected by the user.",
                evidence: "Built-in IPALens file access"
            ),
            .init(
                id: "application-bundles",
                kind: .applicationBundles,
                title: "Application Bundles",
                explanation: "Reads iOS application bundle metadata and contents without running them.",
                evidence: "Built-in capability: applicationBundle"
            ),
            .init(
                id: "zip-archives",
                kind: .archives,
                title: "Compressed Archives",
                explanation: "Indexes IPA ZIP contents using IPALens’ archive safety limits.",
                evidence: "Built-in capability: zipArchive"
            )
        ],
        resourcePaths: []
    )
}

struct PluginStoreView: View {
    @StateObject private var model = PluginStoreModel()

    var body: some View {
        NavigationSplitView {
            List(PluginStoreDestination.allCases, selection: $model.destination) { destination in
                Label(destination.rawValue, systemImage: destination.symbol)
                    .tag(Optional(destination))
            }
            .navigationTitle("Plugins")
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Data-only plugins", systemImage: "checkmark.shield.fill")
                        .font(.caption.weight(.semibold))
                    Text("Plugins are inspected before activation and cannot contain executable code.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
        } detail: {
            detailContent
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.isRefreshing {
                    ProgressView().controlSize(.small)
                }
                Button(action: model.refresh) {
                    Label("Check for Updates", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshing)
                Button(action: model.chooseLocalPlugin) {
                    Label("Import Local Plugin", systemImage: "square.and.arrow.down")
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
            Text("This local plugin is not controlled by the IPALens project. IPALens validates its data-only package, but cannot verify an unsigned publisher.")
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if model.destination == .sources {
            PluginSourcesView(model: model)
        } else if let item = model.selectedItem {
            PluginDetailView(item: item, model: model)
                .id(item.id)
        } else {
            PluginStorefrontView(
                title: model.destination == .updates ? "Updates" : "Discover",
                subtitle: model.destination == .updates
                    ? "Keep your installed platform support current."
                    : "Expand what IPALens can inspect with verified, data-only plugins.",
                items: model.destination == .updates ? model.updateItems : model.items,
                emptyMessage: model.destination == .updates ? "All plugins are up to date." : "No plugins are available.",
                model: model
            )
        }
    }
}

private struct PluginStorefrontView: View {
    let title: String
    let subtitle: String
    let items: [PluginStoreItem]
    let emptyMessage: String
    @ObservedObject var model: PluginStoreModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text(subtitle)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                if let featured = items.first(where: { !$0.isBuiltIn }) {
                    FeaturedPluginCard(
                        item: featured,
                        isBusy: model.busyPluginID == featured.pluginID,
                        progress: model.operationProgress,
                        onOpen: { model.open(featured) },
                        onAction: { model.performPrimaryAction(for: featured) },
                        onCancel: model.cancelOperation
                    )
                }

                if items.isEmpty {
                    EmptyStateView(
                        title: emptyMessage,
                        symbol: "checkmark.circle.fill",
                        description: "Use Check for Updates to refresh approved plugin catalogs."
                    )
                    .frame(maxWidth: .infinity, minHeight: 360)
                } else {
                    Text("Plugins")
                        .font(.title2.bold())
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 360), spacing: 18)],
                        alignment: .leading,
                        spacing: 18
                    ) {
                        ForEach(items) { item in
                            PluginCard(
                                item: item,
                                isBusy: model.busyPluginID == item.pluginID,
                                progress: model.operationProgress,
                                onOpen: { model.open(item) },
                                onAction: { model.performPrimaryAction(for: item) },
                                onCancel: model.cancelOperation
                            )
                        }
                    }
                }
            }
            .padding(30)
            .frame(maxWidth: 1_150, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct FeaturedPluginCard: View {
    let item: PluginStoreItem
    let isBusy: Bool
    let progress: Double?
    let onOpen: () -> Void
    let onAction: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 22) {
            Button(action: onOpen) {
                HStack(spacing: 22) {
                    PluginArtwork(item: item, size: 112)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("FEATURED PLUGIN")
                            .font(.caption.bold())
                            .foregroundStyle(Color.accentColor)
                        Text(item.name)
                            .font(.system(size: 27, weight: .bold, design: .rounded))
                        Text(item.summary)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                        Text("By \(item.maker)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            PluginActionControl(
                state: item.actionState,
                isBusy: isBusy,
                progress: progress,
                onAction: onAction,
                onCancel: onCancel
            )
        }
        .padding(24)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.14), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
        }
    }
}

private struct PluginCard: View {
    let item: PluginStoreItem
    let isBusy: Bool
    let progress: Double?
    let onOpen: () -> Void
    let onAction: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 15) {
            Button(action: onOpen) {
                HStack(spacing: 15) {
                    PluginArtwork(item: item, size: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name)
                            .font(.headline)
                            .lineLimit(1)
                        Text(item.summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Text(item.maker)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            PluginActionControl(
                state: item.actionState,
                isBusy: isBusy,
                progress: progress,
                onAction: onAction,
                onCancel: onCancel
            )
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }
}

private struct PluginDetailView: View {
    let item: PluginStoreItem
    @ObservedObject var model: PluginStoreModel
    @State private var selectedTab = 0

    private var permissions: [PluginPermission] {
        var values = model.details?.permissions ?? []
        if let source = item.available?.source {
            values.append(.init(
                id: "provider-network",
                kind: .providerNetwork,
                title: "Downloads and Updates",
                explanation: "IPALens contacts this approved provider only when you open Plugins, check for updates, or choose an install action.",
                evidence: source.catalogURL.host ?? source.catalogURL.absoluteString
            ))
        }
        return values
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Button(action: model.closeDetails) {
                    Label("Plugins", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .padding(.bottom, 24)

                HStack(alignment: .bottom, spacing: 24) {
                    PluginArtwork(item: item, size: 132)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(item.name)
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                        Text(item.summary)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                        Text("By \(item.maker)")
                            .font(.headline)
                        Text("Provided by \(item.provider)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if let providerDomain = item.providerDomain {
                            Text(providerDomain)
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer(minLength: 20)
                    PluginActionControl(
                        state: item.actionState,
                        isBusy: model.busyPluginID == item.pluginID,
                        progress: model.operationProgress,
                        onAction: { model.performPrimaryAction(for: item) },
                        onCancel: model.cancelOperation
                    )
                    .controlSize(.large)
                }

                HStack(spacing: 0) {
                    MetadataColumn(title: "VERSION", value: item.displayedVersion)
                    Divider().frame(height: 42)
                    MetadataColumn(
                        title: "SIZE",
                        value: item.downloadSize.map {
                            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
                        } ?? "Included"
                    )
                    Divider().frame(height: 42)
                    MetadataColumn(title: "VERIFICATION", value: item.trustDescription)
                }
                .padding(.vertical, 18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .padding(.vertical, 26)

                Picker("Plugin information", selection: $selectedTab) {
                    Text("Overview").tag(0)
                    Text("Permissions").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                .padding(.bottom, 24)

                if model.isLoadingDetails {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Inspecting plugin information…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 280)
                } else if selectedTab == 0 {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("About This Plugin")
                            .font(.title2.bold())
                        if model.details?.hasReadme == false {
                            Label("README.md was not provided by the plugin maker.", systemImage: "doc.badge.ellipsis")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        MarkdownReadmeView(markdown: model.details?.readme ?? PluginPackageDetails.missingReadmeText)
                    }
                } else {
                    PluginPermissionsView(permissions: permissions)
                }

                Divider().padding(.vertical, 28)
                HStack {
                    Label("Read-only, data-only plugin", systemImage: "checkmark.shield.fill")
                    Spacer()
                    Text(item.pluginID)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(32)
            .frame(maxWidth: 930, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct PluginPermissionsView: View {
    let permissions: [PluginPermission]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Permissions")
                    .font(.title2.bold())
                Text("IPALens derives this list from declared capabilities and a static scan of the plugin package. Plugins are never executed during the scan.")
                    .foregroundStyle(.secondary)
            }

            if permissions.isEmpty {
                Label("No additional access or command references were found.", systemImage: "checkmark.shield.fill")
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                ForEach(permissions) { permission in
                    HStack(alignment: .top, spacing: 16) {
                        PermissionIcon(kind: permission.kind)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(permission.title)
                                .font(.headline)
                            Text(permission.explanation)
                                .foregroundStyle(.secondary)
                            Text(permission.evidence)
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                    }
                    .padding(17)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }

            Label(
                "These are IPALens host capabilities, not macOS permission grants. Data-only plugins cannot run commands or access files on their own.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct PermissionIcon: View {
    let kind: PluginPermissionKind

    private var color: Color {
        switch kind {
        case .userSelectedFiles: .blue
        case .applicationBundles: .indigo
        case .archives: .orange
        case .diskImages: .purple
        case .installerPackages: .pink
        case .providerNetwork: .cyan
        case .systemCommand: .gray
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(color.gradient)
            Image(systemName: kind.symbolName)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 46, height: 46)
        .shadow(color: color.opacity(0.2), radius: 5, y: 2)
        .accessibilityHidden(true)
    }
}

private struct PluginSourcesView: View {
    @ObservedObject var model: PluginStoreModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Plugin Sources")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("Manage official and third-party storefront providers.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 12) {
                    ForEach(model.sources) { source in
                        HStack(spacing: 14) {
                            PermissionIcon(kind: .providerNetwork)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(source.name).font(.headline)
                                Text(source.catalogURL.absoluteString)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Text("Key \(source.keyFingerprint)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(source.trust == .official ? "OFFICIAL" : "THIRD-PARTY")
                                .font(.caption.bold())
                                .foregroundStyle(source.trust == .official ? Color.green : Color.orange)
                            if source.trust == .thirdParty {
                                Button("Remove", role: .destructive) { model.removeSource(source) }
                            }
                        }
                        .padding(16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Add a Source").font(.title2.bold())
                    HStack {
                        TextField("https://example.com/catalog-v1.json", text: $model.sourceURLText)
                            .textFieldStyle(.roundedBorder)
                        Button("Review Source", action: model.inspectSource)
                            .buttonStyle(.borderedProminent)
                            .disabled(model.sourceURLText.isEmpty || model.isRefreshing)
                    }
                    Label(
                        "Third-party sources are not reviewed or controlled by the IPALens project.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(alignment: .leading, spacing: 9) {
                    Text("Local Plugins").font(.title2.bold())
                    Text("Import a local .ipalensplugin package. Unsigned packages require explicit confirmation and are still checked for forbidden code and unsafe paths.")
                        .foregroundStyle(.secondary)
                    Button("Import Local Plugin…", action: model.chooseLocalPlugin)
                        .buttonStyle(.bordered)
                }
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding(30)
            .frame(maxWidth: 930, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct PluginActionControl: View {
    let state: PluginActionState
    let isBusy: Bool
    let progress: Double?
    let onAction: () -> Void
    let onCancel: () -> Void

    var body: some View {
        if isBusy, let progress {
            Button(action: onCancel) {
                ZStack {
                    Circle()
                        .stroke(Color.accentColor.opacity(0.2), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: max(0.02, min(1, progress)))
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.accentColor)
                        .frame(width: 8, height: 8)
                }
                .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .help("Cancel Download")
            .accessibilityLabel("Cancel download, \(Int(progress * 100)) percent complete")
        } else if isBusy {
            ProgressView()
                .controlSize(.small)
                .frame(width: 44)
        } else {
            switch state {
            case .builtIn:
                Text("BUILT IN")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            case .download:
                Button(action: onAction) {
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 32, height: 32)
                        .background(Color.accentColor.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Download Plugin")
                .accessibilityLabel("Download plugin")
            case .update:
                Button("UPDATE", action: onAction)
                    .font(.caption.bold())
                    .buttonStyle(StoreCapsuleButtonStyle(tint: .accentColor))
            case .uninstall:
                Button("UNINSTALL", action: onAction)
                    .font(.caption.bold())
                    .buttonStyle(StoreCapsuleButtonStyle(tint: .red))
            }
        }
    }
}

private struct StoreCapsuleButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(tint.opacity(configuration.isPressed ? 0.20 : 0.12), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

private struct PluginArtwork: View {
    let item: PluginStoreItem
    let size: CGFloat

    private var colors: [Color] {
        if item.isBuiltIn { return [.blue, .indigo] }
        if item.pluginID.contains("macos") { return [.gray.opacity(0.85), .blue.opacity(0.75)] }
        return [.purple, .blue]
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .stroke(.white.opacity(0.28), lineWidth: 1)
            Image(systemName: item.isBuiltIn ? "iphone.gen3" : "puzzlepiece.extension.fill")
                .font(.system(size: size * 0.43, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.16), radius: size * 0.08, y: size * 0.04)
        .accessibilityHidden(true)
    }
}

private struct MetadataColumn: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 5) {
            Text(title)
                .font(.caption2.bold())
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct MarkdownReadmeView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            ForEach(Array(MarkdownBlock.parse(markdown).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let value):
                    inlineText(value)
                        .font(headingFont(level))
                        .padding(.top, level <= 2 ? 8 : 2)
                case .paragraph(let value):
                    inlineText(value)
                        .font(.body)
                        .lineSpacing(3)
                case .bullet(let value):
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text("•").foregroundStyle(Color.accentColor)
                        inlineText(value).font(.body)
                    }
                case .code(let value):
                    ScrollView(.horizontal) {
                        Text(value)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private func inlineText(_ value: String) -> Text {
        if let attributed = try? AttributedString(markdown: value) {
            return Text(attributed)
        }
        return Text(value)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title.bold()
        case 2: .title2.bold()
        default: .title3.bold()
        }
    }
}

private enum MarkdownBlock {
    case heading(Int, String)
    case paragraph(String)
    case bullet(String)
    case code(String)

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var codeLines: [String] = []
        var isCode = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph.removeAll()
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                flushParagraph()
                if isCode {
                    blocks.append(.code(codeLines.joined(separator: "\n")))
                    codeLines.removeAll()
                }
                isCode.toggle()
                continue
            }
            if isCode {
                codeLines.append(rawLine)
                continue
            }
            if line.isEmpty {
                flushParagraph()
                continue
            }
            let hashCount = line.prefix(while: { $0 == "#" }).count
            if hashCount > 0, hashCount <= 6,
               line.dropFirst(hashCount).first == " " {
                flushParagraph()
                blocks.append(.heading(hashCount, String(line.dropFirst(hashCount + 1))))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph()
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else {
                paragraph.append(line)
            }
        }
        flushParagraph()
        if !codeLines.isEmpty { blocks.append(.code(codeLines.joined(separator: "\n"))) }
        return blocks
    }
}
