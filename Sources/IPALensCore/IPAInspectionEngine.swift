import CryptoKit
import Foundation
import UniformTypeIdentifiers

private func runBlocking<T: Sendable>(
    priority: TaskPriority = .userInitiated,
    _ operation: @escaping @Sendable () throws -> T
) async throws -> T {
    let task = Task.detached(priority: priority) {
        try operation()
    }
    return try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        task.cancel()
    }
}

public actor IPAInspectionEngine {
    public typealias ProgressHandler = @Sendable (InspectionProgress) -> Void

    private var indexes: [URL: ArchiveIndex] = [:]
    private var mediaPreviewFiles: [URL: [String: URL]] = [:]
    private let previewRoot: URL

    public init() {
        previewRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("IPALens", isDirectory: true)
            .appendingPathComponent("Media-\(UUID().uuidString)", isDirectory: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: previewRoot)
    }

    public func index(
        url: URL,
        progress: ProgressHandler? = nil,
        now: Date = Date()
    ) async throws -> IPAPackageSnapshot {
        progress?(.init(phase: .indexing, completed: 0, total: 1, message: "Reading package directory"))
        try Task.checkCancellation()
        let archiveIndex = try await runBlocking {
            try ArchiveIndexer.build(url: url)
        }
        indexes[cacheKey(url)] = archiveIndex
        let fileSize = try sourceFileSize(url)
        progress?(.init(phase: .indexing, completed: 1, total: 1, message: "Package index ready"))

        return IPAPackageSnapshot(
            sourceFileName: url.lastPathComponent,
            sourceFileSize: fileSize,
            packageSHA256: nil,
            generatedAt: now,
            entries: archiveIndex.entries,
            appBundles: [],
            signing: [],
            issues: [],
            isFullyInspected: false
        )
    }

    public func inspect(
        url: URL,
        indexedSnapshot: IPAPackageSnapshot? = nil,
        progress: ProgressHandler? = nil,
        now: Date = Date()
    ) async throws -> IPAPackageSnapshot {
        let key = cacheKey(url)
        let initialIndex: ArchiveIndex
        if let cached = indexes[key] {
            initialIndex = cached
        } else {
            _ = try await index(url: url, progress: progress, now: now)
            guard let cached = indexes[key] else { throw IPAInspectionError.unreadableArchive }
            initialIndex = cached
        }

        try Task.checkCancellation()
        progress?(.init(phase: .hashing, completed: 0, total: 1, message: "Calculating package fingerprint"))
        let (packageHash, hashedIndex) = try await runBlocking(priority: .utility) {
            let packageHash = try SHA256.hash(fileAt: url)
            let hashedIndex = try ArchiveIndexer.hashEntries(url: url, index: initialIndex, progress: progress)
            return (packageHash, hashedIndex)
        }
        indexes[key] = hashedIndex

        try Task.checkCancellation()
        progress?(.init(phase: .metadata, completed: 0, total: 1, message: "Reading application metadata"))
        let metadata = try await runBlocking(priority: .utility) {
            MetadataInspector.inspectBundles(url: url, index: hashedIndex)
        }
        var issues = metadata.issues
        let unhashedCount = hashedIndex.entries.filter { $0.kind == .file && $0.sha256 == nil }.count
        if unhashedCount > 0 {
            issues.append(.init(
                severity: .warning,
                category: "Archive integrity",
                message: "\(unhashedCount) \(unhashedCount == 1 ? "file could" : "files could") not be decompressed and hashed."
            ))
        }
        progress?(.init(phase: .metadata, completed: 1, total: 1, message: "Application metadata ready"))

        var signingResults: [SigningSummary] = []
        for (offset, bundle) in metadata.bundles.enumerated() {
            try Task.checkCancellation()
            progress?(.init(
                phase: .signing,
                completed: Int64(offset),
                total: Int64(metadata.bundles.count),
                message: "Inspecting code signature for \(bundle.displayName)"
            ))
            do {
                let provisioning = metadata.provisioningByBundlePath[bundle.bundlePath]
                let summary = try await runBlocking(priority: .utility) {
                    try BundleMaterializer.withMaterializedBundle(
                        archiveURL: url,
                        index: hashedIndex,
                        bundlePath: bundle.bundlePath
                    ) { bundleURL in
                        CodeSigningInspector.inspect(
                            bundleURL: bundleURL,
                            bundlePath: bundle.bundlePath,
                            provisioning: provisioning
                        )
                    }
                }
                signingResults.append(summary)
            } catch {
                signingResults.append(SigningSummary(
                    bundlePath: bundle.bundlePath,
                    status: .unknown,
                    provisioning: metadata.provisioningByBundlePath[bundle.bundlePath],
                    detail: error.localizedDescription
                ))
                issues.append(.init(
                    severity: .warning,
                    category: "Code signing",
                    path: bundle.bundlePath,
                    message: error.localizedDescription
                ))
            }
        }
        progress?(.init(
            phase: .signing,
            completed: Int64(metadata.bundles.count),
            total: Int64(metadata.bundles.count),
            message: "Code-signing inspection complete"
        ))

        let inspectedSourceSize = try indexedSnapshot?.sourceFileSize ?? sourceFileSize(url)
        let snapshot = IPAPackageSnapshot(
            sourceFileName: indexedSnapshot?.sourceFileName ?? url.lastPathComponent,
            sourceFileSize: inspectedSourceSize,
            packageSHA256: packageHash,
            generatedAt: now,
            entries: hashedIndex.entries,
            appBundles: metadata.bundles,
            signing: signingResults,
            issues: issues,
            isFullyInspected: true
        )
        progress?(.init(phase: .complete, completed: 1, total: 1, message: "Inspection complete"))
        return snapshot
    }

    public func preview(
        url: URL,
        entryPath: String,
        hexOffset: Int64 = 0
    ) async throws -> PreviewPayload {
        let index = try cachedOrBuildIndex(url)
        guard let entry = index.entryByPath[entryPath] else {
            throw IPAInspectionError.entryNotFound(entryPath)
        }
        try Task.checkCancellation()

        if entry.kind == .directory {
            let descendants = index.entries.filter { $0.path.hasPrefix(entry.path + "/") }
            return .directory(.init(
                path: entry.path,
                childCount: entry.childPaths.count,
                totalUncompressedSize: descendants.reduce(0) { $0 + $1.uncompressedSize }
            ))
        }
        if entry.kind == .symbolicLink {
            return .unavailable("Symbolic links are displayed but never followed or materialized.")
        }

        let lowercasedName = entry.name.lowercased()
        if let typeIdentifier = videoTypeIdentifier(name: lowercasedName) {
            let fileURL = try await materializeMediaEntry(
                archiveURL: url,
                index: index,
                entry: entry,
                entryPath: entryPath
            )
            return .video(.init(
                fileURL: fileURL,
                originalFileName: entry.name,
                fileSize: entry.uncompressedSize,
                typeIdentifier: typeIdentifier
            ))
        }

        if let typeIdentifier = audioTypeIdentifier(name: lowercasedName) {
            let fileURL = try await materializeMediaEntry(
                archiveURL: url,
                index: index,
                entry: entry,
                entryPath: entryPath
            )
            return .audio(.init(
                fileURL: fileURL,
                originalFileName: entry.name,
                fileSize: entry.uncompressedSize,
                typeIdentifier: typeIdentifier
            ))
        }

        if lowercasedName == "embedded.mobileprovision" {
            return try await runBlocking {
                let data = try ArchiveIndexer.readEntry(url: url, index: index, path: entryPath).data
                return .provisioning(try ProvisioningProfileParser.parse(data: data))
            }
        }

        if isPropertyList(name: lowercasedName) {
            guard entry.uncompressedSize <= 64 * 1_024 * 1_024 else {
                return .unavailable("The property list exceeds the 64 MiB structured-preview limit.")
            }
            return try await runBlocking {
                let data = try ArchiveIndexer.readEntry(
                    url: url,
                    index: index,
                    path: entryPath,
                    maximumBytes: entry.uncompressedSize
                ).data
                return .plist(PlistValue(any: try PropertyListParser.object(data: data)))
            }
        }

        if isImage(name: lowercasedName) {
            guard entry.uncompressedSize <= 100 * 1_024 * 1_024 else {
                return .unavailable("The image exceeds the 100 MiB preview limit.")
            }
            let typeIdentifier = imageTypeIdentifier(name: lowercasedName)
            return try await runBlocking {
                let data = try ArchiveIndexer.readEntry(url: url, index: index, path: entryPath).data
                return .image(.init(data: data, typeIdentifier: typeIdentifier))
            }
        }

        if entry.uncompressedSize <= 512 * 1_024 * 1_024 {
            let header = try await runBlocking {
                try ArchiveIndexer.readEntry(
                    url: url,
                    index: index,
                    path: entryPath,
                    maximumBytes: min(entry.uncompressedSize, 4 * 1_024 * 1_024)
                ).data
            }
            if MachOParser.looksLikeMachO(header) {
                return try await runBlocking {
                    let fullData = try ArchiveIndexer.readEntry(url: url, index: index, path: entryPath).data
                    return .machO(try MachOParser.parse(data: fullData))
                }
            }
        }

        if isText(name: lowercasedName) {
            let syntax = syntaxName(name: lowercasedName)
            return try await runBlocking {
                let result = try ArchiveIndexer.readEntry(
                    url: url,
                    index: index,
                    path: entryPath,
                    maximumBytes: ArchiveSafetyLimits.maximumPreviewBytes
                )
                let text = String(decoding: result.data, as: UTF8.self)
                return .text(.init(text: text, syntax: syntax, isTruncated: result.truncated))
            }
        }

        return try await runBlocking {
            try Self.hexPreview(url: url, index: index, entry: entry, offset: hexOffset)
        }
    }

    public func search(
        url: URL,
        query: String,
        options: SearchOptions = .init()
    ) async throws -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let needle = trimmed.lowercased()
        let index = try cachedOrBuildIndex(url)
        var results: [SearchResult] = []

        for entry in index.entries {
            try Task.checkCancellation()
            if entry.path.lowercased().contains(needle) {
                results.append(.init(path: entry.path, matchKind: "Filename", snippet: nil))
            }
            guard options.includeContents,
                  entry.kind == .file,
                  entry.uncompressedSize <= options.maximumContentBytes,
                  isSearchableText(name: entry.name.lowercased()) else {
                if results.count >= 1_000 { break }
                continue
            }
            do {
                let data = try ArchiveIndexer.readEntry(
                    url: url,
                    index: index,
                    path: entry.path,
                    maximumBytes: options.maximumContentBytes
                ).data
                let text: String
                if isPropertyList(name: entry.name.lowercased()),
                   let object = try? PropertyListParser.object(data: data),
                   PropertyListSerialization.propertyList(object, isValidFor: .xml),
                   let xml = try? PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0) {
                    text = String(decoding: xml, as: UTF8.self)
                } else {
                    text = String(decoding: data, as: UTF8.self)
                }
                if let range = text.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) {
                    let snippet = makeSnippet(text: text, around: range)
                    results.append(.init(path: entry.path, matchKind: "Content", snippet: snippet))
                }
            } catch {
                // Corrupt individual files remain searchable by filename.
            }
            if results.count >= 1_000 { break }
        }
        return results
    }

    @discardableResult
    public func exportEntry(
        url: URL,
        entryPath: String,
        destinationURL: URL
    ) async throws -> String {
        let index = try cachedOrBuildIndex(url)
        let expectedHash = index.entryByPath[entryPath]?.sha256
        return try ArchiveIndexer.exportEntry(
            url: url,
            index: index,
            path: entryPath,
            destinationURL: destinationURL,
            expectedSHA256: expectedHash
        )
    }

    public func forget(url: URL) {
        let key = cacheKey(url)
        indexes.removeValue(forKey: key)
        if let previews = mediaPreviewFiles.removeValue(forKey: key) {
            for previewURL in previews.values {
                try? FileManager.default.removeItem(at: previewURL)
            }
        }
    }

    private func cachedOrBuildIndex(_ url: URL) throws -> ArchiveIndex {
        let key = cacheKey(url)
        if let cached = indexes[key] { return cached }
        let built = try ArchiveIndexer.build(url: url)
        indexes[key] = built
        return built
    }

    private func cacheKey(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func sourceFileSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    private func materializeMediaEntry(
        archiveURL: URL,
        index: ArchiveIndex,
        entry: IPAEntry,
        entryPath: String
    ) async throws -> URL {
        let sourceKey = cacheKey(archiveURL)
        if let cached = mediaPreviewFiles[sourceKey]?[entryPath],
           FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }

        let fileExtension = (entry.name as NSString).pathExtension
        let safeSuffix = fileExtension.count <= 16 && !fileExtension.isEmpty ? ".\(fileExtension)" : ""
        let destination = previewRoot.appendingPathComponent(UUID().uuidString + safeSuffix)
        _ = try await runBlocking {
            try ArchiveIndexer.materializeEntry(
                url: archiveURL,
                index: index,
                path: entryPath,
                destinationURL: destination
            )
        }
        mediaPreviewFiles[sourceKey, default: [:]][entryPath] = destination
        return destination
    }

    private nonisolated static func hexPreview(
        url: URL,
        index: ArchiveIndex,
        entry: IPAEntry,
        offset: Int64
    ) throws -> PreviewPayload {
        guard offset >= 0, offset < max(1, entry.uncompressedSize) else {
            return .unavailable("The requested hex page is outside the file.")
        }
        let result = try ArchiveIndexer.readEntry(
            url: url,
            index: index,
            path: entry.path,
            maximumBytes: min(entry.uncompressedSize, offset + Int64(ArchiveSafetyLimits.hexPageBytes))
        ).data
        let start = min(result.count, Int(offset))
        let end = min(result.count, start + ArchiveSafetyLimits.hexPageBytes)
        return .hex(.init(offset: offset, totalSize: entry.uncompressedSize, data: Data(result[start..<end])))
    }

    private func makeSnippet(text: String, around range: Range<String.Index>) -> String {
        let lower = text.index(range.lowerBound, offsetBy: -80, limitedBy: text.startIndex) ?? text.startIndex
        let upper = text.index(range.upperBound, offsetBy: 120, limitedBy: text.endIndex) ?? text.endIndex
        return String(text[lower..<upper]).replacingOccurrences(of: "\n", with: " ")
    }

    private func isPropertyList(name: String) -> Bool {
        name.hasSuffix(".plist") || name.hasSuffix(".xcprivacy") || name.hasSuffix(".strings")
    }

    private func isImage(name: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "tiff", "tif", "heic", "webp", "icns"]
            .contains((name as NSString).pathExtension)
    }

    private func audioTypeIdentifier(name: String) -> String? {
        let fileExtension = (name as NSString).pathExtension.lowercased()
        guard !fileExtension.isEmpty else { return nil }
        if let type = UTType(filenameExtension: fileExtension), type.conforms(to: .audio) {
            return type.identifier
        }
        let additionalAudioExtensions: Set<String> = [
            "aac", "ac3", "aif", "aifc", "aiff", "alac", "amr", "au", "caf", "eac3",
            "flac", "m4a", "m4b", "mka", "mp2", "mp3", "oga", "ogg", "opus", "snd",
            "wav", "wave", "weba", "wma"
        ]
        return additionalAudioExtensions.contains(fileExtension)
            ? UTType(filenameExtension: fileExtension)?.identifier ?? "public.audio"
            : nil
    }

    private func videoTypeIdentifier(name: String) -> String? {
        let fileExtension = (name as NSString).pathExtension.lowercased()
        guard !fileExtension.isEmpty else { return nil }
        if let type = UTType(filenameExtension: fileExtension),
           type.conforms(to: .movie) || type.conforms(to: .video) {
            return type.identifier
        }
        let additionalVideoExtensions: Set<String> = [
            "3g2", "3gp", "avi", "m2ts", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg",
            "mts", "ogv", "ts", "webm", "wmv"
        ]
        return additionalVideoExtensions.contains(fileExtension)
            ? UTType(filenameExtension: fileExtension)?.identifier ?? "public.movie"
            : nil
    }

    private func imageTypeIdentifier(name: String) -> String? {
        switch (name as NSString).pathExtension {
        case "png": "public.png"
        case "jpg", "jpeg": "public.jpeg"
        case "gif": "com.compuserve.gif"
        case "tiff", "tif": "public.tiff"
        case "heic": "public.heic"
        case "webp": "org.webmproject.webp"
        case "icns": "com.apple.icns"
        default: nil
        }
    }

    private func isText(name: String) -> Bool {
        let extensions = [
            "txt", "json", "xml", "html", "htm", "css", "js", "mjs", "ts", "tsx",
            "swift", "m", "mm", "h", "hpp", "c", "cpp", "md", "yaml", "yml", "csv",
            "stringsdict", "storyboard", "xib", "entitlements", "conf", "ini", "log", "sql"
        ]
        return extensions.contains((name as NSString).pathExtension)
    }

    private func isSearchableText(name: String) -> Bool {
        isText(name: name) || isPropertyList(name: name)
    }

    private func syntaxName(name: String) -> String {
        switch (name as NSString).pathExtension {
        case "json": "JSON"
        case "xml", "storyboard", "xib": "XML"
        case "html", "htm": "HTML (source)"
        case "css": "CSS"
        case "js", "mjs": "JavaScript"
        case "ts", "tsx": "TypeScript"
        case "swift": "Swift"
        case "md": "Markdown"
        case "yaml", "yml": "YAML"
        default: "Plain text"
        }
    }
}
