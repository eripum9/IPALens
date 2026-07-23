import CryptoKit
import Foundation
import ZIPFoundation

public actor PluginManager {
    public static let hostAPIVersion = 1
    public static let macOSPluginID = "com.eripum9.ipalens.platform.macos"
    public static let officialCatalogURL = URL(
        string: "https://raw.githubusercontent.com/eripum9/IPALens-Plugins/main/catalog-v1.json"
    )!

    public static let officialPublicKeyBase64 = "XdlWIVyBKi0AnwPT27V6Hl540gdJpmNJtoPW1XItu1M="

    public static let shared = PluginManager()

    private static let maximumCatalogBytes = 1 * 1_024 * 1_024
    private static let maximumPluginBytes = 50 * 1_024 * 1_024
    private static let maximumPluginResourceBytes = 10 * 1_024 * 1_024
    private static let maximumManifestBytes = 1 * 1_024 * 1_024
    private static let maximumPluginEntries = 1_000

    private let storageRoot: URL
    private let sourcesFile: URL
    private let session: URLSession
    private var inUsePluginIDs: Set<String> = []

    public init(storageRoot: URL? = nil, session: URLSession? = nil) {
        let root = storageRoot ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("IPALens/Plugins", isDirectory: true)
        self.storageRoot = root
        sourcesFile = root.appendingPathComponent("Sources.json")
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 30
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration, delegate: HTTPSRedirectDelegate(), delegateQueue: nil)
        }
    }

    public func officialSource() throws -> PluginSource {
        return PluginSource(
            name: "IPALens Official Plugins",
            catalogURL: Self.officialCatalogURL,
            trust: .official,
            publicKey: Self.officialPublicKeyBase64
        )
    }

    public func sources() throws -> [PluginSource] {
        var values: [PluginSource] = []
        if let official = try? officialSource() { values.append(official) }
        guard FileManager.default.fileExists(atPath: sourcesFile.path) else { return values }
        let data = try Data(contentsOf: sourcesFile)
        values.append(contentsOf: try JSONDecoder().decode([PluginSource].self, from: data))
        return values
    }

    public func inspectThirdPartySource(url: URL) async throws -> PluginSourceCandidate {
        try Self.validateRemoteURL(url)
        let data = try await download(url: url, maximumBytes: Self.maximumCatalogBytes)
        let envelope = try JSONDecoder().decode(PluginCatalogEnvelopeV1.self, from: data)
        guard let publicKey = envelope.publisherPublicKey else { throw PluginError.invalidEnvelope }
        let payload = try Self.verifyEnvelope(envelope, publicKey: publicKey)
        return PluginSourceCandidate(
            name: payload.publisher,
            catalogURL: url,
            publicKey: publicKey,
            keyFingerprint: PluginSource.fingerprint(forBase64Key: publicKey),
            payload: payload
        )
    }

    public func trustThirdPartySource(_ candidate: PluginSourceCandidate) throws -> PluginSource {
        let source = PluginSource(
            name: candidate.name,
            catalogURL: candidate.catalogURL,
            trust: .thirdParty,
            publicKey: candidate.publicKey,
            keyFingerprint: candidate.keyFingerprint
        )
        var custom = try sources().filter { $0.trust == .thirdParty }
        if let existing = custom.first(where: { $0.catalogURL == source.catalogURL }),
           existing.publicKey != source.publicKey {
            throw PluginError.untrustedPublisher
        }
        custom.removeAll { $0.catalogURL == source.catalogURL }
        custom.append(source)
        try persistSources(custom)
        return source
    }

    public func removeSource(id: UUID) throws {
        let custom = try sources().filter { $0.trust == .thirdParty && $0.id != id }
        try persistSources(custom)
    }

    public func fetchCatalog(from source: PluginSource) async throws -> PluginCatalog {
        try Self.validateRemoteURL(source.catalogURL)
        let data = try await download(url: source.catalogURL, maximumBytes: Self.maximumCatalogBytes)
        let envelope = try JSONDecoder().decode(PluginCatalogEnvelopeV1.self, from: data)
        if let advertisedKey = envelope.publisherPublicKey, advertisedKey != source.publicKey {
            throw PluginError.untrustedPublisher
        }
        let payload = try Self.verifyEnvelope(envelope, publicKey: source.publicKey)
        for entry in payload.plugins {
            guard entry.hostAPIVersion == Self.hostAPIVersion else {
                throw PluginError.incompatibleHostAPI(entry.hostAPIVersion)
            }
            try Self.validateRemoteURL(entry.artifactURL)
        }
        return PluginCatalog(source: source, payload: payload)
    }

    public func availablePlugins() async throws -> [(PluginCatalogEntry, PluginSource)] {
        var result: [(PluginCatalogEntry, PluginSource)] = []
        for source in try sources() {
            do {
                let catalog = try await fetchCatalog(from: source)
                result.append(contentsOf: catalog.payload.plugins.map { ($0, source) })
            } catch where source.trust != .official {
                continue
            }
        }
        return result
    }

    public func installedPlugins() throws -> [PluginInstallation] {
        guard FileManager.default.fileExists(atPath: storageRoot.path) else { return [] }
        let pluginDirectories = try FileManager.default.contentsOfDirectory(
            at: storageRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return pluginDirectories.compactMap { pluginRoot in
            guard pluginRoot.lastPathComponent != sourcesFile.lastPathComponent else { return nil }
            let currentURL = pluginRoot.appendingPathComponent("Current.json")
            guard let currentData = try? Data(contentsOf: currentURL),
                  let current = try? JSONDecoder.ipalens.decode(CurrentInstallation.self, from: currentData) else { return nil }
            let installationURL = pluginRoot.appendingPathComponent(current.version, isDirectory: true)
            let manifestURL = installationURL.appendingPathComponent("Plugin.json")
            guard let manifestData = try? Data(contentsOf: manifestURL),
                  let manifest = try? Self.decodeManifest(manifestData) else { return nil }
            return PluginInstallation(
                manifest: manifest,
                trust: current.trust,
                sourceName: current.sourceName,
                installedAt: current.installedAt,
                installationURL: installationURL
            )
        }.sorted { $0.manifest.name.localizedStandardCompare($1.manifest.name) == .orderedAscending }
    }

    public func installedPlugin(id: String) throws -> PluginInstallation? {
        try installedPlugins().first { $0.manifest.id == id }
    }

    public func install(entry: PluginCatalogEntry, from source: PluginSource) async throws -> PluginInstallation {
        try await install(entry: entry, from: source, progress: nil)
    }

    public func install(
        entry: PluginCatalogEntry,
        from source: PluginSource,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> PluginInstallation {
        guard entry.hostAPIVersion == Self.hostAPIVersion else {
            throw PluginError.incompatibleHostAPI(entry.hostAPIVersion)
        }
        let package = try await download(
            url: entry.artifactURL,
            maximumBytes: Self.maximumPluginBytes,
            expectedBytes: entry.downloadSize,
            progress: progress
        )
        guard Int64(package.count) == entry.downloadSize else { throw PluginError.hashMismatch }
        guard Self.sha256(package) == entry.sha256.lowercased() else { throw PluginError.hashMismatch }
        try Self.verify(signature: entry.signature, data: package, publicKey: source.publicKey)
        return try installPackageData(package, trust: source.trust, sourceName: source.name, expected: entry)
    }

    public func packageDetails(
        entry: PluginCatalogEntry,
        from source: PluginSource
    ) async throws -> PluginPackageDetails {
        let package = try await download(
            url: entry.artifactURL,
            maximumBytes: Self.maximumPluginBytes,
            expectedBytes: entry.downloadSize,
            progress: nil
        )
        guard Int64(package.count) == entry.downloadSize,
              Self.sha256(package) == entry.sha256.lowercased() else {
            throw PluginError.hashMismatch
        }
        try Self.verify(signature: entry.signature, data: package, publicKey: source.publicKey)
        return try Self.inspectPackageData(package, expected: entry)
    }

    public func packageDetails(for installation: PluginInstallation) throws -> PluginPackageDetails {
        let fileManager = FileManager.default
        let root = installation.installationURL.standardizedFileURL
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw PluginError.invalidPackage("The installed plugin resources could not be read.")
        }
        var resources: [String: Data] = [:]
        var resourcePaths: [String] = []
        for case let resourceURL as URL in enumerator {
            let values = try resourceURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true,
                  values.fileSize ?? 0 <= Self.maximumPluginResourceBytes else { continue }
            let standardized = resourceURL.standardizedFileURL
            guard standardized.path.hasPrefix(root.path + "/") else { continue }
            let relativePath = String(standardized.path.dropFirst(root.path.count + 1))
            resourcePaths.append(relativePath)
            let fileExtension = (relativePath as NSString).pathExtension.lowercased()
            guard ["json", "plist", "md"].contains(fileExtension) else { continue }
            resources[relativePath] = try Data(contentsOf: standardized, options: .mappedIfSafe)
        }
        return Self.makePackageDetails(
            manifest: installation.manifest,
            resources: resources,
            resourcePaths: resourcePaths
        )
    }

    public func importLocalPackage(url: URL, allowUnsigned: Bool) throws -> PluginInstallation {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard values.fileSize ?? 0 <= Self.maximumPluginBytes else { throw PluginError.pluginTooLarge }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard allowUnsigned else { throw PluginError.untrustedPublisher }
        return try installPackageData(data, trust: .localUnsigned, sourceName: "Local import", expected: nil)
    }

    public func removePlugin(id: String) throws {
        guard !inUsePluginIDs.contains(id) else { throw PluginError.pluginInUse }
        let target = storageRoot.appendingPathComponent(Self.safeComponent(id), isDirectory: true)
        guard FileManager.default.fileExists(atPath: target.path) else { throw PluginError.pluginNotFound }
        try FileManager.default.removeItem(at: target)
    }

    public func beginUsing(pluginID: String) { inUsePluginIDs.insert(pluginID) }
    public func endUsing(pluginID: String) { inUsePluginIDs.remove(pluginID) }

    public static func verifyEnvelope(
        _ envelope: PluginCatalogEnvelopeV1,
        publicKey: String
    ) throws -> PluginCatalogPayloadV1 {
        guard envelope.schemaVersion == 1,
              let payloadData = Data(base64Encoded: envelope.payload) else {
            throw PluginError.invalidEnvelope
        }
        try verify(signature: envelope.signature, data: payloadData, publicKey: publicKey)
        let payload = try JSONDecoder().decode(PluginCatalogPayloadV1.self, from: payloadData)
        guard payload.schemaVersion == 1 else { throw PluginError.invalidEnvelope }
        return payload
    }

    public static func validateRemoteURL(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              let host = url.host?.lowercased(),
              !host.isEmpty else { throw PluginError.invalidURL }
        let blockedNames = ["localhost", "localhost.localdomain"]
        if blockedNames.contains(host) || host.hasSuffix(".local") || isPrivateIPv4(host) || isPrivateIPv6(host) {
            throw PluginError.privateNetworkURL
        }
    }

    private func installPackageData(
        _ data: Data,
        trust: PluginTrust,
        sourceName: String,
        expected: PluginCatalogEntry?
    ) throws -> PluginInstallation {
        guard data.count <= Self.maximumPluginBytes else { throw PluginError.pluginTooLarge }
        let fileManager = FileManager.default
        let stagingRoot = fileManager.temporaryDirectory
            .appendingPathComponent("IPALens-Plugin-\(UUID().uuidString)", isDirectory: true)
        let packageURL = stagingRoot.appendingPathComponent("Plugin.ipalensplugin")
        let extractedURL = stagingRoot.appendingPathComponent("Extracted", isDirectory: true)
        try fileManager.createDirectory(at: extractedURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stagingRoot) }
        try data.write(to: packageURL, options: .atomic)

        let archive: Archive
        do {
            archive = try Archive(url: packageURL, accessMode: .read)
        } catch {
            throw PluginError.invalidPackage("The file is not a readable ZIP archive.")
        }
        var entryCount = 0
        var uncompressedBytes: Int64 = 0
        var normalizedPaths = Set<String>()
        for entry in archive {
            entryCount += 1
            guard entryCount <= Self.maximumPluginEntries else {
                throw PluginError.invalidPackage("The package contains too many files.")
            }
            let normalized = try Self.validatePackagePath(entry.path)
            guard normalizedPaths.insert(normalized.lowercased()).inserted else {
                throw PluginError.invalidPackage("Duplicate path: \(normalized)")
            }
            uncompressedBytes += Int64(entry.uncompressedSize)
            guard uncompressedBytes <= Self.maximumPluginBytes else { throw PluginError.pluginTooLarge }
            guard entry.type != .symlink else {
                throw PluginError.invalidPackage("Symbolic links are not permitted.")
            }
            if entry.type == .file {
                try Self.validateAllowedFile(normalized)
                let perFileLimit = normalized == "Plugin.json"
                    ? Self.maximumManifestBytes
                    : Self.maximumPluginResourceBytes
                guard entry.uncompressedSize <= UInt32(perFileLimit) else {
                    throw PluginError.invalidPackage("A plugin resource exceeds its size limit: \(normalized)")
                }
            }
            let destination = extractedURL.appendingPathComponent(normalized)
            guard destination.standardizedFileURL.path.hasPrefix(extractedURL.standardizedFileURL.path + "/") else {
                throw PluginError.invalidPackage("Unsafe extraction path.")
            }
            if entry.type == .directory {
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            } else {
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                _ = try archive.extract(entry, to: destination)
            }
        }

        let manifestURL = extractedURL.appendingPathComponent("Plugin.json")
        let manifest = try Self.decodeManifest(Data(contentsOf: manifestURL))
        if let expected {
            guard manifest.id == expected.id,
                  manifest.version == expected.version,
                  manifest.publisher == expected.publisher,
                  manifest.hostAPIVersion == expected.hostAPIVersion else {
                throw PluginError.invalidPackage("The manifest does not match its catalog entry.")
            }
        }

        try fileManager.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        let pluginRoot = storageRoot.appendingPathComponent(Self.safeComponent(manifest.id), isDirectory: true)
        try fileManager.createDirectory(at: pluginRoot, withIntermediateDirectories: true)
        let finalURL = pluginRoot.appendingPathComponent(Self.safeComponent(manifest.version), isDirectory: true)
        let rollbackURL = pluginRoot.appendingPathComponent(".Rollback-\(UUID().uuidString)", isDirectory: true)
        let installedAt = Date()
        let current = CurrentInstallation(
            version: manifest.version,
            trust: trust,
            sourceName: sourceName,
            installedAt: installedAt
        )
        let currentData = try JSONEncoder.pretty.encode(current)
        do {
            if fileManager.fileExists(atPath: finalURL.path) {
                try fileManager.moveItem(at: finalURL, to: rollbackURL)
            }
            try fileManager.moveItem(at: extractedURL, to: finalURL)
            try currentData.write(to: pluginRoot.appendingPathComponent("Current.json"), options: .atomic)
            if fileManager.fileExists(atPath: rollbackURL.path) {
                try? fileManager.removeItem(at: rollbackURL)
            }
        } catch {
            if fileManager.fileExists(atPath: finalURL.path) {
                try? fileManager.removeItem(at: finalURL)
            }
            if fileManager.fileExists(atPath: rollbackURL.path) {
                try? fileManager.moveItem(at: rollbackURL, to: finalURL)
            }
            throw error
        }
        return PluginInstallation(
            manifest: manifest,
            trust: trust,
            sourceName: sourceName,
            installedAt: installedAt,
            installationURL: finalURL
        )
    }

    private static func inspectPackageData(
        _ data: Data,
        expected: PluginCatalogEntry?
    ) throws -> PluginPackageDetails {
        guard data.count <= maximumPluginBytes else { throw PluginError.pluginTooLarge }
        let archive: Archive
        do {
            archive = try Archive(data: data, accessMode: .read)
        } catch {
            throw PluginError.invalidPackage("The file is not a readable ZIP archive.")
        }

        var entryCount = 0
        var uncompressedBytes: Int64 = 0
        var normalizedPaths = Set<String>()
        var resourcePaths: [String] = []
        var resources: [String: Data] = [:]
        for entry in archive {
            entryCount += 1
            guard entryCount <= maximumPluginEntries else {
                throw PluginError.invalidPackage("The package contains too many files.")
            }
            let normalized = try validatePackagePath(entry.path)
            guard normalizedPaths.insert(normalized.lowercased()).inserted else {
                throw PluginError.invalidPackage("Duplicate path: \(normalized)")
            }
            uncompressedBytes += Int64(entry.uncompressedSize)
            guard uncompressedBytes <= maximumPluginBytes else { throw PluginError.pluginTooLarge }
            guard entry.type != .symlink else {
                throw PluginError.invalidPackage("Symbolic links are not permitted.")
            }
            guard entry.type == .file else { continue }

            try validateAllowedFile(normalized)
            let perFileLimit = normalized == "Plugin.json"
                ? maximumManifestBytes
                : maximumPluginResourceBytes
            guard entry.uncompressedSize <= UInt32(perFileLimit) else {
                throw PluginError.invalidPackage("A plugin resource exceeds its size limit: \(normalized)")
            }
            resourcePaths.append(normalized)
            let fileExtension = (normalized as NSString).pathExtension.lowercased()
            guard ["json", "plist", "md"].contains(fileExtension) else { continue }
            var resourceData = Data()
            resourceData.reserveCapacity(Int(entry.uncompressedSize))
            _ = try archive.extract(entry) { chunk in
                resourceData.append(chunk)
            }
            resources[normalized] = resourceData
        }

        guard let manifestData = resources["Plugin.json"] else {
            throw PluginError.invalidPackage("The package must contain Plugin.json at its root.")
        }
        let manifest = try decodeManifest(manifestData)
        if let expected {
            guard manifest.id == expected.id,
                  manifest.version == expected.version,
                  manifest.publisher == expected.publisher,
                  manifest.hostAPIVersion == expected.hostAPIVersion else {
                throw PluginError.invalidPackage("The manifest does not match its catalog entry.")
            }
        }
        return makePackageDetails(
            manifest: manifest,
            resources: resources,
            resourcePaths: resourcePaths
        )
    }

    private static func makePackageDetails(
        manifest: PluginManifestV1,
        resources: [String: Data],
        resourcePaths: [String]? = nil
    ) -> PluginPackageDetails {
        let readmeResource = resources.first { $0.key.lowercased() == "readme.md" }
        let decodedReadme = readmeResource
            .flatMap { String(data: $0.value, encoding: .utf8) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let hasReadme = decodedReadme?.isEmpty == false
        let readme = hasReadme ? decodedReadme! : PluginPackageDetails.missingReadmeText

        var searchableResources: [(String, String)] = []
        for (path, data) in resources {
            if let text = String(data: data, encoding: .utf8) {
                searchableResources.append((path, text))
            } else {
                searchableResources.append((path, String(decoding: data, as: UTF8.self)))
            }
        }
        return PluginPackageDetails(
            manifest: manifest,
            readme: readme,
            hasReadme: hasReadme,
            permissions: permissions(for: manifest, resources: searchableResources),
            resourcePaths: (resourcePaths ?? Array(resources.keys)).sorted()
        )
    }

    private static func permissions(
        for manifest: PluginManifestV1,
        resources: [(String, String)]
    ) -> [PluginPermission] {
        var permissions: [PluginPermission] = [
            PluginPermission(
                id: "user-selected-files",
                kind: .userSelectedFiles,
                title: "Files and Folders",
                explanation: "Reads only packages and export locations selected by the user.",
                evidence: "IPALens host access; the plugin receives no direct filesystem access"
            )
        ]
        for capability in manifest.capabilities {
            switch capability {
            case .applicationBundle:
                permissions.append(.init(
                    id: "application-bundles",
                    kind: .applicationBundles,
                    title: "Application Bundles",
                    explanation: "Defines how IPALens reads application bundle metadata and contents.",
                    evidence: "Declared capability: applicationBundle"
                ))
            case .zipArchive:
                permissions.append(.init(
                    id: "zip-archives",
                    kind: .archives,
                    title: "Compressed Archives",
                    explanation: "Allows IPALens to inspect supported ZIP containers without executing their contents.",
                    evidence: "Declared capability: zipArchive"
                ))
            case .diskImage:
                permissions.append(.init(
                    id: "disk-images",
                    kind: .diskImages,
                    title: "Disk Images",
                    explanation: "Allows verified, read-only inspection of disk-image contents.",
                    evidence: "Declared capability: diskImage"
                ))
                permissions.append(systemCommandPermission(
                    command: "/usr/bin/hdiutil",
                    evidence: "Declared diskImage capability"
                ))
            case .installerPackage:
                permissions.append(.init(
                    id: "installer-packages",
                    kind: .installerPackages,
                    title: "Installer Packages",
                    explanation: "Allows package payloads to be expanded for read-only inspection; installer scripts remain inert.",
                    evidence: "Declared capability: installerPackage"
                ))
                permissions.append(systemCommandPermission(
                    command: "/usr/sbin/pkgutil",
                    evidence: "Declared installerPackage capability"
                ))
            }
        }

        var commandIDs = Set(permissions.filter { $0.kind == .systemCommand }.map(\.id))
        for command in recognizedCommands {
            guard let resource = resources.first(where: { containsCommand(command, in: $0.1) }) else { continue }
            let permission = systemCommandPermission(
                command: command.path,
                evidence: "Static reference found in \(resource.0)"
            )
            if commandIDs.insert(permission.id).inserted {
                permissions.append(permission)
            }
        }
        return permissions
    }

    private static func systemCommandPermission(command: String, evidence: String) -> PluginPermission {
        PluginPermission(
            id: "command-\(safeComponent(command))",
            kind: .systemCommand,
            title: (command as NSString).lastPathComponent,
            explanation: "This command is host-controlled. Data-only plugins cannot execute commands themselves.",
            evidence: "\(evidence) → \(command)"
        )
    }

    private static let recognizedCommands: [(name: String, path: String)] = [
        ("hdiutil", "/usr/bin/hdiutil"),
        ("pkgutil", "/usr/sbin/pkgutil"),
        ("codesign", "/usr/bin/codesign"),
        ("security", "/usr/bin/security"),
        ("spctl", "/usr/sbin/spctl"),
        ("installer", "/usr/sbin/installer"),
        ("diskutil", "/usr/sbin/diskutil"),
        ("ditto", "/usr/bin/ditto"),
        ("plutil", "/usr/bin/plutil"),
        ("otool", "/usr/bin/otool"),
        ("xcrun", "/usr/bin/xcrun"),
        ("xcodebuild", "/usr/bin/xcodebuild"),
        ("open", "/usr/bin/open"),
        ("osascript", "/usr/bin/osascript"),
        ("bash", "/bin/bash"),
        ("zsh", "/bin/zsh"),
        ("sh", "/bin/sh"),
        ("python3", "/usr/bin/python3"),
        ("node", "/usr/local/bin/node")
    ]

    private static func containsCommand(_ command: (name: String, path: String), in text: String) -> Bool {
        if text.range(of: command.path, options: .caseInsensitive) != nil { return true }
        let lowercased = text.lowercased()
        let name = command.name.lowercased()
        if lowercased.contains("`\(name)`") ||
            lowercased.contains("\"\(name)\"") ||
            lowercased.contains("'\(name)'") {
            return true
        }
        let escaped = NSRegularExpression.escapedPattern(for: command.name)
        let pattern = "(?m)^\\s*(?:\\$\\s*)?\(escaped)(?:\\s|$)"
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return false
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.firstMatch(in: text, range: range) != nil
    }

    private func persistSources(_ sources: [PluginSource]) throws {
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        try JSONEncoder.pretty.encode(sources).write(to: sourcesFile, options: .atomic)
    }

    private func download(
        url: URL,
        maximumBytes: Int,
        expectedBytes: Int64? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Data {
        do {
            let (bytes, response) = try await session.bytes(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw PluginError.downloadFailed("The server returned an unexpected response.")
            }
            if let finalURL = http.url { try Self.validateRemoteURL(finalURL) }
            if let expectedLength = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init),
               expectedLength > maximumBytes {
                throw Self.sizeError(for: maximumBytes)
            }
            var data = Data()
            data.reserveCapacity(min(maximumBytes, max(0, Int(http.expectedContentLength))))
            let progressTotal: Int64?
            if let expectedBytes, expectedBytes > 0 {
                progressTotal = expectedBytes
            } else if http.expectedContentLength > 0 {
                progressTotal = http.expectedContentLength
            } else {
                progressTotal = nil
            }
            progress?(0)
            var nextProgressUpdate = 16 * 1_024
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < maximumBytes else { throw Self.sizeError(for: maximumBytes) }
                data.append(byte)
                if data.count >= nextProgressUpdate,
                   let progressTotal {
                    progress?(min(1, Double(data.count) / Double(progressTotal)))
                    nextProgressUpdate = data.count + 16 * 1_024
                }
            }
            progress?(1)
            return data
        } catch let error as PluginError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PluginError.downloadFailed(error.localizedDescription)
        }
    }

    private static func verify(signature: String, data: Data, publicKey: String) throws {
        guard let keyData = Data(base64Encoded: publicKey),
              let signatureData = Data(base64Encoded: signature),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              key.isValidSignature(signatureData, for: data) else {
            throw PluginError.invalidSignature
        }
    }

    private static func decodeManifest(_ data: Data) throws -> PluginManifestV1 {
        let rootObject: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw PluginError.invalidPackage("Plugin.json must contain a JSON object.")
            }
            rootObject = object
        } catch let error as PluginError {
            throw error
        } catch {
            throw PluginError.invalidPackage("Plugin.json could not be decoded.")
        }
        let allowedRootKeys: Set<String> = [
            "schemaVersion", "id", "name", "version", "publisher", "description",
            "hostAPIVersion", "capabilities", "platform"
        ]
        let unknownRootKeys = Set(rootObject.keys).subtracting(allowedRootKeys)
        guard unknownRootKeys.isEmpty else {
            throw PluginError.invalidPackage(
                "Plugin.json contains unknown fields: \(unknownRootKeys.sorted().joined(separator: ", "))."
            )
        }
        guard let platformObject = rootObject["platform"] as? [String: Any] else {
            throw PluginError.invalidPackage("Plugin.json is missing its platform definition.")
        }
        let allowedPlatformKeys: Set<String> = [
            "platformIdentifier", "displayName", "appBundleSuffix", "infoPlistRelativePath",
            "executableDirectory", "frameworksDirectories", "componentDirectories",
            "componentSuffixes", "minimumSystemVersionKey", "privacyManifestNames"
        ]
        let unknownPlatformKeys = Set(platformObject.keys).subtracting(allowedPlatformKeys)
        guard unknownPlatformKeys.isEmpty else {
            throw PluginError.invalidPackage(
                "The platform definition contains unknown fields: \(unknownPlatformKeys.sorted().joined(separator: ", "))."
            )
        }
        let decoder = JSONDecoder()
        let manifest: PluginManifestV1
        do {
            manifest = try decoder.decode(PluginManifestV1.self, from: data)
        } catch {
            throw PluginError.invalidPackage("Plugin.json could not be decoded.")
        }
        guard manifest.schemaVersion == 1,
              manifest.hostAPIVersion == hostAPIVersion,
              !manifest.id.isEmpty,
              safeComponent(manifest.id) == manifest.id,
              !manifest.name.isEmpty,
              !manifest.version.isEmpty,
              safeComponent(manifest.version) == manifest.version,
              !manifest.publisher.isEmpty else {
            throw PluginError.invalidPackage("Plugin.json contains unsupported or missing values.")
        }
        return manifest
    }

    private static func validatePackagePath(_ raw: String) throws -> String {
        guard !raw.isEmpty,
              !raw.hasPrefix("/"),
              !raw.hasPrefix("~"),
              !raw.contains("\\"),
              !raw.contains("\0") else {
            throw PluginError.invalidPackage("Unsafe path: \(raw)")
        }
        var value = raw
        while value.hasSuffix("/") { value.removeLast() }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw PluginError.invalidPackage("Unsafe path: \(raw)")
        }
        return components.map(String.init).joined(separator: "/")
            .precomposedStringWithCanonicalMapping
    }

    private static func validateAllowedFile(_ path: String) throws {
        let allowedExtensions = ["json", "plist", "md", "png", "icns"]
        let fileExtension = (path as NSString).pathExtension.lowercased()
        guard allowedExtensions.contains(fileExtension) else {
            throw PluginError.invalidPackage("Unsupported file type: \(path)")
        }
    }

    private static func safeComponent(_ value: String) -> String {
        value.map { character in
            character.isLetter || character.isNumber || character == "." || character == "-" ? character : "_"
        }.reduce(into: "") { $0.append($1) }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        return parts[0] == 0 ||
            parts[0] == 10 ||
            parts[0] == 127 ||
            (parts[0] == 169 && parts[1] == 254) ||
            (parts[0] == 172 && (16...31).contains(parts[1])) ||
            (parts[0] == 192 && parts[1] == 168) ||
            (parts[0] == 100 && (64...127).contains(parts[1])) ||
            (parts[0] == 198 && (18...19).contains(parts[1])) ||
            parts[0] >= 224
    }

    private static func isPrivateIPv6(_ host: String) -> Bool {
        let value = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if value == "::" || value == "::1" || value.hasPrefix("ff") { return true }
        if value.hasPrefix("fc") || value.hasPrefix("fd") { return true }
        if ["fe8", "fe9", "fea", "feb"].contains(where: value.hasPrefix) { return true }
        if let mapped = value.split(separator: ":").last,
           value.contains("::ffff:"), isPrivateIPv4(String(mapped)) {
            return true
        }
        return false
    }

    private static func sizeError(for maximumBytes: Int) -> PluginError {
        maximumBytes == maximumCatalogBytes ? .catalogTooLarge : .pluginTooLarge
    }
}

private struct CurrentInstallation: Codable {
    let version: String
    let trust: PluginTrust
    let sourceName: String
    let installedAt: Date
}

private final class HTTPSRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              (try? PluginManager.validateRemoteURL(url)) != nil else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var ipalens: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
