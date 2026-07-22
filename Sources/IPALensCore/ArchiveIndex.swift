import CryptoKit
import Foundation
import ZIPFoundation

public enum ArchiveSafetyLimits {
    public static let maximumEntryCount = 200_000
    public static let maximumUncompressedSize: Int64 = 20 * 1_024 * 1_024 * 1_024
    public static let maximumPreviewBytes: Int64 = 5 * 1_024 * 1_024
    public static let hexPageBytes = 64 * 1_024
    public static let minimumFreeSpaceReserve: Int64 = 1 * 1_024 * 1_024 * 1_024
}

public enum ArchivePathValidator {
    public static func normalize(_ rawPath: String) throws -> String {
        guard !rawPath.isEmpty,
              !rawPath.hasPrefix("/"),
              !rawPath.hasPrefix("~"),
              !rawPath.contains("\0"),
              !rawPath.contains("\\") else {
            throw IPAInspectionError.unsafePath(rawPath)
        }

        var path = rawPath
        while path.hasSuffix("/") {
            path.removeLast()
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw IPAInspectionError.unsafePath(rawPath)
        }

        return components
            .map { String($0).precomposedStringWithCanonicalMapping }
            .joined(separator: "/")
    }

    public static func collisionKey(for normalizedPath: String) -> String {
        normalizedPath.precomposedStringWithCanonicalMapping.lowercased()
    }

    public static func parentPath(of path: String) -> String? {
        guard let slash = path.lastIndex(of: "/") else { return nil }
        return String(path[..<slash])
    }
}

struct ArchiveIndex: Sendable {
    let entries: [PackageEntry]
    let archivePaths: [String: String]
    let archiveURL: URL?
    let physicalPaths: [String: URL]
    let totalUncompressedSize: Int64
    let entryByPath: [String: PackageEntry]

    init(
        entries: [PackageEntry],
        archivePaths: [String: String] = [:],
        archiveURL: URL? = nil,
        physicalPaths: [String: URL] = [:],
        totalUncompressedSize: Int64
    ) {
        self.entries = entries
        self.archivePaths = archivePaths
        self.archiveURL = archiveURL
        self.physicalPaths = physicalPaths
        self.totalUncompressedSize = totalUncompressedSize
        entryByPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
    }

    func replacingHashes(_ hashes: [String: String]) -> ArchiveIndex {
        let updated = entries.map { entry in
            PackageEntry(
                path: entry.path,
                name: entry.name,
                parentPath: entry.parentPath,
                kind: entry.kind,
                compressedSize: entry.compressedSize,
                uncompressedSize: entry.uncompressedSize,
                compressionMethod: entry.compressionMethod,
                sha256: hashes[entry.path] ?? entry.sha256,
                childPaths: entry.childPaths,
                isSyntheticDirectory: entry.isSyntheticDirectory
            )
        }
        return ArchiveIndex(
            entries: updated,
            archivePaths: archivePaths,
            archiveURL: archiveURL,
            physicalPaths: physicalPaths,
            totalUncompressedSize: totalUncompressedSize
        )
    }
}

enum ArchiveIndexer {
    private struct MutableRecord {
        var path: String
        var kind: IPAEntryKind
        var compressedSize: Int64
        var uncompressedSize: Int64
        var compressionMethod: String
        var archivePath: String?
        var isSynthetic: Bool
    }

