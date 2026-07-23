import CryptoKit
import Foundation

public enum PluginCapability: String, Codable, CaseIterable, Sendable, Hashable {
    case applicationBundle
    case zipArchive
    case diskImage
    case installerPackage
    case iOSPersonalTeamSigning
    case usbDeviceManagement
    case xcodeManagement
    case appleDeveloperAccount

    public var displayName: String {
        switch self {
        case .applicationBundle: "Application bundles"
        case .zipArchive: "ZIP archives"
        case .diskImage: "Disk images"
        case .installerPackage: "Installer packages"
        case .iOSPersonalTeamSigning: "Personal Team signing"
        case .usbDeviceManagement: "USB device management"
        case .xcodeManagement: "Xcode management"
        case .appleDeveloperAccount: "Apple Developer account"
        }
    }
}

public enum PluginKind: String, Codable, Sendable, Hashable {
    case platformDefinition
    case privilegedExtension
}

public enum PluginComponentRole: String, Codable, Sendable, Hashable {
    case signingService
    case xcodeInstallerTool
}

public struct PluginComponentV1: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let role: PluginComponentRole
    public let relativePath: String
    public let sha256: String
    public let architectures: [String]
    public let minimumMacOS: String
    public let allowedCommands: [String]

    public init(
        id: String,
        role: PluginComponentRole,
        relativePath: String,
        sha256: String,
        architectures: [String],
        minimumMacOS: String,
        allowedCommands: [String]
    ) {
        self.id = id
        self.role = role
        self.relativePath = relativePath
        self.sha256 = sha256
        self.architectures = architectures
        self.minimumMacOS = minimumMacOS
        self.allowedCommands = allowedCommands
    }
}

public enum PluginTrust: String, Codable, Sendable, Hashable {
    case builtIn
    case official
    case thirdParty
    case localSigned
    case localUnsigned
}

public struct PluginSource: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public let name: String
    public let catalogURL: URL
    public let trust: PluginTrust
    public let publicKey: String
    public let keyFingerprint: String

    public init(
        id: UUID = UUID(),
        name: String,
        catalogURL: URL,
        trust: PluginTrust,
        publicKey: String,
        keyFingerprint: String? = nil
    ) {
        self.id = id
        self.name = name
        self.catalogURL = catalogURL
        self.trust = trust
        self.publicKey = publicKey
        self.keyFingerprint = keyFingerprint ?? Self.fingerprint(forBase64Key: publicKey)
    }

    public static func fingerprint(forBase64Key value: String) -> String {
        guard let data = Data(base64Encoded: value) else { return "Invalid key" }
        return SHA256.hash(data: data).map { String(format: "%02X", $0) }
            .joined()
            .splitEvery(4)
            .joined(separator: " ")
    }
}

public struct PlatformDefinitionV1: Codable, Sendable, Hashable {
    public let platformIdentifier: String
    public let displayName: String
    public let appBundleSuffix: String
    public let infoPlistRelativePath: String
    public let executableDirectory: String
    public let frameworksDirectories: [String]
    public let componentDirectories: [String]
    public let componentSuffixes: [String]
    public let minimumSystemVersionKey: String
    public let privacyManifestNames: [String]

    public init(
        platformIdentifier: String,
        displayName: String,
        appBundleSuffix: String,
        infoPlistRelativePath: String,
        executableDirectory: String,
        frameworksDirectories: [String],
        componentDirectories: [String],
        componentSuffixes: [String],
        minimumSystemVersionKey: String,
        privacyManifestNames: [String]
    ) {
        self.platformIdentifier = platformIdentifier
        self.displayName = displayName
        self.appBundleSuffix = appBundleSuffix
        self.infoPlistRelativePath = infoPlistRelativePath
        self.executableDirectory = executableDirectory
        self.frameworksDirectories = frameworksDirectories
        self.componentDirectories = componentDirectories
        self.componentSuffixes = componentSuffixes
        self.minimumSystemVersionKey = minimumSystemVersionKey
        self.privacyManifestNames = privacyManifestNames
    }

