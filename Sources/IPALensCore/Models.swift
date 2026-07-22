import Foundation

public enum IPAEntryKind: String, Codable, Sendable, Hashable {
    case file
    case directory
    case symbolicLink
}

public struct IPAEntry: Identifiable, Codable, Sendable, Hashable {
    public var id: String { path }

    public let path: String
    public let name: String
    public let parentPath: String?
    public let kind: IPAEntryKind
    public let compressedSize: Int64
    public let uncompressedSize: Int64
    public let compressionMethod: String
    public let sha256: String?
    public let childPaths: [String]
    public let isSyntheticDirectory: Bool

    public init(
        path: String,
        name: String,
        parentPath: String?,
        kind: IPAEntryKind,
        compressedSize: Int64,
        uncompressedSize: Int64,
        compressionMethod: String,
        sha256: String?,
        childPaths: [String],
        isSyntheticDirectory: Bool = false
    ) {
        self.path = path
        self.name = name
        self.parentPath = parentPath
        self.kind = kind
        self.compressedSize = compressedSize
        self.uncompressedSize = uncompressedSize
        self.compressionMethod = compressionMethod
        self.sha256 = sha256
        self.childPaths = childPaths
        self.isSyntheticDirectory = isSyntheticDirectory
    }
}

public enum PlistValue: Codable, Sendable, Hashable {
    case dictionary([String: PlistValue])
    case array([PlistValue])
    case string(String)
    case integer(Int64)
    case real(Double)
    case boolean(Bool)
    case date(Date)
    case data(Data)
    case null

    public init(any value: Any) {
        switch value {
        case let value as [String: Any]:
            self = .dictionary(value.mapValues(PlistValue.init(any:)))
        case let value as [Any]:
            self = .array(value.map(PlistValue.init(any:)))
        case let value as String:
            self = .string(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .boolean(value.boolValue)
            } else {
                let double = value.doubleValue
                let integer = value.int64Value
                self = double == Double(integer) ? .integer(integer) : .real(double)
            }
        case let value as Date:
            self = .date(value)
        case let value as Data:
            self = .data(value)
        default:
            self = .null
        }
    }

    public var displayValue: String {
        switch self {
        case .dictionary(let value): "Dictionary (\(value.count) keys)"
        case .array(let value): "Array (\(value.count) items)"
        case .string(let value): value
        case .integer(let value): String(value)
        case .real(let value): String(value)
        case .boolean(let value): value ? "Yes" : "No"
        case .date(let value): value.formatted(date: .abbreviated, time: .standard)
        case .data(let value): "Data (\(value.count) bytes)"
        case .null: "Null"
        }
    }
}

public struct PermissionUsage: Codable, Sendable, Hashable, Identifiable {
    public var id: String { "\(bundlePath):\(key)" }
    public let bundlePath: String
    public let key: String
    public let description: String

    public init(bundlePath: String, key: String, description: String) {
        self.bundlePath = bundlePath
        self.key = key
        self.description = description
    }
}

public struct ExtensionSummary: Codable, Sendable, Hashable, Identifiable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let bundleIdentifier: String?
    public let extensionPointIdentifier: String?

    public init(path: String, name: String, bundleIdentifier: String?, extensionPointIdentifier: String?) {
        self.path = path
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.extensionPointIdentifier = extensionPointIdentifier
    }
}

public struct FrameworkSummary: Codable, Sendable, Hashable, Identifiable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let kind: String
    public let isInjectedCodeCandidate: Bool

    public init(path: String, name: String, kind: String, isInjectedCodeCandidate: Bool) {
        self.path = path
        self.name = name
        self.kind = kind
        self.isInjectedCodeCandidate = isInjectedCodeCandidate
    }
}

public struct AppTransportSecuritySummary: Codable, Sendable, Hashable {
    public let allowsArbitraryLoads: Bool
    public let allowsArbitraryLoadsInWebContent: Bool
    public let exceptionDomains: [String]

    public init(
        allowsArbitraryLoads: Bool = false,
        allowsArbitraryLoadsInWebContent: Bool = false,
        exceptionDomains: [String] = []
    ) {
        self.allowsArbitraryLoads = allowsArbitraryLoads
        self.allowsArbitraryLoadsInWebContent = allowsArbitraryLoadsInWebContent
        self.exceptionDomains = exceptionDomains
    }
}

