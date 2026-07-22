import AppKit
import Combine
import Foundation
import IPALensCore
import UniformTypeIdentifiers

enum SidebarSection: String, CaseIterable, Identifiable {
    case files = "Files"
    case overview = "Overview"
    case signing = "Signing"
    case entitlements = "Entitlements"
    case privacy = "Privacy"
    case frameworks = "Frameworks"
    case extensions = "Extensions"
    case binary = "Binary Information"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .files: "folder"
        case .overview: "app.badge"
        case .signing: "signature"
        case .entitlements: "key.horizontal"
        case .privacy: "hand.raised"
        case .frameworks: "shippingbox"
        case .extensions: "puzzlepiece.extension"
        case .binary: "cpu"
        }
    }
}

struct FileTreeNode: Identifiable, Hashable, Sendable {
    let entry: IPAEntry
    let children: [FileTreeNode]?
    var id: String { entry.path }
}

extension UTType {
    static let ipaPackage = UTType(filenameExtension: "ipa")
        ?? UTType(importedAs: "com.apple.itunes.ipa", conformingTo: .data)
}

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published var sourceURL: URL?
    @Published var snapshot: IPAPackageSnapshot?
    @Published var selectedSection: SidebarSection = .files
    @Published var selectedEntryPath: String? {
        didSet { schedulePreview() }
    }
    @Published var selectedBundlePath: String?
    @Published var preview: PreviewPayload?
    @Published var progress: InspectionProgress?
    @Published var isLoading = false
    @Published var isPreviewLoading = false
    @Published var previewLoadingMessage = "Preparing preview"
    @Published var isSearching = false
    @Published var isTreeLoading = false
    @Published private(set) var treeRoots: [FileTreeNode] = []
    @Published var isDropTargeted = false
    @Published var query = "" {
        didSet { scheduleSearch() }
    }
    @Published var searchContents = false {
        didSet { scheduleSearch() }
    }
    @Published var searchResults: [SearchResult] = []
    @Published var errorMessage: String?

    private let engine = IPAInspectionEngine()
    private var loadTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var entriesByPath: [String: IPAEntry] = [:]
    private var loadGeneration = UUID()
    private var previewGeneration = UUID()
    private var searchGeneration = UUID()
    private var hasSecurityScope = false
    nonisolated(unsafe) private var securityScopedURL: URL?

    deinit {
        loadTask?.cancel()
        previewTask?.cancel()
        searchTask?.cancel()
        securityScopedURL?.stopAccessingSecurityScopedResource()
    }

    var selectedEntry: IPAEntry? {
        guard let path = selectedEntryPath else { return nil }
        return entriesByPath[path]
    }

    var selectedBundle: AppBundleSummary? {
        guard let snapshot else { return nil }
        if let selectedBundlePath,
           let selected = snapshot.appBundles.first(where: { $0.bundlePath == selectedBundlePath }) {
            return selected
        }
        return snapshot.appBundles.first
    }

    var selectedSigning: SigningSummary? {
        guard let path = selectedBundle?.bundlePath else { return nil }
        return snapshot?.signing.first { $0.bundlePath == path }
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.ipaPackage]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an IPA package. IPALens inspects it locally without modifying the source file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url)
    }

    func open(url: URL) {
        guard url.pathExtension.lowercased() == "ipa" else {
            errorMessage = "IPALens opens files with the .ipa extension."
            return
        }
        loadTask?.cancel()
        previewTask?.cancel()
        searchTask?.cancel()
        if let previousURL = sourceURL {
            Task { await self.engine.forget(url: previousURL) }
        }
        releaseSecurityScope()

        sourceURL = url
        hasSecurityScope = url.startAccessingSecurityScopedResource()
        securityScopedURL = hasSecurityScope ? url : nil
        snapshot = nil
        entriesByPath = [:]
        treeRoots = []
        preview = nil
        selectedEntryPath = nil
        selectedBundlePath = nil
        selectedSection = .files
        query = ""
        let generation = UUID()
        loadGeneration = generation
        isLoading = true
        isPreviewLoading = false
        isSearching = false
        isTreeLoading = true
        progress = .init(phase: .indexing, completed: 0, total: 1, message: "Opening package")
        errorMessage = nil

        let inspectionEngine = engine
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let handler: IPAInspectionEngine.ProgressHandler = { [weak self] value in
                    Task { @MainActor in
                        guard self?.loadGeneration == generation else { return }
                        self?.progress = value
                    }
                }
                let indexed = try await inspectionEngine.index(url: url, progress: handler)
                guard !Task.isCancelled, loadGeneration == generation else { return }
                snapshot = indexed
                await buildTree(from: indexed.entries)
                guard !Task.isCancelled, loadGeneration == generation else { return }
                selectedEntryPath = indexed.entries.first(where: { $0.path == "Payload" })?.path ?? indexed.entries.first?.path

                let inspected = try await inspectionEngine.inspect(
                    url: url,
                    indexedSnapshot: indexed,
                    progress: handler
                )
                guard !Task.isCancelled, loadGeneration == generation else { return }
                snapshot = inspected
                entriesByPath = await Task.detached(priority: .userInitiated) {
                    Dictionary(uniqueKeysWithValues: inspected.entries.map { ($0.path, $0) })
                }.value
                selectedBundlePath = inspected.appBundles.first?.bundlePath
                isLoading = false
                progress = .init(phase: .complete, completed: 1, total: 1, message: "Inspection complete")
            } catch is CancellationError {
                guard loadGeneration == generation else { return }
                isLoading = false
                progress = nil
            } catch {
                guard loadGeneration == generation else { return }
                isLoading = false
                isTreeLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelLoading() {
        loadTask?.cancel()
        loadGeneration = UUID()
        isLoading = false
        isTreeLoading = false
        progress = nil
    }

    func exportReport() {
        guard let snapshot else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = snapshot.sourceFileName.replacingOccurrences(of: ".ipa", with: "") + "-inspection.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .json]
        panel.message = "Save this inspection as a readable Markdown report or versioned JSON data."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let report = InspectionReportV1(snapshot: snapshot)
            if url.pathExtension.lowercased() == "json" {
                try report.jsonData().write(to: url, options: .atomic)
            } else {
                try report.markdown().write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func exportSelectedEntry() {
        guard let sourceURL, let entry = selectedEntry, entry.kind == .file else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name
        panel.message = "Save an exact, hash-verified copy of this package file."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task {
            do {
                _ = try await engine.exportEntry(
                    url: sourceURL,
                    entryPath: entry.path,
                    destinationURL: destination
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func copySelectedPath() {
        guard let selectedEntryPath else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedEntryPath, forType: .string)
    }

    func selectInspectionPath(_ path: String) {
        selectedSection = .files
        selectedEntryPath = path
    }

    private func schedulePreview() {
        previewTask?.cancel()
        let generation = UUID()
        previewGeneration = generation
        preview = nil
        isPreviewLoading = false
        guard let sourceURL, let selectedEntryPath, let entry = entriesByPath[selectedEntryPath] else { return }
        isPreviewLoading = true
        previewLoadingMessage = entry.kind == .directory
            ? "Reading folder contents"
            : "Preparing \(ByteCountFormatter.string(fromByteCount: entry.uncompressedSize, countStyle: .file)) preview"
        previewTask = Task { [weak self] in
            guard let self else { return }
            do {
                let payload = try await engine.preview(url: sourceURL, entryPath: selectedEntryPath)
                guard !Task.isCancelled, previewGeneration == generation else { return }
                preview = payload
                isPreviewLoading = false
            } catch is CancellationError {
                guard previewGeneration == generation else { return }
                isPreviewLoading = false
                return
            } catch {
                guard previewGeneration == generation else { return }
                preview = .unavailable(error.localizedDescription)
                isPreviewLoading = false
            }
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let generation = UUID()
        searchGeneration = generation
        isSearching = false
        let query = query
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let sourceURL else {
            searchResults = []
            return
        }
        isSearching = true
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                let results = try await engine.search(
                    url: sourceURL,
                    query: query,
                    options: .init(includeContents: searchContents)
                )
                guard !Task.isCancelled, searchGeneration == generation else { return }
                searchResults = results
                isSearching = false
            } catch {
                guard self?.searchGeneration == generation else { return }
                self?.isSearching = false
                if !(error is CancellationError) { self?.errorMessage = error.localizedDescription }
            }
        }
    }

    private func buildTree(from entries: [IPAEntry]) async {
        isTreeLoading = true
        let structureTask = Task.detached(priority: .userInitiated) {
            let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
            func build(_ entry: IPAEntry) -> FileTreeNode {
                let children = entry.childPaths.compactMap { byPath[$0] }.map(build)
                return FileTreeNode(entry: entry, children: children.isEmpty ? nil : children)
            }
            return (byPath, entries.filter { $0.parentPath == nil }.map(build))
        }
        let (byPath, roots) = await withTaskCancellationHandler {
            await structureTask.value
        } onCancel: {
            structureTask.cancel()
        }
        guard !Task.isCancelled else { return }
        entriesByPath = byPath
        treeRoots = roots
        isTreeLoading = false
    }

    private func releaseSecurityScope() {
        if hasSecurityScope {
            sourceURL?.stopAccessingSecurityScopedResource()
        }
        hasSecurityScope = false
        securityScopedURL = nil
    }
}
