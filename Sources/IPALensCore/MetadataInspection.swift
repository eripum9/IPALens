import Foundation

enum PropertyListParser {
    static func object(data: Data) throws -> Any {
        try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    }

    static func dictionary(data: Data) throws -> [String: Any] {
        guard let dictionary = try object(data: data) as? [String: Any] else {
            throw Error.notDictionary
        }
        return dictionary
    }

    enum Error: LocalizedError {
        case notDictionary

        var errorDescription: String? { "The property list root is not a dictionary." }
    }
}

enum MetadataInspector {
    struct Result: Sendable {
        let bundles: [AppBundleSummary]
        let provisioningByBundlePath: [String: ProvisioningSummary]
        let issues: [InspectionIssue]
    }

    static func inspectBundles(url: URL, index: ArchiveIndex) -> Result {
        let infoPlistPaths = index.entries
            .filter { entry in
                let components = entry.path.split(separator: "/")
                return entry.kind == .file &&
                    components.count == 3 &&
                    components[0] == "Payload" &&
                    components[1].hasSuffix(".app") &&
                    components[2] == "Info.plist"
            }
            .map(\.path)
            .sorted()

        var bundles: [AppBundleSummary] = []
        var provisioningByBundlePath: [String: ProvisioningSummary] = [:]
        var issues: [InspectionIssue] = []

        if infoPlistPaths.isEmpty {
            issues.append(.init(
                severity: .warning,
                category: "Package structure",
                message: "IPALens could not find a top-level app bundle at Payload/*.app/Info.plist. You can still browse the package files."
            ))
        }

        for infoPath in infoPlistPaths {
            do {
                let bundlePath = ArchivePathValidator.parentPath(of: infoPath)!
                guard index.entryByPath[infoPath]?.uncompressedSize ?? 0 <= 32 * 1_024 * 1_024 else {
                    throw MetadataError.infoPlistTooLarge
                }
                let data = try ArchiveIndexer.readEntry(url: url, index: index, path: infoPath).data
                let plist = try PropertyListParser.dictionary(data: data)

                let executableName = plist["CFBundleExecutable"] as? String
                let executablePath = executableName.map { bundlePath + "/" + $0 }
                let machO = executablePath.flatMap { path -> MachOSummary? in
                    guard index.entryByPath[path]?.uncompressedSize ?? 0 <= 512 * 1_024 * 1_024 else {
                        issues.append(.init(
                            severity: .information,
                            category: "Mach-O",
                            path: path,
                            message: "IPALens skipped binary inspection because this executable exceeds the 512 MiB parsing limit."
                        ))
                        return nil
                    }
                    do {
                        let executableData = try ArchiveIndexer.readEntry(url: url, index: index, path: path).data
                        return try MachOParser.parse(data: executableData)
                    } catch {
                        issues.append(.init(
                            severity: .warning,
                            category: "Mach-O",
                            path: path,
                            message: error.localizedDescription
                        ))
                        return nil
                    }
                }

                let permissions = plist
                    .compactMap { key, value -> PermissionUsage? in
                        guard key.hasSuffix("UsageDescription"), let description = value as? String else { return nil }
                        return PermissionUsage(bundlePath: bundlePath, key: key, description: description)
                    }
                    .sorted { $0.key < $1.key }

                let urlSchemes = extractURLSchemes(from: plist)
                let ats = extractATS(from: plist)
                let frameworks = detectFrameworks(bundlePath: bundlePath, index: index)
                let extensions = inspectExtensions(url: url, bundlePath: bundlePath, index: index, issues: &issues)
                let privacyPaths = index.entries
                    .filter { $0.kind == .file && $0.path.hasPrefix(bundlePath + "/") && $0.name == "PrivacyInfo.xcprivacy" }
                    .map(\.path)
                    .sorted()

                if let profilePath = index.entries.first(where: {
                    $0.kind == .file && $0.path == bundlePath + "/embedded.mobileprovision"
                })?.path {
                    do {
                        let profileData = try ArchiveIndexer.readEntry(url: url, index: index, path: profilePath).data
                        provisioningByBundlePath[bundlePath] = try ProvisioningProfileParser.parse(data: profileData)
                    } catch {
                        issues.append(.init(
                            severity: .warning,
                            category: "Provisioning profile",
                            path: profilePath,
                            message: error.localizedDescription
                        ))
                    }
                }

                let fallbackName = bundlePath.split(separator: "/").last.map(String.init)?
                    .replacingOccurrences(of: ".app", with: "") ?? "Unknown App"
                bundles.append(AppBundleSummary(
                    bundlePath: bundlePath,
                    displayName: (plist["CFBundleDisplayName"] as? String) ??
                        (plist["CFBundleName"] as? String) ?? fallbackName,
                    bundleIdentifier: plist["CFBundleIdentifier"] as? String,
                    version: plist["CFBundleShortVersionString"] as? String,
                    build: plist["CFBundleVersion"] as? String,
                    minimumOSVersion: plist["MinimumOSVersion"] as? String,
                    executableName: executableName,
                    executablePath: executablePath,
                    iconPath: findIconPath(bundlePath: bundlePath, plist: plist, index: index),
                    infoPlistPath: infoPath,
                    permissions: permissions,
                    urlSchemes: urlSchemes,
                    appTransportSecurity: ats,
                    privacyManifestPaths: privacyPaths,
                    frameworks: frameworks,
                    extensions: extensions,
                    machO: machO
                ))
            } catch {
                issues.append(.init(
                    severity: .error,
                    category: "App metadata",
                    path: infoPath,
                    message: error.localizedDescription
                ))
            }
        }

        return Result(
            bundles: bundles,
            provisioningByBundlePath: provisioningByBundlePath,
            issues: issues
        )
    }