public struct AppBundleSummary: Codable, Sendable, Hashable, Identifiable {
    public var id: String { bundlePath }
    public let bundlePath: String
    public let displayName: String
    public let bundleIdentifier: String?
    public let version: String?
    public let build: String?
    public let minimumOSVersion: String?
    public let executableName: String?
    public let executablePath: String?
    public let iconPath: String?
    public let infoPlistPath: String
    public let permissions: [PermissionUsage]
    public let urlSchemes: [String]
    public let appTransportSecurity: AppTransportSecuritySummary
    public let privacyManifestPaths: [String]
    public let frameworks: [FrameworkSummary]
    public let extensions: [ExtensionSummary]
    public let machO: MachOSummary?

    public init(
        bundlePath: String,
        displayName: String,
        bundleIdentifier: String?,
        version: String?,
        build: String?,
        minimumOSVersion: String?,
        executableName: String?,
        executablePath: String?,
        iconPath: String?,
        infoPlistPath: String,
        permissions: [PermissionUsage],
        urlSchemes: [String],
        appTransportSecurity: AppTransportSecuritySummary,
        privacyManifestPaths: [String],
        frameworks: [FrameworkSummary],
        extensions: [ExtensionSummary],
        machO: MachOSummary?
    ) {
        self.bundlePath = bundlePath
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.build = build
        self.minimumOSVersion = minimumOSVersion
        self.executableName = executableName
        self.executablePath = executablePath
        self.iconPath = iconPath
        self.infoPlistPath = infoPlistPath
        self.permissions = permissions
        self.urlSchemes = urlSchemes
        self.appTransportSecurity = appTransportSecurity
        self.privacyManifestPaths = privacyManifestPaths
        self.frameworks = frameworks
        self.extensions = extensions
        self.machO = machO
    }
}

public struct EntitlementsSummary: Codable, Sendable, Hashable {
    public let values: [String: PlistValue]

    public init(values: [String: PlistValue] = [:]) {
        self.values = values
    }
}

public enum SigningStatus: String, Codable, Sendable, Hashable {
    case valid
    case invalid
    case unsigned
    case unknown
}

public struct CertificateSummary: Codable, Sendable, Hashable, Identifiable {
    public var id: String { sha256 }
    public let subject: String
    public let sha256: String

    public init(subject: String, sha256: String) {
        self.subject = subject
        self.sha256 = sha256
    }
}

public struct ProvisioningSummary: Codable, Sendable, Hashable {
    public let name: String?
    public let uuid: String?
    public let teamIdentifiers: [String]
    public let applicationIdentifier: String?
    public let creationDate: Date?
    public let expirationDate: Date?
    public let distributionKind: String
    public let provisionedDeviceCount: Int
    public let entitlements: EntitlementsSummary

    public init(
        name: String? = nil,
        uuid: String? = nil,
        teamIdentifiers: [String] = [],
        applicationIdentifier: String? = nil,
        creationDate: Date? = nil,
        expirationDate: Date? = nil,
        distributionKind: String = "Unknown",
        provisionedDeviceCount: Int = 0,
        entitlements: EntitlementsSummary = .init()
    ) {
        self.name = name
        self.uuid = uuid
        self.teamIdentifiers = teamIdentifiers
        self.applicationIdentifier = applicationIdentifier
        self.creationDate = creationDate
        self.expirationDate = expirationDate
        self.distributionKind = distributionKind
        self.provisionedDeviceCount = provisionedDeviceCount
        self.entitlements = entitlements
    }
}

public struct SigningSummary: Codable, Sendable, Hashable, Identifiable {
    public var id: String { bundlePath }
    public let bundlePath: String
    public let status: SigningStatus
    public let identifier: String?
    public let teamIdentifier: String?
    public let certificates: [CertificateSummary]
    public let entitlements: EntitlementsSummary
    public let provisioning: ProvisioningSummary?
    public let detail: String?