    static func build(url: URL) throws -> ArchiveIndex {
        let archive = try Archive(url: url, accessMode: .read)

        var records: [String: MutableRecord] = [:]
        var collisionPaths: [String: String] = [:]
        var archivePaths: [String: String] = [:]
        var actualEntryCount = 0
        var totalUncompressedSize: Int64 = 0

        for archiveEntry in archive {
            try Task.checkCancellation()
            actualEntryCount += 1
            guard actualEntryCount <= ArchiveSafetyLimits.maximumEntryCount else {
                throw IPAInspectionError.entryLimitExceeded(actualEntryCount)
            }

            let normalized = try ArchivePathValidator.normalize(archiveEntry.path)
            let collisionKey = ArchivePathValidator.collisionKey(for: normalized)
            if let existingPath = collisionPaths[collisionKey] {
                let existing = records[existingPath]
                let incomingIsDirectory = archiveEntry.type == .directory
                if existing?.isSynthetic == true && incomingIsDirectory {
                    // Replace the implicit directory with the explicit archive record.
                } else {
                    throw IPAInspectionError.duplicatePath(normalized)
                }
            }

            let kind: IPAEntryKind
            switch archiveEntry.type {
            case .file: kind = .file
            case .directory: kind = .directory
            case .symlink: kind = .symbolicLink
            @unknown default: kind = .file
            }

            let uncompressedSize = Int64(archiveEntry.uncompressedSize)
            totalUncompressedSize = try checkedAdd(totalUncompressedSize, uncompressedSize)
            guard totalUncompressedSize <= ArchiveSafetyLimits.maximumUncompressedSize else {
                throw IPAInspectionError.sizeLimitExceeded(totalUncompressedSize)
            }

            records[normalized] = MutableRecord(
                path: normalized,
                kind: kind,
                compressedSize: Int64(archiveEntry.compressedSize),
                uncompressedSize: uncompressedSize,
                compressionMethod: archiveEntry.compressedSize == archiveEntry.uncompressedSize ? "none" : "deflate-or-other",
                archivePath: archiveEntry.path,
                isSynthetic: false
            )
            collisionPaths[collisionKey] = normalized
            archivePaths[normalized] = archiveEntry.path

            var parent = ArchivePathValidator.parentPath(of: normalized)
            while let parentPath = parent {
                let parentKey = ArchivePathValidator.collisionKey(for: parentPath)
                if let existingPath = collisionPaths[parentKey] {
                    guard records[existingPath]?.kind == .directory else {
                        throw IPAInspectionError.duplicatePath(parentPath)
                    }
                } else {
                    records[parentPath] = MutableRecord(
                        path: parentPath,
                        kind: .directory,
                        compressedSize: 0,
                        uncompressedSize: 0,
                        compressionMethod: "none",
                        archivePath: nil,
                        isSynthetic: true
                    )
                    collisionPaths[parentKey] = parentPath
                }
                parent = ArchivePathValidator.parentPath(of: parentPath)
            }
        }

        var children: [String: [String]] = [:]
        for path in records.keys {
            if let parent = ArchivePathValidator.parentPath(of: path) {
                children[parent, default: []].append(path)
            }
        }

        let entries = records.values.map { record in
            PackageEntry(
                path: record.path,
                name: record.path.split(separator: "/").last.map(String.init) ?? record.path,
                parentPath: ArchivePathValidator.parentPath(of: record.path),
                kind: record.kind,
                compressedSize: record.compressedSize,
                uncompressedSize: record.uncompressedSize,
                compressionMethod: record.compressionMethod,
                sha256: nil,
                childPaths: (children[record.path] ?? []).sorted(),
                isSyntheticDirectory: record.isSynthetic
            )
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        return ArchiveIndex(
            entries: entries,
            archivePaths: archivePaths,
            archiveURL: url,
            totalUncompressedSize: totalUncompressedSize
        )
    }

    static func hashEntries(
        url: URL,
        index: ArchiveIndex,
        progress: (@Sendable (InspectionProgress) -> Void)?
    ) throws -> ArchiveIndex {
        let archive = try index.archiveURL.map { try Archive(url: $0, accessMode: .read) }

        let files = index.entries.filter { $0.kind == .file }
        let progressStride = max(1, files.count / 500)
        var hashes: [String: String] = [:]
        for (offset, entry) in files.enumerated() {
            try Task.checkCancellation()
            do {
                if let archive,
                   let archivePath = index.archivePaths[entry.path],
                   let archiveEntry = archive[archivePath] {
                    var hasher = SHA256()
                    _ = try archive.extract(archiveEntry, bufferSize: 64 * 1_024) { chunk in
                        try Task.checkCancellation()
                        hasher.update(data: chunk)
                    }
                    hashes[entry.path] = hasher.finalize().hexString
                } else if let physicalURL = index.physicalPaths[entry.path] {
                    hashes[entry.path] = try SHA256.hash(fileAt: physicalURL)
                }
            } catch {
                // A corrupt individual entry is reported by the inspection layer.
            }
            if offset == 0 || offset + 1 == files.count || (offset + 1).isMultiple(of: progressStride) {
                progress?(.init(
                    phase: .hashing,
                    completed: Int64(offset + 1),
                    total: Int64(files.count),
                    message: "Calculating hashes: \(entry.name)"
                ))
            }
        }
        return index.replacingHashes(hashes)
    }

    static func readEntry(
        url: URL,
        index: ArchiveIndex,
        path: String,
        maximumBytes: Int64? = nil
    ) throws -> (data: Data, truncated: Bool) {
        if let physicalURL = index.physicalPaths[path] {
            guard index.entryByPath[path]?.kind == .file else {
                throw IPAInspectionError.entryNotFound(path)
            }
            let handle = try FileHandle(forReadingFrom: physicalURL)
            defer { try? handle.close() }
            let limit = maximumBytes.map { max(0, $0) }
            var data = Data()
            var truncated = false
            while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                try Task.checkCancellation()
                if let limit {
                    let remaining = max(0, Int(limit) - data.count)
                    if remaining > 0 { data.append(chunk.prefix(remaining)) }
                    if chunk.count > remaining || Int64(data.count) >= limit && index.entryByPath[path]!.uncompressedSize > limit {
                        truncated = true
                        break
                    }
                } else {
                    data.append(chunk)
                }
            }
            return (data, truncated)
        }
        guard let archivePath = index.archivePaths[path] else {
            throw IPAInspectionError.entryNotFound(path)
        }
        let archive = try Archive(url: index.archiveURL ?? url, accessMode: .read)
        guard let entry = archive[archivePath] else { throw IPAInspectionError.entryNotFound(path) }
        guard entry.type == .file else {
            throw IPAInspectionError.entryNotFound(path)
        }

        let limit = maximumBytes.map { max(0, $0) }
        var data = Data()
        var truncated = false
        do {
            _ = try archive.extract(entry, bufferSize: 64 * 1_024, skipCRC32: limit != nil) { chunk in
                try Task.checkCancellation()
                if let limit {
                    let remaining = max(0, Int(limit) - data.count)
                    if remaining > 0 {
                        data.append(chunk.prefix(remaining))
                    }
                    if chunk.count > remaining || Int64(data.count) >= limit && entry.uncompressedSize > limit {
                        truncated = true
                    }
                } else {
                    data.append(chunk)
                }
            }
        } catch {
            throw IPAInspectionError.extractionFailed(error.localizedDescription)
        }
        return (data, truncated)
    }

