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
        await #expect(throws: PluginError.self) {
            try await manager.removePlugin(id: installation.id)
        }
        await manager.endUsing(pluginID: installation.id)
        try await manager.removePlugin(id: installation.id)
        #expect(try await manager.installedPlugin(id: installation.id) == nil)
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