    public init(
        bundlePath: String,
        status: SigningStatus,
        identifier: String? = nil,
        teamIdentifier: String? = nil,
        certificates: [CertificateSummary] = [],
        entitlements: EntitlementsSummary = .init(),
        provisioning: ProvisioningSummary? = nil,
        detail: String? = nil
    ) {
        self.bundlePath = bundlePath
        self.status = status
        self.identifier = identifier
        self.teamIdentifier = teamIdentifier
        self.certificates = certificates
        self.entitlements = entitlements
        self.provisioning = provisioning
        self.detail = detail
    }
}

public struct MachOSliceSummary: Codable, Sendable, Hashable, Identifiable {
    public var id: String { "\(architecture):\(fileType)" }
    public let architecture: String
    public let fileType: String
    public let is64Bit: Bool
    public let isEncrypted: Bool?
    public let hasCodeSignature: Bool
    public let linkedLibraries: [String]
    public let loadCommands: [String]

    public init(
        architecture: String,
        fileType: String,
        is64Bit: Bool,
        isEncrypted: Bool?,
        hasCodeSignature: Bool,
        linkedLibraries: [String],
        loadCommands: [String]
    ) {
        self.architecture = architecture
        self.fileType = fileType
        self.is64Bit = is64Bit
        self.isEncrypted = isEncrypted
        self.hasCodeSignature = hasCodeSignature
        self.linkedLibraries = linkedLibraries
        self.loadCommands = loadCommands
    }
}

public struct MachOSummary: Codable, Sendable, Hashable {
    public let slices: [MachOSliceSummary]

    public init(slices: [MachOSliceSummary]) {
        self.slices = slices
    }
}

public enum InspectionIssueSeverity: String, Codable, Sendable, Hashable {
    case information
    case warning
    case error
}

public struct InspectionIssue: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let severity: InspectionIssueSeverity
    public let category: String
    public let path: String?
    public let message: String

    public init(
        id: UUID = UUID(),
        severity: InspectionIssueSeverity,
        category: String,
        path: String? = nil,
        message: String
    ) {
        self.id = id
        self.severity = severity
        self.category = category
        self.path = path
        self.message = message
    }
}

public struct IPAPackageSnapshot: Codable, Sendable, Hashable {
    public let schemaVersion: Int
    public let sourceFileName: String
    public let sourceFileSize: Int64
    public let packageSHA256: String?
    public let generatedAt: Date
    public let entries: [IPAEntry]
    public let appBundles: [AppBundleSummary]
    public let signing: [SigningSummary]
    public let issues: [InspectionIssue]
    public let isFullyInspected: Bool

    public init(
        schemaVersion: Int = 1,
        sourceFileName: String,
        sourceFileSize: Int64,
        packageSHA256: String?,
        generatedAt: Date,
        entries: [IPAEntry],
        appBundles: [AppBundleSummary],
        signing: [SigningSummary],
        issues: [InspectionIssue],
        isFullyInspected: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.sourceFileName = sourceFileName
        self.sourceFileSize = sourceFileSize
        self.packageSHA256 = packageSHA256
        self.generatedAt = generatedAt
        self.entries = entries
        self.appBundles = appBundles
        self.signing = signing
        self.issues = issues
        self.isFullyInspected = isFullyInspected
    }
}

public enum InspectionPhase: String, Codable, Sendable, Hashable {
    case indexing
    case hashing
    case metadata
    case signing
    case reporting
    case complete
}

public struct InspectionProgress: Codable, Sendable, Hashable {
    public let phase: InspectionPhase
    public let completed: Int64
    public let total: Int64
    public let message: String

    public init(phase: InspectionPhase, completed: Int64, total: Int64, message: String) {
        self.phase = phase
        self.completed = completed
        self.total = total
        self.message = message
    }

    public var fractionCompleted: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

public struct TextPreview: Codable, Sendable, Hashable {
    public let text: String
    public let syntax: String
    public let isTruncated: Bool
}

public struct ImagePreview: Codable, Sendable, Hashable {
    public let data: Data
    public let typeIdentifier: String?
}

public struct AudioPreview: Codable, Sendable, Hashable {
    public let fileURL: URL
    public let originalFileName: String
    public let fileSize: Int64
    public let typeIdentifier: String?