    @discardableResult
    static func materializeEntry(
        url: URL,
        index: ArchiveIndex,
        path: String,
        destinationURL: URL
    ) throws -> String {
        guard let indexedEntry = index.entryByPath[path],
              indexedEntry.kind == .file else {
            throw IPAInspectionError.entryNotFound(path)
        }

        let available = try FileManager.default.temporaryDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage ?? Int64.max
        let required = indexedEntry.uncompressedSize + ArchiveSafetyLimits.minimumFreeSpaceReserve
        guard available >= required else {
            throw IPAInspectionError.insufficientDiskSpace(required: required, available: available)
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        guard fileManager.createFile(atPath: destinationURL.path, contents: nil) else {
            throw IPAInspectionError.extractionFailed("The temporary preview file could not be created.")
        }

        let handle = try FileHandle(forWritingTo: destinationURL)
        var hasher = SHA256()
        do {
            if let physicalURL = index.physicalPaths[path] {
                let source = try FileHandle(forReadingFrom: physicalURL)
                defer { try? source.close() }
                while let chunk = try source.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                    try Task.checkCancellation()
                    try handle.write(contentsOf: chunk)
                    hasher.update(data: chunk)
                }
            } else {
                guard let archivePath = index.archivePaths[path] else {
                    throw IPAInspectionError.entryNotFound(path)
                }
                let archive = try Archive(url: index.archiveURL ?? url, accessMode: .read)
                guard let archiveEntry = archive[archivePath], archiveEntry.type == .file else {
                    throw IPAInspectionError.entryNotFound(path)
                }
                _ = try archive.extract(archiveEntry, bufferSize: 64 * 1_024) { chunk in
                    try Task.checkCancellation()
                    try handle.write(contentsOf: chunk)
                    hasher.update(data: chunk)
                }
            }
            try handle.close()
        } catch is CancellationError {
            try? handle.close()
            try? fileManager.removeItem(at: destinationURL)
            throw CancellationError()
        } catch {
            try? handle.close()
            try? fileManager.removeItem(at: destinationURL)
            throw IPAInspectionError.extractionFailed(error.localizedDescription)
        }

        let actualHash = hasher.finalize().hexString
        if let expectedHash = indexedEntry.sha256, expectedHash != actualHash {
            try? fileManager.removeItem(at: destinationURL)
            throw IPAInspectionError.extractionFailed("The preview file did not match its inspection hash.")
        }
        return actualHash
    }