    public static let iOS = PlatformDefinitionV1(
        platformIdentifier: "ios",
        displayName: "iOS App Support",
        appBundleSuffix: ".app",
        infoPlistRelativePath: "Info.plist",
        executableDirectory: "",
        frameworksDirectories: ["Frameworks"],
        componentDirectories: ["PlugIns"],
        componentSuffixes: [".appex"],
        minimumSystemVersionKey: "MinimumOSVersion",
        privacyManifestNames: ["PrivacyInfo.xcprivacy"]
    )
}

public struct PluginManifestV1: Codable, Sendable, Hashable, Identifiable {
    public let schemaVersion: Int
    public let id: String
    public let name: String
    public let version: String
    public let publisher: String
    public let description: String
    public let hostAPIVersion: Int
    public let capabilities: [PluginCapability]
    public let kind: PluginKind?
    public let platform: PlatformDefinitionV1?
    public let components: [PluginComponentV1]?

    public var resolvedKind: PluginKind { kind ?? .platformDefinition }
    public var resolvedComponents: [PluginComponentV1] { components ?? [] }

    public init(
        schemaVersion: Int = 1,
        id: String,
        name: String,
        version: String,
        publisher: String,
        description: String,
        hostAPIVersion: Int = 1,
        capabilities: [PluginCapability],
        kind: PluginKind = .platformDefinition,
        platform: PlatformDefinitionV1? = nil,
        components: [PluginComponentV1] = []
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.version = version
        self.publisher = publisher
        self.description = description
        self.hostAPIVersion = hostAPIVersion
        self.capabilities = capabilities
        self.kind = kind
        self.platform = platform
        self.components = components
    }
}

public struct PluginCatalogEntry: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let version: String
    public let publisher: String
    public let description: String
    public let hostAPIVersion: Int
    public let capabilities: [PluginCapability]
    public let downloadSize: Int64
    public let artifactURL: URL
    public let sha256: String
    public let signature: String

    public init(
        id: String,
        name: String,
        version: String,
        publisher: String,
        description: String,
        hostAPIVersion: Int,
        capabilities: [PluginCapability],
        downloadSize: Int64,
        artifactURL: URL,
        sha256: String,
        signature: String
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.publisher = publisher
        self.description = description
        self.hostAPIVersion = hostAPIVersion
        self.capabilities = capabilities
        self.downloadSize = downloadSize
        self.artifactURL = artifactURL
        self.sha256 = sha256
        self.signature = signature
    }
}

public struct PluginCatalogPayloadV1: Codable, Sendable, Hashable {
    public let schemaVersion: Int
    public let publisher: String
    public let plugins: [PluginCatalogEntry]

    public init(schemaVersion: Int = 1, publisher: String, plugins: [PluginCatalogEntry]) {
        self.schemaVersion = schemaVersion
        self.publisher = publisher
        self.plugins = plugins
    }
}

public struct PluginCatalogEnvelopeV1: Codable, Sendable, Hashable {
    public let schemaVersion: Int
    public let keyID: String
    public let publisherPublicKey: String?
    public let payload: String
    public let signature: String

    public init(
        schemaVersion: Int = 1,
        keyID: String,
        publisherPublicKey: String?,
        payload: String,
        signature: String
    ) {
        self.schemaVersion = schemaVersion
        self.keyID = keyID
        self.publisherPublicKey = publisherPublicKey
        self.payload = payload
        self.signature = signature
    }
}

public struct PluginCatalog: Sendable, Hashable {
    public let source: PluginSource
    public let payload: PluginCatalogPayloadV1

    public init(source: PluginSource, payload: PluginCatalogPayloadV1) {
        self.source = source
        self.payload = payload
    }
}

public struct PluginInstallation: Identifiable, Codable, Sendable, Hashable {
    public var id: String { manifest.id }
    public let manifest: PluginManifestV1
    public let trust: PluginTrust
    public let sourceName: String
    public let installedAt: Date
    public let installationURL: URL

    public init(
        manifest: PluginManifestV1,
        trust: PluginTrust,
        sourceName: String,
        installedAt: Date,
        installationURL: URL
    ) {
        self.manifest = manifest
        self.trust = trust
        self.sourceName = sourceName
        self.installedAt = installedAt
        self.installationURL = installationURL
    }
}