    public init(fileURL: URL, originalFileName: String, fileSize: Int64, typeIdentifier: String?) {
        self.fileURL = fileURL
        self.originalFileName = originalFileName
        self.fileSize = fileSize
        self.typeIdentifier = typeIdentifier
    }
}

public struct VideoPreview: Codable, Sendable, Hashable {
    public let fileURL: URL
    public let originalFileName: String
    public let fileSize: Int64
    public let typeIdentifier: String?

    public init(fileURL: URL, originalFileName: String, fileSize: Int64, typeIdentifier: String?) {
        self.fileURL = fileURL
        self.originalFileName = originalFileName
        self.fileSize = fileSize
        self.typeIdentifier = typeIdentifier
    }
}

public struct HexPreview: Codable, Sendable, Hashable {
    public let offset: Int64
    public let totalSize: Int64
    public let data: Data
}

public struct DirectoryPreview: Codable, Sendable, Hashable {
    public let path: String
    public let childCount: Int
    public let totalUncompressedSize: Int64
}

public enum PreviewPayload: Codable, Sendable, Hashable {
    case directory(DirectoryPreview)
    case plist(PlistValue)
    case image(ImagePreview)
    case audio(AudioPreview)
    case video(VideoPreview)
    case text(TextPreview)
    case machO(MachOSummary)
    case provisioning(ProvisioningSummary)
    case hex(HexPreview)
    case unavailable(String)
}

public struct SearchResult: Codable, Sendable, Hashable, Identifiable {
    public var id: String { "\(path):\(matchKind):\(snippet ?? "")" }
    public let path: String
    public let matchKind: String
    public let snippet: String?
}

public struct SearchOptions: Codable, Sendable, Hashable {
    public let includeContents: Bool
    public let maximumContentBytes: Int64

    public init(includeContents: Bool = false, maximumContentBytes: Int64 = 5 * 1_024 * 1_024) {
        self.includeContents = includeContents
        self.maximumContentBytes = maximumContentBytes
    }
}

// Reserved stable vocabulary for the future Trust Diff engine.
public enum ChangeKind: String, Codable, Sendable, Hashable {
    case added
    case removed
    case modified
    case moved
    case unchanged
}

public struct EntryChange: Codable, Sendable, Hashable, Identifiable {
    public var id: String { "\(oldPath ?? ""):\(newPath ?? ""):" + kind.rawValue }
    public let kind: ChangeKind
    public let oldPath: String?
    public let newPath: String?
    public let oldSHA256: String?
    public let newSHA256: String?
}

public struct SemanticChange: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let category: String
    public let evidencePath: String?
    public let summary: String

    public init(id: UUID = UUID(), category: String, evidencePath: String?, summary: String) {
        self.id = id
        self.category = category
        self.evidencePath = evidencePath
        self.summary = summary
    }
}

public struct PackageDiff: Codable, Sendable, Hashable {
    public let entries: [EntryChange]
    public let semanticChanges: [SemanticChange]

    public init(entries: [EntryChange] = [], semanticChanges: [SemanticChange] = []) {
        self.entries = entries
        self.semanticChanges = semanticChanges
    }
}

public enum IPAInspectionError: LocalizedError, Sendable {
    case unreadableArchive
    case unsafePath(String)
    case duplicatePath(String)
    case entryLimitExceeded(Int)
    case sizeLimitExceeded(Int64)
    case entryNotFound(String)
    case extractionFailed(String)
    case insufficientDiskSpace(required: Int64, available: Int64)

    public var errorDescription: String? {
        switch self {
        case .unreadableArchive: "IPALens could not read this file as an IPA or ZIP archive."
        case .unsafePath(let path): "IPALens blocked an unsafe archive path: \(path)"
        case .duplicatePath(let path): "The archive contains duplicate paths after macOS normalization: \(path)"
        case .entryLimitExceeded(let count): "The archive contains \(count.formatted()) entries, exceeding IPALens’s 200,000-entry safety limit."
        case .sizeLimitExceeded(let bytes): "The archive declares \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) of uncompressed data, exceeding IPALens’s 20 GiB safety limit."
        case .entryNotFound(let path): "IPALens could not find this archive entry: \(path)"
        case .extractionFailed(let detail): "IPALens could not extract this archive entry: \(detail)"
        case .insufficientDiskSpace(let required, let available):
            "Not enough temporary disk space. IPALens needs \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file)); \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) is available."
        }
    }
}