    static func exportEntry(
        url: URL,
        index: ArchiveIndex,
        path: String,
        destinationURL: URL,
        expectedSHA256: String?
    ) throws -> String {
        guard index.entryByPath[path]?.kind == .file else {
            throw IPAInspectionError.entryNotFound(path)
        }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        _ = try materializeEntry(url: url, index: index, path: path, destinationURL: destinationURL)

        let actualHash = try SHA256.hash(fileAt: destinationURL)
        if let expectedSHA256, expectedSHA256 != actualHash {
            try? fileManager.removeItem(at: destinationURL)
            throw IPAInspectionError.extractionFailed("The exported file did not match its inspection hash.")
        }
        return actualHash
    }

    private static func checkedAdd(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        if overflow {
            throw IPAInspectionError.sizeLimitExceeded(.max)
        }
        return result
    }
}

enum DirectoryIndexer {
    private struct Record {
        let path: String
        let kind: IPAEntryKind
        let size: Int64
        let physicalURL: URL
    }

    static func build(roots: [(logicalName: String, url: URL)]) throws -> ArchiveIndex {
        var records: [String: Record] = [:]
        var collisions = Set<String>()
        var totalSize: Int64 = 0
        var entryCount = 0

        func visit(url: URL, logicalPath rawPath: String) throws {
            try Task.checkCancellation()
            let path = try ArchivePathValidator.normalize(rawPath)
            let collision = ArchivePathValidator.collisionKey(for: path)
            guard collisions.insert(collision).inserted else {
                throw IPAInspectionError.duplicatePath(path)
            }
            entryCount += 1
            guard entryCount <= ArchiveSafetyLimits.maximumEntryCount else {
                throw IPAInspectionError.entryLimitExceeded(entryCount)
            }

            let values = try url.resourceValues(forKeys: [
                .isSymbolicLinkKey,
                .isDirectoryKey,
                .isRegularFileKey,
                .fileSizeKey
            ])
            let kind: IPAEntryKind
            let size: Int64
            if values.isSymbolicLink == true {
                kind = .symbolicLink
                size = 0
            } else if values.isDirectory == true {
                kind = .directory
                size = 0
            } else if values.isRegularFile == true {
                kind = .file
                size = Int64(values.fileSize ?? 0)
                let (next, overflow) = totalSize.addingReportingOverflow(size)
                guard !overflow, next <= ArchiveSafetyLimits.maximumUncompressedSize else {
                    throw IPAInspectionError.sizeLimitExceeded(overflow ? .max : next)
                }
                totalSize = next
            } else {
                kind = .file
                size = Int64(values.fileSize ?? 0)
            }
            records[path] = Record(path: path, kind: kind, size: size, physicalURL: url)

            if kind == .directory {
                let children = try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey],
                    options: []
                ).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                for child in children {
                    try visit(url: child, logicalPath: path + "/" + child.lastPathComponent)
                }
            }
        }

        for root in roots {
            try visit(url: root.url, logicalPath: root.logicalName)
        }

        var children: [String: [String]] = [:]
        for path in records.keys {
            if let parent = ArchivePathValidator.parentPath(of: path) {
                children[parent, default: []].append(path)
            }
        }
        let entries = records.values.map { record in
            PackageEntry(
                path: record.path,
                name: record.path.split(separator: "/").last.map(String.init) ?? record.path,
                parentPath: ArchivePathValidator.parentPath(of: record.path),
                kind: record.kind,
                compressedSize: record.size,
                uncompressedSize: record.size,
                compressionMethod: "none",
                sha256: nil,
                childPaths: (children[record.path] ?? []).sorted(),
                isSyntheticDirectory: false
            )
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return ArchiveIndex(
            entries: entries,
            physicalPaths: Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0.value.physicalURL) }),
            totalUncompressedSize: totalSize
        )
    }
}

extension SHA256.Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

extension SHA256 {
    static func hash(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data)
        }
        return hasher.finalize().hexString
    }
}
