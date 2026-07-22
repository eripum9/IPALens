import IPALensCore
import SwiftUI

private func countLabel(_ count: Int, singular: String, plural: String) -> String {
    "\(count.formatted()) \(count == 1 ? singular : plural)"
}

struct EmptyStateView: View {
    let title: String
    let symbol: String
    var description: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 42, weight: .thin))
                .foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            if let description {
                Text(description)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ClassicActivityIndicator: View {
    var size: CGFloat = 38
    @State private var rotation = 0.0

    var body: some View {
        ZStack {
            ForEach(0..<12, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(Color.secondary.opacity(0.2 + Double(index) * 0.065))
                    .frame(width: max(2.5, size * 0.09), height: size * 0.30)
                    .offset(y: -size * 0.34)
                    .rotationEffect(.degrees(Double(index) * 30))
            }
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(rotation))
        .onAppear {
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
        .accessibilityLabel("Loading")
    }
}

struct LoadingStateView: View {
    let message: String
    var detail: String?

    var body: some View {
        VStack(spacing: 14) {
            ClassicActivityIndicator(size: 44)
            Text(message).font(.headline)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct RootView: View {
    @StateObject private var model = WorkspaceModel()

    var body: some View {
        Group {
            if model.snapshot == nil {
                WelcomeView(model: model)
            } else {
                ExplorerView(model: model)
            }
        }
        .dropDestination(for: URL.self, action: { urls, _ in
            guard let url = urls.first else { return false }
            model.open(url: url)
            return true
        }, isTargeted: { model.isDropTargeted = $0 })
        .onOpenURL { model.open(url: $0) }
        .focusedSceneValue(\.openIPAAction, WindowAction(perform: model.presentOpenPanel))
        .focusedSceneValue(
            \.exportReportAction,
            model.snapshot == nil ? nil : WindowAction(perform: model.exportReport)
        )
        .focusedSceneValue(
            \.exportEntryAction,
            model.selectedEntry?.kind == .file ? WindowAction(perform: model.exportSelectedEntry) : nil
        )
        .focusedSceneValue(
            \.copyPathAction,
            model.selectedEntryPath == nil ? nil : WindowAction(perform: model.copySelectedPath)
        )
        .alert("IPALens Couldn’t Complete the Request", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "An unknown error occurred.")
        }
        .alert("macOS App Support Required", isPresented: Binding(
            get: { model.pluginRequiredURL != nil },
            set: { if !$0 { model.dismissPluginOffer() } }
        )) {
            Button("Install") { model.installRequiredPlugin() }
            Button("Not Now", role: .cancel) { model.dismissPluginOffer() }
        } message: {
            Text("This source requires the official macOS App Support plugin. IPALens will download, verify, and install it from GitHub after you confirm.")
        }
        .overlay {
            if model.isInstallingPlugin {
                VStack(spacing: 16) {
                    ClassicActivityIndicator(size: 52)
                    Text(model.pluginInstallMessage)
                        .font(.headline)
                    Text("The plugin is verified before it becomes active.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Cancel", role: .cancel, action: model.cancelPluginInstallation)
                }
                .padding(28)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .shadow(radius: 18, y: 8)
            }
        }
    }
}

private struct WelcomeView: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "shippingbox.and.arrow.backward")
                .font(.system(size: 72, weight: .thin))
                .foregroundStyle(model.isDropTargeted ? Color.accentColor : .secondary)
            VStack(spacing: 8) {
                Text("IPALens")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("Inspect iOS and macOS app packages privately")
                    .foregroundStyle(.secondary)
            }
            Text("Drop an app package here, or choose one to begin")
                .font(.title3)
            Button("Open Package…", action: model.presentOpenPanel)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut("o")
            HStack(spacing: 20) {
                Label("Works offline", systemImage: "network.slash")
                Label("Read only", systemImage: "lock")
                Label("No telemetry", systemImage: "eye.slash")
            }
            .foregroundStyle(.secondary)
            .font(.callout)
            Spacer()
            Text("IPALens never executes package contents. Inspection notes describe observable evidence—not a malware verdict.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 20)
        }
        .padding(40)
        .background(model.isDropTargeted ? Color.accentColor.opacity(0.06) : Color.clear)
        .animation(.easeInOut(duration: 0.15), value: model.isDropTargeted)
        .overlay {
            if model.isLoading {
                VStack(spacing: 16) {
                    ClassicActivityIndicator(size: 52)
                    Text(model.progress?.message ?? "Opening package")
                        .font(.headline)
                    if let progress = model.progress, progress.total > 1 {
                        ProgressView(value: progress.fractionCompleted)
                            .frame(width: 260)
                    }
                    Button("Cancel", action: model.cancelLoading)
                }
                .padding(28)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .shadow(radius: 18, y: 8)
            }
        }
    }
}

private struct ExplorerView: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 175, ideal: 205, max: 260)
        } content: {
            MiddlePane(model: model)
                .navigationSplitViewColumnWidth(min: 280, ideal: 360, max: 520)
        } detail: {
            DetailPane(model: model)
        }
        .navigationTitle(model.snapshot?.sourceFileName ?? "IPALens")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let bundles = model.snapshot?.appBundles, bundles.count > 1 {
                    Picker("App bundle", selection: Binding(
                        get: { model.selectedBundlePath ?? bundles[0].bundlePath },
                        set: { model.selectedBundlePath = $0 }
                    )) {
                        ForEach(bundles) { bundle in
                            Text(bundle.displayName).tag(bundle.bundlePath)
                        }
                    }
                    .frame(maxWidth: 220)
                }

                Button(action: model.presentOpenPanel) {
                    Label("Open Package", systemImage: "folder.badge.plus")
                }

                Menu {
                    Button("Inspection Report…", action: model.exportReport)
                    Button("Selected File…", action: model.exportSelectedEntry)
                        .disabled(model.selectedEntry?.kind != .file)
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.isLoading, let progress = model.progress {
                HStack(spacing: 10) {
                    ClassicActivityIndicator(size: 24)
                    ProgressView(value: progress.fractionCompleted)
                        .frame(maxWidth: 180)
                    Text(progress.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button("Cancel", action: model.cancelLoading)
                        .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.bar)
            }
        }
    }
}

