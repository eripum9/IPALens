import CryptoKit
import Foundation
import Security
import ZIPFoundation

public enum ProvisioningProfileParser {
    public static func parse(data: Data) throws -> ProvisioningSummary {
        var decoder: CMSDecoder?
        guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder else {
            throw ParserError.cmsCreationFailed
        }

        guard !data.isEmpty else { throw ParserError.invalidCMS }
        let updateStatus = data.withUnsafeBytes { bytes in
            CMSDecoderUpdateMessage(decoder, bytes.baseAddress!, data.count)
        }
        guard updateStatus == errSecSuccess,
              CMSDecoderFinalizeMessage(decoder) == errSecSuccess else {
            throw ParserError.invalidCMS
        }

        var content: CFData?
        guard CMSDecoderCopyContent(decoder, &content) == errSecSuccess,
              let content else {
            throw ParserError.missingContent
        }

        let object = try PropertyListSerialization.propertyList(
            from: content as Data,
            options: [],
            format: nil
        )
        guard let plist = object as? [String: Any] else {
            throw ParserError.invalidPropertyList
        }
        return summary(from: plist)
    }

    static func summary(from plist: [String: Any]) -> ProvisioningSummary {
        let entitlementsDictionary = plist["Entitlements"] as? [String: Any] ?? [:]
        let entitlements = EntitlementsSummary(values: entitlementsDictionary.mapValues(PlistValue.init(any:)))
        let deviceCount = (plist["ProvisionedDevices"] as? [String])?.count ?? 0
        let provisionsAllDevices = plist["ProvisionsAllDevices"] as? Bool ?? false
        let getTaskAllow = entitlementsDictionary["get-task-allow"] as? Bool ?? false

        let distributionKind: String
        if provisionsAllDevices {
            distributionKind = "Enterprise"
        } else if deviceCount > 0 {
            distributionKind = getTaskAllow ? "Development" : "Ad Hoc"
        } else {
            distributionKind = "App Store"
        }

        return ProvisioningSummary(
            name: plist["Name"] as? String,
            uuid: plist["UUID"] as? String,
            teamIdentifiers: plist["TeamIdentifier"] as? [String] ?? [],
            applicationIdentifier: entitlementsDictionary["application-identifier"] as? String,
            creationDate: plist["CreationDate"] as? Date,
            expirationDate: plist["ExpirationDate"] as? Date,
            distributionKind: distributionKind,
            provisionedDeviceCount: deviceCount,
            entitlements: entitlements
        )
    }

    public enum ParserError: LocalizedError, Sendable {
        case cmsCreationFailed
        case invalidCMS
        case missingContent
        case invalidPropertyList

        public var errorDescription: String? {
            switch self {
            case .cmsCreationFailed: "IPALens could not start the provisioning-profile decoder."
            case .invalidCMS: "The provisioning profile is not valid CMS data."
            case .missingContent: "The provisioning profile does not contain an embedded payload."
            case .invalidPropertyList: "The provisioning profile payload is not a valid property list."
            }
        }
    }
}

enum CodeSigningInspector {
    static func inspect(bundleURL: URL, bundlePath: String, provisioning: ProvisioningSummary?) -> SigningSummary {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            return SigningSummary(
                bundlePath: bundlePath,
                status: createStatus == errSecCSUnsigned ? .unsigned : .unknown,
                provisioning: provisioning,
                detail: SecCopyErrorMessageString(createStatus, nil) as String?
            )
        }

        var information: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        )

        let info = information as? [CFString: Any] ?? [:]
        let entitlementsDictionary = info[kSecCodeInfoEntitlementsDict] as? [String: Any] ?? [:]
        let entitlements = EntitlementsSummary(values: entitlementsDictionary.mapValues(PlistValue.init(any:)))

        let certificates: [CertificateSummary]
        if let values = info[kSecCodeInfoCertificates] as? [SecCertificate] {
            certificates = values.map { certificate in
                let subject = SecCertificateCopySubjectSummary(certificate) as String? ?? "Unknown certificate"
                let digest = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).hexString
                return CertificateSummary(subject: subject, sha256: digest)
            }
        } else {
            certificates = []
        }

        let validityFlags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        var validationError: Unmanaged<CFError>?
        let validityStatus = SecStaticCodeCheckValidityWithErrors(
            staticCode,
            validityFlags,
            nil,
            &validationError
        )
        let errorDetail = validationError?.takeRetainedValue().localizedDescription

        let status: SigningStatus
        if infoStatus == errSecCSUnsigned || validityStatus == errSecCSUnsigned {
            status = .unsigned
        } else if validityStatus == errSecSuccess {
            status = .valid
        } else {
            status = .invalid
        }

        return SigningSummary(
            bundlePath: bundlePath,
            status: status,
            identifier: info[kSecCodeInfoIdentifier] as? String,
            teamIdentifier: info[kSecCodeInfoTeamIdentifier] as? String,
            certificates: certificates,
            entitlements: entitlements,
            provisioning: provisioning,
            detail: errorDetail ?? (infoStatus == errSecSuccess ? nil : SecCopyErrorMessageString(infoStatus, nil) as String?)
        )
    }
}

enum BundleMaterializer {
    static func withMaterializedBundle<T>(
        archiveURL: URL,
        index: ArchiveIndex,
        bundlePath: String,
        body: (URL) throws -> T
    ) throws -> T {
        let requiredBytes = index.entries
            .filter { $0.path == bundlePath || $0.path.hasPrefix(bundlePath + "/") }
            .reduce(Int64(0)) { $0 + $1.uncompressedSize }
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("IPALens", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        let available = try FileManager.default.temporaryDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage ?? Int64.max
        let requiredWithReserve = requiredBytes + ArchiveSafetyLimits.minimumFreeSpaceReserve
        guard available >= requiredWithReserve else {
            throw IPAInspectionError.insufficientDiskSpace(required: requiredWithReserve, available: available)
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let archive = try Archive(url: archiveURL, accessMode: .read)

        let subtree = index.entries.filter { $0.path == bundlePath || $0.path.hasPrefix(bundlePath + "/") }
        for entry in subtree {
            try Task.checkCancellation()
            let destination = temporaryRoot.appendingPathComponent(entry.path)
            switch entry.kind {
            case .directory:
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            case .symbolicLink:
                continue
            case .file:
                guard let archivePath = index.archivePaths[entry.path],
                      let archiveEntry = archive[archivePath] else {
                    continue
                }
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                _ = try archive.extract(archiveEntry, to: destination)
            }
        }

        return try body(temporaryRoot.appendingPathComponent(bundlePath))
    }
}

public enum TemporaryDirectoryManager {
    public static func removeStaleDirectories(olderThan age: TimeInterval = 24 * 60 * 60) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("IPALens", isDirectory: true)
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for child in children {
            let modified = try? child.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if modified == nil || modified! < cutoff {
                try? FileManager.default.removeItem(at: child)
            }
        }
    }
}