    private static func detectFrameworks(bundlePath: String, index: ArchiveIndex) -> [FrameworkSummary] {
        var values: [FrameworkSummary] = []
        let prefix = bundlePath + "/"
        for entry in index.entries where entry.path.hasPrefix(prefix) {
            if entry.kind == .directory && entry.name.hasSuffix(".framework") {
                values.append(.init(
                    path: entry.path,
                    name: entry.name,
                    kind: "Framework",
                    isInjectedCodeCandidate: false
                ))
            } else if entry.kind == .file && entry.name.lowercased().hasSuffix(".dylib") {
                values.append(.init(
                    path: entry.path,
                    name: entry.name,
                    kind: "Dynamic library",
                    isInjectedCodeCandidate: true
                ))
            }
        }
        return values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func inspectExtensions(
        url: URL,
        bundlePath: String,
        index: ArchiveIndex,
        issues: inout [InspectionIssue]
    ) -> [ExtensionSummary] {
        let extensionDirectories = index.entries.filter {
            $0.kind == .directory &&
                $0.path.hasPrefix(bundlePath + "/PlugIns/") &&
                $0.name.hasSuffix(".appex")
        }
        return extensionDirectories.map { entry in
            let plistPath = entry.path + "/Info.plist"
            do {
                let data = try ArchiveIndexer.readEntry(url: url, index: index, path: plistPath).data
                let plist = try PropertyListParser.dictionary(data: data)
                let extensionDictionary = plist["NSExtension"] as? [String: Any]
                return ExtensionSummary(
                    path: entry.path,
                    name: (plist["CFBundleDisplayName"] as? String) ?? entry.name,
                    bundleIdentifier: plist["CFBundleIdentifier"] as? String,
                    extensionPointIdentifier: extensionDictionary?["NSExtensionPointIdentifier"] as? String
                )
            } catch {
                issues.append(.init(
                    severity: .warning,
                    category: "Extension metadata",
                    path: plistPath,
                    message: error.localizedDescription
                ))
                return ExtensionSummary(
                    path: entry.path,
                    name: entry.name,
                    bundleIdentifier: nil,
                    extensionPointIdentifier: nil
                )
            }
        }.sorted { $0.path < $1.path }
    }

    private static func extractURLSchemes(from plist: [String: Any]) -> [String] {
        guard let types = plist["CFBundleURLTypes"] as? [[String: Any]] else { return [] }
        return Array(Set(types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] })).sorted()
    }

    private static func extractATS(from plist: [String: Any]) -> AppTransportSecuritySummary {
        guard let ats = plist["NSAppTransportSecurity"] as? [String: Any] else {
            return .init()
        }
        return .init(
            allowsArbitraryLoads: ats["NSAllowsArbitraryLoads"] as? Bool ?? false,
            allowsArbitraryLoadsInWebContent: ats["NSAllowsArbitraryLoadsInWebContent"] as? Bool ?? false,
            exceptionDomains: ((ats["NSExceptionDomains"] as? [String: Any])?.keys.sorted()) ?? []
        )
    }

    private static func findIconPath(bundlePath: String, plist: [String: Any], index: ArchiveIndex) -> String? {
        var iconNames: [String] = []
        if let icons = plist["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primary["CFBundleIconFiles"] as? [String] {
            iconNames.append(contentsOf: files.reversed())
        }
        if let files = plist["CFBundleIconFiles"] as? [String] {
            iconNames.append(contentsOf: files.reversed())
        }

        let allPaths = Set(index.entries.filter { $0.kind == .file }.map(\.path))
        for name in iconNames {
            let candidates = [name, name + ".png", name + "@3x.png", name + "@2x.png"]
            for candidate in candidates {
                let path = bundlePath + "/" + candidate
                if allPaths.contains(path) { return path }
            }
        }

        return index.entries.first(where: {
            $0.kind == .file && $0.parentPath == bundlePath &&
                ($0.name.localizedCaseInsensitiveContains("AppIcon") || $0.name == "iTunesArtwork")
        })?.path
    }

    private enum MetadataError: LocalizedError {
        case infoPlistTooLarge

        var errorDescription: String? {
            "Info.plist exceeds the 32 MiB metadata limit."
        }
    }
}