public enum PluginPermissionKind: String, Codable, CaseIterable, Sendable, Hashable {
    case userSelectedFiles
    case applicationBundles
    case archives
    case diskImages
    case installerPackages
    case providerNetwork
    case systemCommand
    case executableCode
    case keychain
    case usbDevices
    case appleDeveloperAccount
    case xcodeInstallation

    public var symbolName: String {
        switch self {
        case .userSelectedFiles: "folder.fill"
        case .applicationBundles: "app.fill"
        case .archives: "archivebox.fill"
        case .diskImages: "externaldrive.fill"
        case .installerPackages: "shippingbox.fill"
        case .providerNetwork: "network"
        case .systemCommand: "terminal.fill"
        case .executableCode: "cpu.fill"
        case .keychain: "key.fill"
        case .usbDevices: "cable.connector"
        case .appleDeveloperAccount: "person.crop.circle.badge.checkmark"
        case .xcodeInstallation: "hammer.fill"
        }
    }
}

public struct PluginPermission: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public let kind: PluginPermissionKind
    public let title: String
    public let explanation: String
    public let evidence: String

    public init(
        id: String,
        kind: PluginPermissionKind,
        title: String,
        explanation: String,
        evidence: String
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.explanation = explanation
        self.evidence = evidence
    }
}

public struct PluginPackageDetails: Codable, Sendable, Hashable {
    public static let missingReadmeText = "No description was provided."

    public let manifest: PluginManifestV1
    public let readme: String
    public let hasReadme: Bool
    public let permissions: [PluginPermission]
    public let resourcePaths: [String]

    public init(
        manifest: PluginManifestV1,
        readme: String,
        hasReadme: Bool,
        permissions: [PluginPermission],
        resourcePaths: [String]
    ) {
        self.manifest = manifest
        self.readme = readme
        self.hasReadme = hasReadme
        self.permissions = permissions
        self.resourcePaths = resourcePaths
    }
}

public struct PluginSourceCandidate: Sendable, Hashable {
    public let name: String
    public let catalogURL: URL
    public let publicKey: String
    public let keyFingerprint: String
    public let payload: PluginCatalogPayloadV1
}

public enum PluginError: LocalizedError, Sendable {
    case invalidURL
    case privateNetworkURL
    case catalogTooLarge
    case invalidEnvelope
    case invalidSignature
    case untrustedPublisher
    case incompatibleHostAPI(Int)
    case pluginTooLarge
    case invalidPackage(String)
    case hashMismatch
    case pluginNotFound
    case pluginInUse
    case downloadFailed(String)
    case executablePluginRequiresOfficialSource
    case componentVerificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "The plugin source must use a valid HTTPS URL without embedded credentials."
        case .privateNetworkURL: "Plugin sources on localhost or private networks are not allowed."
        case .catalogTooLarge: "The plugin catalog exceeds the 1 MiB safety limit."
        case .invalidEnvelope: "The plugin catalog has an invalid signed-envelope format."
        case .invalidSignature: "The plugin signature could not be verified."
        case .untrustedPublisher: "The plugin publisher key is not trusted for this source."
        case .incompatibleHostAPI(let version): "This plugin requires unsupported host API version \(version)."
        case .pluginTooLarge: "The plugin package exceeds the 50 MiB safety limit."
        case .invalidPackage(let detail): "The plugin package is invalid: \(detail)"
        case .hashMismatch: "The downloaded plugin does not match the catalog SHA-256."
        case .pluginNotFound: "The requested plugin is not available."
        case .pluginInUse: "Close packages using this plugin before removing it."
        case .downloadFailed(let detail): "The plugin download failed: \(detail)"
        case .executablePluginRequiresOfficialSource: "Executable extensions can only be installed from the verified IPALens official catalog."
        case .componentVerificationFailed(let path): "The executable plugin component failed verification: \(path)"
        }
    }
}

private extension String {
    func splitEvery(_ length: Int) -> [String] {
        guard length > 0 else { return [self] }
        return stride(from: 0, to: count, by: length).map { offset in
            let start = index(startIndex, offsetBy: offset)
            let end = index(start, offsetBy: min(length, count - offset))
            return String(self[start..<end])
        }
    }
}