private struct SidebarView: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        List(SidebarSection.allCases, selection: $model.selectedSection) { section in
            Label(title(for: section), systemImage: section.symbol)
                .tag(section)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 7) {
                Label("READ-ONLY MODE", systemImage: "lock.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.green)
                if let snapshot = model.snapshot {
                    Text(countLabel(snapshot.entries.count, singular: "entry", plural: "entries"))
                    Text(ByteCountFormatter.string(fromByteCount: snapshot.sourceFileSize, countStyle: .file))
                    if !snapshot.issues.isEmpty {
                        Label(countLabel(snapshot.issues.count, singular: "inspection note", plural: "inspection notes"), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.bar)
        }
    }

    private func title(for section: SidebarSection) -> String {
        if model.snapshot?.platform == .macOS, section == .extensions {
            return "Components"
        }
        return section.rawValue
    }
}

private struct MiddlePane: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        Group {
            switch model.selectedSection {
            case .files:
                FileBrowserView(model: model)
            case .overview:
                OverviewList(model: model)
            case .signing:
                SigningList(model: model)
            case .entitlements:
                EntitlementsList(model: model)
            case .privacy:
                PrivacyList(model: model)
            case .frameworks:
                FrameworkList(model: model)
            case .extensions:
                ExtensionList(model: model)
            case .binary:
                BinaryList(model: model)
            }
        }
        .searchable(text: $model.query, prompt: model.selectedSection == .files ? "Search package files" : "Filter results")
        .toolbar {
            if model.selectedSection == .files {
                ToolbarItem {
                    Toggle(isOn: $model.searchContents) {
                        Label("Include file contents", systemImage: "text.magnifyingglass")
                    }
                    .toggleStyle(.button)
                    .help("Also search text and property-list files up to 5 MiB each")
                }
            }
        }
    }
}

private struct FileBrowserView: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        if !model.query.isEmpty {
            List(model.searchResults, selection: $model.selectedEntryPath) { result in
                VStack(alignment: .leading, spacing: 3) {
                    Label(result.path, systemImage: result.matchKind == "Content" ? "text.magnifyingglass" : "doc")
                        .lineLimit(1)
                    if let snippet = result.snippet {
                        Text(snippet)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .tag(result.path)
            }
            .overlay {
                if model.isSearching {
                    LoadingStateView(
                        message: model.searchContents ? "Searching file contents" : "Searching filenames",
                        detail: "This may take a moment for large packages."
                    )
                } else if model.searchResults.isEmpty {
                    EmptyStateView(
                        title: "No Results",
                        symbol: "magnifyingglass",
                        description: "No package entries match “\(model.query)”."
                    )
                }
            }
        } else {
            List(selection: $model.selectedEntryPath) {
                OutlineGroup(model.treeRoots, children: \.children) { node in
                    EntryRow(entry: node.entry)
                        .tag(node.entry.path)
                }
            }
            .overlay {
                if model.isTreeLoading {
                    LoadingStateView(message: "Building file tree", detail: "Organizing package folders in the background.")
                }
            }
        }
    }
}

private struct EntryRow: View {
    let entry: PackageEntry

