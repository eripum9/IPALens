import Foundation

public struct InspectionReportV1: Codable, Sendable, Hashable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let package: IPAPackageSnapshot

    public init(snapshot: IPAPackageSnapshot) {
        schemaVersion = 1
        generatedAt = snapshot.generatedAt
        package = snapshot
    }

    public func jsonData(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = prettyPrinted
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public func markdown() -> String {
        var lines: [String] = []
        lines.append("# IPALens Inspection Report")
        lines.append("")
        lines.append("> Read-only inspection of observable package evidence. This report is not a malware or safety verdict.")
        lines.append("")
        lines.append("- **Package:** \(escaped(package.sourceFileName))")
        lines.append("- **Generated:** \(package.generatedAt.ISO8601Format())")
        lines.append("- **Package size:** \(package.sourceFileSize) bytes")
        lines.append("- **Package SHA-256:** `\(package.packageSHA256 ?? "Not computed")`")
        lines.append("- **Entries:** \(package.entries.count)")
        lines.append("")

        for bundle in package.appBundles {
            lines.append("## \(escaped(bundle.displayName))")
            lines.append("")
            lines.append("- **Bundle path:** `\(inlineCode(bundle.bundlePath))`")
            lines.append("- **Bundle ID:** `\(inlineCode(bundle.bundleIdentifier ?? "Unknown"))`")
            lines.append("- **Version:** \(escaped(bundle.version ?? "Unknown")) (\(escaped(bundle.build ?? "Unknown")))")
            lines.append("- **Minimum iOS:** \(escaped(bundle.minimumOSVersion ?? "Unknown"))")
            lines.append("- **Executable:** `\(inlineCode(bundle.executableName ?? "Unknown"))`")
            lines.append("")

            if let signing = package.signing.first(where: { $0.bundlePath == bundle.bundlePath }) {
                lines.append("### Signing")
                lines.append("")
                lines.append("- **Status:** \(signing.status.rawValue.capitalized)")
                lines.append("- **Identifier:** `\(inlineCode(signing.identifier ?? "Unknown"))`")
                lines.append("- **Team ID:** `\(inlineCode(signing.teamIdentifier ?? "Unknown"))`")
                if let provisioning = signing.provisioning {
                    lines.append("- **Profile:** \(escaped(provisioning.name ?? "Unnamed"))")
                    lines.append("- **Distribution:** \(escaped(provisioning.distributionKind))")
                    lines.append("- **Profile expiration:** \(provisioning.expirationDate?.ISO8601Format() ?? "Unknown")")
                }
                lines.append("")

                lines.append("### Entitlements")
                lines.append("")
                if signing.entitlements.values.isEmpty {
                lines.append("No readable code-signing entitlements were found.")
                } else {
                    for key in signing.entitlements.values.keys.sorted() {
                        lines.append("- `\(inlineCode(key))`: \(escaped(signing.entitlements.values[key]!.displayValue))")
                    }
                }
                lines.append("")
            }

            lines.append("### Permissions and privacy")
            lines.append("")
            if bundle.permissions.isEmpty {
                lines.append("No usage-description permission keys were found.")
            } else {
                for permission in bundle.permissions {
                    lines.append("- `\(inlineCode(permission.key))`: \(escaped(permission.description))")
                }
            }
            lines.append("- **URL schemes:** \(bundle.urlSchemes.isEmpty ? "None" : bundle.urlSchemes.map { "`\(inlineCode($0))`" }.joined(separator: ", "))")
            lines.append("- **Privacy manifests:** \(bundle.privacyManifestPaths.count)")
            lines.append("- **ATS arbitrary network loads:** \(bundle.appTransportSecurity.allowsArbitraryLoads ? "Allowed" : "Not allowed")")
            lines.append("")

            lines.append("### Embedded code")
            lines.append("")
            if bundle.frameworks.isEmpty {
                lines.append("No frameworks or standalone dynamic libraries were found.")
            } else {
                for framework in bundle.frameworks {
                    let marker = framework.isInjectedCodeCandidate ? " — standalone executable code to review" : ""
                    lines.append("- `\(inlineCode(framework.path))` (\(escaped(framework.kind)))\(marker)")
                }
            }
            lines.append("- **Extensions:** \(bundle.extensions.count)")
            lines.append("")
        }

        lines.append("## Inspection Notes")
        lines.append("")
        if package.issues.isEmpty {
            lines.append("No parser or package-structure notes were recorded.")
        } else {
            for issue in package.issues {
                let path = issue.path.map { " (`\(inlineCode($0))`)" } ?? ""
                lines.append("- **\(issue.severity.rawValue.capitalized) — \(escaped(issue.category))**\(path): \(escaped(issue.message))")
            }
        }
        lines.append("")
        lines.append("## File inventory")
        lines.append("")
        lines.append("| Path | Kind | Size | SHA-256 |")
        lines.append("|---|---:|---:|---|")
        for entry in package.entries {
            lines.append("| `\(inlineCode(entry.path))` | \(displayName(for: entry.kind)) | \(entry.uncompressedSize) | `\(entry.sha256 ?? "—")` |")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "_", with: "\\_")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private func inlineCode(_ value: String) -> String {
        value.replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private func displayName(for kind: IPAEntryKind) -> String {
        switch kind {
        case .file: "File"
        case .directory: "Directory"
        case .symbolicLink: "Symbolic link"
        }
    }
}
