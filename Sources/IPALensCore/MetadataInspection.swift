import Foundation
import IPALensPluginKit

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

    static func inspectBundles(
        url: URL,
        index: ArchiveIndex,
        platform: PlatformDefinitionV1 = .iOS
    ) -> Result {
        let infoPlistPaths = index.entries
            .filter { entry in
                guard entry.kind == .file, entry.name == "Info.plist" else { return false }
                if platform.platformIdentifier == "ios" {
                    let components = entry.path.split(separator: "/")
                    return components.count == 3 &&
                        components[0] == "Payload" &&
                        components[1].hasSuffix(platform.appBundleSuffix)
                }
                let suffix = "/" + platform.infoPlistRelativePath
                guard entry.path.hasSuffix(suffix) else { return false }
                let bundlePath = String(entry.path.dropLast(suffix.count))
                guard bundlePath.hasSuffix(platform.appBundleSuffix) else { return false }
                let prefix = bundlePath + "/"
                return !index.entries.contains {
                    $0.kind == .directory &&
                        $0.path != bundlePath &&
                        bundlePath.hasPrefix($0.path + "/") &&
                        $0.path.hasSuffix(platform.appBundleSuffix) &&
                        prefix.hasPrefix($0.path + "/")
                }
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
                message: platform.platformIdentifier == "ios"
                    ? "IPALens could not find a top-level app bundle at Payload/*.app/Info.plist. You can still browse the package files."
                    : "IPALens could not find a top-level macOS app bundle. You can still browse the package files."
            ))
        }

        for infoPath in infoPlistPaths {
            do {
                let bundlePath: String
                if platform.platformIdentifier == "ios" {
                    bundlePath = ArchivePathValidator.parentPath(of: infoPath)!
                } else {
                    let suffix = "/" + platform.infoPlistRelativePath
                    bundlePath = String(infoPath.dropLast(suffix.count))
                }
                guard index.entryByPath[infoPath]?.uncompressedSize ?? 0 <= 32 * 1_024 * 1_024 else {
                    throw MetadataError.infoPlistTooLarge
                }
                let data = try ArchiveIndexer.readEntry(url: url, index: index, path: infoPath).data
                let plist = try PropertyListParser.dictionary(data: data)

                let executableName = plist["CFBundleExecutable"] as? String
                let executablePath = executableName.map {
                    let directory = platform.executableDirectory.isEmpty ? "" : "/" + platform.executableDirectory
                    return bundlePath + directory + "/" + $0
                }
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
                let frameworks = detectFrameworks(bundlePath: bundlePath, index: index, platform: platform)
                let extensions = inspectExtensions(
                    url: url,
                    bundlePath: bundlePath,
                    index: index,
                    platform: platform,
                    issues: &issues
                )
                let privacyPaths = index.entries
                    .filter {
                        $0.kind == .file &&
                            $0.path.hasPrefix(bundlePath + "/") &&
                            platform.privacyManifestNames.contains($0.name)
                    }
                    .map(\.path)
                    .sorted()

                if platform.platformIdentifier == "ios", let profilePath = index.entries.first(where: {
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
                    minimumOSVersion: plist[platform.minimumSystemVersionKey] as? String,
                    executableName: executableName,
                    executablePath: executablePath,
                    iconPath: findIconPath(bundlePath: bundlePath, plist: plist, index: index, platform: platform),
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

    private static func detectFrameworks(
        bundlePath: String,
        index: ArchiveIndex,
        platform: PlatformDefinitionV1
    ) -> [FrameworkSummary] {
        var values: [FrameworkSummary] = []
        let prefix = bundlePath + "/"
        for entry in index.entries where entry.path.hasPrefix(prefix) {
            let isFrameworkLocation = platform.frameworksDirectories.contains { directory in
                entry.path.hasPrefix(bundlePath + "/" + directory + "/")
            }
            if entry.kind == .directory && entry.name.hasSuffix(".framework") && isFrameworkLocation {
                values.append(.init(
                    path: entry.path,
                    name: entry.name,
                    kind: "Framework",
                    isInjectedCodeCandidate: false
                ))
            } else if entry.kind == .file && entry.name.lowercased().hasSuffix(".dylib") && isFrameworkLocation {
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
        platform: PlatformDefinitionV1,
        issues: inout [InspectionIssue]
    ) -> [ExtensionSummary] {
        let extensionDirectories = index.entries.filter { entry in
            guard entry.kind == .directory,
                  entry.path.hasPrefix(bundlePath + "/"),
                  entry.path != bundlePath else { return false }
            return platform.componentSuffixes.contains { suffix in
                entry.path.lowercased().hasSuffix(suffix.lowercased())
            }
        }
        return extensionDirectories.map { entry in
            let plistPath: String
            if platform.platformIdentifier == "macos" {
                plistPath = entry.path + "/Contents/Info.plist"
            } else {
                plistPath = entry.path + "/Info.plist"
            }
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

    private static func findIconPath(
        bundlePath: String,
        plist: [String: Any],
        index: ArchiveIndex,
        platform: PlatformDefinitionV1
    ) -> String? {
        var iconNames: [String] = []
        if let icon = plist["CFBundleIconFile"] as? String {
            iconNames.append(icon)
        }
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
            let candidates: [String]
            if platform.platformIdentifier == "macos" {
                candidates = [name, name + ".icns"].map { bundlePath + "/Contents/Resources/" + $0 }
            } else {
                candidates = [name, name + ".png", name + "@3x.png", name + "@2x.png"].map { bundlePath + "/" + $0 }
            }
            for candidate in candidates {
                if allPaths.contains(candidate) { return candidate }
            }
        }

        return index.entries.first(where: {
            $0.kind == .file && $0.path.hasPrefix(bundlePath + "/") &&
                ($0.name.localizedCaseInsensitiveContains("AppIcon") ||
                    $0.name == "iTunesArtwork" ||
                    $0.name.lowercased().hasSuffix(".icns"))
        })?.path
    }

    private enum MetadataError: LocalizedError {
        case infoPlistTooLarge

        var errorDescription: String? {
            "Info.plist exceeds the 32 MiB metadata limit."
        }
    }
}