    var body: some View {
        HStack {
            Label(entry.name, systemImage: symbol)
                .lineLimit(1)
            Spacer()
            if entry.kind == .file {
                Text(ByteCountFormatter.string(fromByteCount: entry.uncompressedSize, countStyle: .file))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if entry.kind == .symbolicLink {
                Text("symlink")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var symbol: String {
        switch entry.kind {
        case .directory: "folder"
        case .symbolicLink: "link"
        case .file:
            if entry.name.lowercased().hasSuffix(".dylib") { "shippingbox.fill" }
            else if entry.name.lowercased().hasSuffix(".plist") { "list.bullet.rectangle" }
            else if entry.name.lowercased().hasSuffix(".png") { "photo" }
            else { "doc" }
        }
    }
}

private struct OverviewList: View {
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        List {
            Section("App bundles") {
                if model.snapshot?.appBundles.isEmpty != false {
                    Text("No top-level app bundle found")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.snapshot?.appBundles ?? []) { bundle in
                        Button {
                            model.selectedBundlePath = bundle.bundlePath
                        } label: {
                            Label(bundle.displayName, systemImage: "app")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if let issues = model.snapshot?.issues, !issues.isEmpty {
                Section("Inspection notes") {
                    ForEach(issues) { issue in
                        VStack(alignment: .leading) {
                            Label(issue.category, systemImage: issue.severity == .error ? "xmark.octagon" : "exclamationmark.triangle")
                            Text(issue.message).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

private struct SigningList: View {
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        List {
            if let signing = model.selectedSigning {
                Label(signing.status.rawValue.capitalized, systemImage: signing.status == .valid ? "checkmark.seal" : "exclamationmark.shield")
                ForEach(signing.certificates) { certificate in
                    Label(certificate.subject, systemImage: "person.text.rectangle")
                }
                if let profile = signing.provisioning {
                    Label(profile.name ?? "Provisioning profile", systemImage: "doc.badge.gearshape")
                }
            } else {
                EmptyStateView(
                    title: "No Signing Information",
                    symbol: "signature",
                    description: "IPALens could not read a code signature for the selected app bundle."
                )
            }
        }
    }
}

private struct EntitlementsList: View {
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        List {
            ForEach((model.selectedSigning?.entitlements.values.keys.sorted()) ?? [], id: \.self) { key in
                VStack(alignment: .leading) {
                    Text(key).font(.body.monospaced())
                    Text(model.selectedSigning?.entitlements.values[key]?.displayValue ?? "")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .overlay {
            if model.selectedSigning?.entitlements.values.isEmpty != false {
                EmptyStateView(
                    title: "No Entitlements Found",
                    symbol: "key.horizontal",
                    description: "The selected app bundle does not expose readable code-signing entitlements."
                )
            }
        }
    }
}

private struct PrivacyList: View {
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        List {
            Section("Usage descriptions") {
                if model.selectedBundle?.permissions.isEmpty != false {
                    Text("None declared").foregroundStyle(.secondary)
                } else {
                    ForEach(model.selectedBundle?.permissions ?? []) { permission in
                        VStack(alignment: .leading) {
                            Text(permission.key).font(.body.monospaced())
                            Text(permission.description).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Privacy manifests") {
                if model.selectedBundle?.privacyManifestPaths.isEmpty != false {
                    Text("None found").foregroundStyle(.secondary)
                } else {
                    ForEach(model.selectedBundle?.privacyManifestPaths ?? [], id: \.self) { path in
                        Button(path) { model.selectInspectionPath(path) }
                            .buttonStyle(.plain)
                    }
                }
            }
            Section("URL schemes") {
                if model.selectedBundle?.urlSchemes.isEmpty != false {
                    Text("None declared").foregroundStyle(.secondary)
                } else {
                    ForEach(model.selectedBundle?.urlSchemes ?? [], id: \.self) { Text($0).font(.body.monospaced()) }
                }
            }
        }
    }
}

private struct FrameworkList: View {
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        List(model.selectedBundle?.frameworks ?? []) { framework in
            Button { model.selectInspectionPath(framework.path) } label: {
                HStack {
                    Label(framework.name, systemImage: framework.isInjectedCodeCandidate ? "exclamationmark.shield" : "shippingbox")
                    Spacer()
                    Text(framework.kind).font(.caption).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        }
        .overlay {
            if model.selectedBundle?.frameworks.isEmpty != false {
                EmptyStateView(
                    title: "No Embedded Code Found",
                    symbol: "shippingbox",
                    description: "No frameworks or standalone dynamic libraries were detected in the selected app bundle."
                )
            }
        }
    }
}

private struct ExtensionList: View {
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        List(model.selectedBundle?.extensions ?? []) { item in
            Button { model.selectInspectionPath(item.path) } label: {
                VStack(alignment: .leading) {
                    Label(item.name, systemImage: "puzzlepiece.extension")
                    Text(item.bundleIdentifier ?? item.path).font(.caption).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        }
        .overlay {
            if model.selectedBundle?.extensions.isEmpty != false {
                EmptyStateView(
                    title: "No App Extensions Found",
                    symbol: "puzzlepiece.extension",
                    description: "The selected app bundle does not contain any .appex bundles."
                )
            }
        }
    }
}

private struct BinaryList: View {
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        List(model.selectedBundle?.machO?.slices ?? []) { slice in
            VStack(alignment: .leading) {
                Label(slice.architecture, systemImage: "cpu")
                Text("\(slice.fileType) · \(countLabel(slice.linkedLibraries.count, singular: "linked library", plural: "linked libraries"))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .overlay {
            if model.selectedBundle?.machO?.slices.isEmpty != false {
                EmptyStateView(
                    title: "No Binary Information",
                    symbol: "cpu",
                    description: "IPALens could not locate or parse the selected app bundle’s executable."
                )
            }
        }
    }
}
