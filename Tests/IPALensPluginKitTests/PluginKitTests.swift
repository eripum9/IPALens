import CryptoKit
import Foundation
import Testing
import ZIPFoundation
@testable import IPALensPluginKit

@Suite("Plugin trust and validation")
struct PluginKitTests {
    @Test func verifiesSignedCatalogEnvelope() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let payload = PluginCatalogPayloadV1(schemaVersion: 1, publisher: "Test Publisher", plugins: [])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payloadData = try encoder.encode(payload)
        let signature = try privateKey.signature(for: payloadData)
        let envelope = PluginCatalogEnvelopeV1(
            schemaVersion: 1,
            keyID: "test",
            publisherPublicKey: privateKey.publicKey.rawRepresentation.base64EncodedString(),
            payload: payloadData.base64EncodedString(),
            signature: signature.base64EncodedString()
        )

        let decoded = try PluginManager.verifyEnvelope(
            envelope,
            publicKey: privateKey.publicKey.rawRepresentation.base64EncodedString()
        )
        #expect(decoded.publisher == "Test Publisher")
    }

    @Test func rejectsModifiedCatalogPayload() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let payloadData = Data("{}".utf8)
        let signature = try privateKey.signature(for: payloadData)
        let envelope = PluginCatalogEnvelopeV1(
            schemaVersion: 1,
            keyID: "test",
            publisherPublicKey: privateKey.publicKey.rawRepresentation.base64EncodedString(),
            payload: Data("{\"changed\":true}".utf8).base64EncodedString(),
            signature: signature.base64EncodedString()
        )

        #expect(throws: PluginError.self) {
            _ = try PluginManager.verifyEnvelope(
                envelope,
                publicKey: privateKey.publicKey.rawRepresentation.base64EncodedString()
            )
        }
    }

    @Test(arguments: [
        "http://example.com/catalog.json",
        "https://localhost/catalog.json",
        "https://127.0.0.1/catalog.json",
        "https://192.168.1.20/catalog.json",
        "https://[::1]/catalog.json",
        "https://[fd00::1]/catalog.json",
        "https://user:password@example.com/catalog.json"
    ])
    func rejectsUnsafeCatalogURLs(_ value: String) throws {
        let url = try #require(URL(string: value))
        #expect(throws: PluginError.self) {
            try PluginManager.validateRemoteURL(url)
        }
    }

    @Test func acceptsPublicHTTPSCatalogURL() throws {
        let url = try #require(URL(string: "https://plugins.example.com/catalog.json"))
        try PluginManager.validateRemoteURL(url)
    }

    @Test func rejectsThirdPartyKeyChangesAfterTrustOnFirstUse() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IPALens-SourceTrustTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = PluginManager(storageRoot: root)
        let catalogURL = try #require(URL(string: "https://plugins.example.com/catalog-v1.json"))
        let firstKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let changedKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let payload = PluginCatalogPayloadV1(publisher: "Test Publisher", plugins: [])
        let first = PluginSourceCandidate(
            name: "Test Publisher",
            catalogURL: catalogURL,
            publicKey: firstKey,
            keyFingerprint: PluginSource.fingerprint(forBase64Key: firstKey),
            payload: payload
        )
        _ = try await manager.trustThirdPartySource(first)
        let changed = PluginSourceCandidate(
            name: "Test Publisher",
            catalogURL: catalogURL,
            publicKey: changedKey,
            keyFingerprint: PluginSource.fingerprint(forBase64Key: changedKey),
            payload: payload
        )
        await #expect(throws: PluginError.self) {
            _ = try await manager.trustThirdPartySource(changed)
        }
    }

    @Test func rejectsUnknownManifestFields() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IPALens-PluginTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        var manifest = validManifestObject()
        manifest["unexpectedExecutableHook"] = "run-me"
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try data.write(to: source.appendingPathComponent("Plugin.json"))
        let package = root.appendingPathComponent("UnknownField.ipalensplugin")
        try FileManager.default.zipItem(at: source, to: package, shouldKeepParent: false)

        let manager = PluginManager(storageRoot: root.appendingPathComponent("Installed", isDirectory: true))
        await #expect(throws: PluginError.self) {
            _ = try await manager.importLocalPackage(url: package, allowUnsigned: false)
        }
        do {
            _ = try await manager.importLocalPackage(url: package, allowUnsigned: true)
            Issue.record("A manifest with an unknown field was accepted.")
        } catch let error as PluginError {
            guard case .invalidPackage = error else {
                Issue.record("Unexpected validation error: \(error.localizedDescription)")
                return
            }
        }
    }

    @Test func rejectsExecutableComponentsFromLocalPackages() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IPALens-ExecutablePluginTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source", isDirectory: true)
        let components = source.appendingPathComponent("Components", isDirectory: true)
        try FileManager.default.createDirectory(at: components, withIntermediateDirectories: true)
        let componentData = Data("not-an-executable".utf8)
        try componentData.write(to: components.appendingPathComponent("TestComponent"))
        let componentHash = SHA256.hash(data: componentData)
            .map { String(format: "%02x", $0) }
            .joined()
        let manifest: [String: Any] = [
            "schemaVersion": 2,
            "kind": "privilegedExtension",
            "id": "com.example.ipalens.executable",
            "name": "Executable Test",
            "version": "1.0.0",
            "publisher": "Untrusted Publisher",
            "description": "Must not be accepted from a local source.",
            "hostAPIVersion": 2,
            "capabilities": ["usbDeviceManagement"],
            "components": [[
                "id": "test-component",
                "role": "signingService",
                "relativePath": "Components/TestComponent",
                "sha256": componentHash,
                "architectures": ["arm64", "x86_64"],
                "minimumMacOS": "13.0",
                "allowedCommands": ["/usr/bin/codesign"]
            ]]
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: source.appendingPathComponent("Plugin.json"))
        let package = root.appendingPathComponent("Executable.ipalensplugin")
        try FileManager.default.zipItem(at: source, to: package, shouldKeepParent: false)

        let manager = PluginManager(storageRoot: root.appendingPathComponent("Installed", isDirectory: true))
        await #expect(throws: PluginError.self) {
            _ = try await manager.importLocalPackage(url: package, allowUnsigned: true)
        }
    }

    @Test func verifiesAndInstallsOfficialExecutableComponents() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IPALens-OfficialExecutableTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDirectory = root.appendingPathComponent("Source", isDirectory: true)
        let componentDirectory = sourceDirectory.appendingPathComponent("Components", isDirectory: true)
        try FileManager.default.createDirectory(at: componentDirectory, withIntermediateDirectories: true)
        let componentData = Data("verified-component-fixture".utf8)
        try componentData.write(to: componentDirectory.appendingPathComponent("Fixture"))
        let componentHash = SHA256.hash(data: componentData).map { String(format: "%02x", $0) }.joined()
        let manifest: [String: Any] = [
            "schemaVersion": 2,
            "kind": "privilegedExtension",
            "id": "com.example.ipalens.official-executable",
            "name": "Official Executable Test",
            "version": "1.0.0",
            "publisher": "Test Publisher",
            "description": "Verified executable test package.",
            "hostAPIVersion": 2,
            "capabilities": ["iOSPersonalTeamSigning", "usbDeviceManagement"],
            "components": [[
                "id": "fixture",
                "role": "signingService",
                "relativePath": "Components/Fixture",
                "sha256": componentHash,
                "architectures": ["arm64", "x86_64"],
                "minimumMacOS": "13.0",
                "allowedCommands": ["/usr/bin/codesign", "/usr/bin/xcrun"]
            ]]
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: sourceDirectory.appendingPathComponent("Plugin.json"))
        try Data("# Official Executable Test\n".utf8).write(to: sourceDirectory.appendingPathComponent("README.md"))
        let packageURL = root.appendingPathComponent("Official.ipalensplugin")
        try FileManager.default.zipItem(at: sourceDirectory, to: packageURL, shouldKeepParent: false)
        let packageData = try Data(contentsOf: packageURL)
        let privateKey = Curve25519.Signing.PrivateKey()
        let entry = PluginCatalogEntry(
            id: "com.example.ipalens.official-executable",
            name: "Official Executable Test",
            version: "1.0.0",
            publisher: "Test Publisher",
            description: "Verified executable test package.",
            hostAPIVersion: 2,
            capabilities: [.iOSPersonalTeamSigning, .usbDeviceManagement],
            downloadSize: Int64(packageData.count),
            artifactURL: try #require(URL(string: "https://plugins.example.com/official.ipalensplugin")),
            sha256: SHA256.hash(data: packageData).map { String(format: "%02x", $0) }.joined(),
            signature: try privateKey.signature(for: packageData).base64EncodedString()
        )
        PluginFixtureURLProtocol.responseData = packageData
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PluginFixtureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let manager = PluginManager(storageRoot: root.appendingPathComponent("Installed", isDirectory: true), session: session)
        let pluginSource = PluginSource(
            name: "Fixture Official Source",
            catalogURL: try #require(URL(string: "https://plugins.example.com/catalog.json")),
            trust: .official,
            publicKey: privateKey.publicKey.rawRepresentation.base64EncodedString()
        )

        let details = try await manager.packageDetails(entry: entry, from: pluginSource)
        #expect(details.manifest.resolvedKind == .privilegedExtension)
        #expect(details.permissions.contains { $0.kind == .executableCode })
        #expect(details.permissions.contains { $0.kind == .usbDevices })
        let installation = try await manager.install(entry: entry, from: pluginSource)
        let componentURL = installation.installationURL.appendingPathComponent("Components/Fixture")
        #expect(try Data(contentsOf: componentURL) == componentData)
        let attributes = try FileManager.default.attributesOfItem(atPath: componentURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o500)
    }

    @Test func installsOfficialPluginInIsolatedStorageWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["IPALENS_TEST_OFFICIAL_CATALOG"] == "1" else { return }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IPALens-OfficialGrabberTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = PluginManager(storageRoot: root)
        let source = try await manager.officialSource()
        let catalog = try await manager.fetchCatalog(from: source)
        let entry = try #require(catalog.payload.plugins.first { $0.id == PluginManager.macOSPluginID })
        let installation = try await manager.install(entry: entry, from: source)

        #expect(installation.manifest.version == "1.0.0")
        #expect(installation.trust == .official)
        #expect(FileManager.default.fileExists(
            atPath: installation.installationURL.appendingPathComponent("Plugin.json").path
        ))
        #expect(try await manager.installedPlugin(id: PluginManager.macOSPluginID) != nil)
        try await manager.removePlugin(id: PluginManager.macOSPluginID)
        #expect(try await manager.installedPlugin(id: PluginManager.macOSPluginID) == nil)

        let signingEntry = try #require(catalog.payload.plugins.first { $0.id == PluginManager.signingPluginID })
        let details = try await manager.packageDetails(entry: signingEntry, from: source)
        #expect(details.manifest.resolvedKind == .privilegedExtension)
        #expect(details.permissions.contains { $0.kind == .xcodeInstallation })
        let signingInstallation = try await manager.install(entry: signingEntry, from: source)
        #expect(signingInstallation.trust == .official)
        #expect(signingInstallation.manifest.resolvedComponents.count == 2)
        for component in signingInstallation.manifest.resolvedComponents {
            #expect(FileManager.default.isExecutableFile(
                atPath: signingInstallation.installationURL.appendingPathComponent(component.relativePath).path
            ))
        }
        try await manager.removePlugin(id: PluginManager.signingPluginID)
        #expect(try await manager.installedPlugin(id: PluginManager.signingPluginID) == nil)
    }

    @Test func preventsRemovalWhileAPluginVersionIsInUse() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IPALens-InUsePluginTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let manifestData = try JSONSerialization.data(withJSONObject: validManifestObject(), options: [.sortedKeys])
        try manifestData.write(to: source.appendingPathComponent("Plugin.json"))
        let package = root.appendingPathComponent("Valid.ipalensplugin")
        try FileManager.default.zipItem(at: source, to: package, shouldKeepParent: false)
        let manager = PluginManager(storageRoot: root.appendingPathComponent("Installed", isDirectory: true))
        let installation = try await manager.importLocalPackage(url: package, allowUnsigned: true)

        await manager.beginUsing(pluginID: installation.id)
        await manager.beginUsing(pluginID: installation.id)
        await #expect(throws: PluginError.self) {
            try await manager.removePlugin(id: installation.id)
        }
        await manager.endUsing(pluginID: installation.id)
        await #expect(throws: PluginError.self) {
            try await manager.removePlugin(id: installation.id)
        }
        await manager.endUsing(pluginID: installation.id)
        try await manager.removePlugin(id: installation.id)
        #expect(try await manager.installedPlugin(id: installation.id) == nil)
    }

    @Test func readsStorefrontReadmeAndScansPermissionEvidence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IPALens-PluginDetailsTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        var manifest = validManifestObject()
        manifest["capabilities"] = ["applicationBundle", "diskImage", "installerPackage"]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: source.appendingPathComponent("Plugin.json"))
        try Data("# Test Plugin\n\nUses `/usr/bin/codesign` for documented verification.\n".utf8)
            .write(to: source.appendingPathComponent("README.md"))
        let package = root.appendingPathComponent("Details.ipalensplugin")
        try FileManager.default.zipItem(at: source, to: package, shouldKeepParent: false)

        let manager = PluginManager(storageRoot: root.appendingPathComponent("Installed", isDirectory: true))
        let installation = try await manager.importLocalPackage(url: package, allowUnsigned: true)
        let details = try await manager.packageDetails(for: installation)

        #expect(details.hasReadme)
        #expect(details.readme.contains("Test Plugin"))
        #expect(details.permissions.contains { $0.kind == .diskImages })
        #expect(details.permissions.contains { $0.evidence.contains("/usr/bin/hdiutil") })
        #expect(details.permissions.contains { $0.evidence.contains("/usr/sbin/pkgutil") })
        #expect(details.permissions.contains { $0.evidence.contains("/usr/bin/codesign") })
    }

    @Test func displaysFallbackWhenReadmeIsMissing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IPALens-MissingReadmeTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: validManifestObject(), options: [.sortedKeys])
            .write(to: source.appendingPathComponent("Plugin.json"))
        let package = root.appendingPathComponent("MissingReadme.ipalensplugin")
        try FileManager.default.zipItem(at: source, to: package, shouldKeepParent: false)

        let manager = PluginManager(storageRoot: root.appendingPathComponent("Installed", isDirectory: true))
        let installation = try await manager.importLocalPackage(url: package, allowUnsigned: true)
        let details = try await manager.packageDetails(for: installation)

        #expect(!details.hasReadme)
        #expect(details.readme == PluginPackageDetails.missingReadmeText)
    }

    private func validManifestObject() -> [String: Any] {
        [
            "schemaVersion": 1,
            "id": "com.example.ipalens.test",
            "name": "Test Platform",
            "version": "1.0.0",
            "publisher": "Test Publisher",
            "description": "Test data-only plugin.",
            "hostAPIVersion": 1,
            "capabilities": ["applicationBundle"],
            "platform": [
                "platformIdentifier": "test",
                "displayName": "Test",
                "appBundleSuffix": ".app",
                "infoPlistRelativePath": "Contents/Info.plist",
                "executableDirectory": "Contents/MacOS",
                "frameworksDirectories": ["Contents/Frameworks"],
                "componentDirectories": ["Contents/PlugIns"],
                "componentSuffixes": [".appex"],
                "minimumSystemVersionKey": "LSMinimumSystemVersion",
                "privacyManifestNames": ["PrivacyInfo.xcprivacy"]
            ]
        ]
    }
}

private final class PluginFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseData = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(Self.responseData.count)]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
