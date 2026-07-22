import CryptoKit
import Foundation
import Testing
import ZIPFoundation
@testable import IPALensCore

@Suite("Archive path safety")
struct ArchivePathSafetyTests {
    @Test func normalizesSafePaths() throws {
        #expect(try ArchivePathValidator.normalize("Payload/Test.app/Info.plist") == "Payload/Test.app/Info.plist")
        #expect(ArchivePathValidator.parentPath(of: "Payload/Test.app") == "Payload")
        #expect(ArchivePathValidator.collisionKey(for: "Payload/Test.app") == "payload/test.app")
    }

    @Test(arguments: [
        "/etc/passwd",
        "../outside",
        "Payload/../outside",
        "Payload//Test.app",
        "Payload\\Test.app",
        "~/.ssh/id_rsa",
        "Payload/./Test.app"
    ])
    func rejectsUnsafePaths(_ path: String) {
        #expect(throws: IPAInspectionError.self) {
            try ArchivePathValidator.normalize(path)
        }
    }
}

@Suite("Mach-O parser")
struct MachOParserTests {
    @Test func parsesArm64ExecutableAndLoadCommands() throws {
        let data = FixtureFactory.machO64(linkedLibrary: "@rpath/Injected.dylib")
        let summary = try MachOParser.parse(data: data)
        #expect(summary.slices.count == 1)
        let slice = try #require(summary.slices.first)
        #expect(slice.architecture == "arm64")
        #expect(slice.fileType == "Executable")
        #expect(slice.is64Bit)
        #expect(slice.hasCodeSignature)
        #expect(slice.linkedLibraries == ["@rpath/Injected.dylib"])
    }

    @Test func rejectsTruncatedLoadCommands() {
        var data = FixtureFactory.machO64(linkedLibrary: "@rpath/Injected.dylib")
        data.removeLast(12)
        #expect(throws: MachOParser.ParseError.self) {
            try MachOParser.parse(data: data)
        }
    }
}

@Suite("Inspection engine")
struct InspectionEngineTests {
    @Test func indexesInspectsPreviewsSearchesAndExports() async throws {
        let fixture = try FixtureFactory.makeIPA()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let sourceHashBefore = try SHA256.hash(fileAt: fixture.ipa)
        let engine = IPAInspectionEngine()
        let indexed = try await engine.index(url: fixture.ipa, now: Date(timeIntervalSince1970: 1_000))

        #expect(!indexed.isFullyInspected)
        #expect(indexed.entries.contains { $0.path == "Payload/Demo.app/Info.plist" })
        #expect(indexed.entries.contains { $0.path == "Payload/Demo.app/Frameworks/Injected.dylib" })
        #expect(indexed.entries.contains { $0.path == "Payload/Demo.app/PlugIns/Share.appex/Info.plist" })

        let inspected = try await engine.inspect(
            url: fixture.ipa,
            indexedSnapshot: indexed,
            now: Date(timeIntervalSince1970: 1_000)
        )
        #expect(inspected.isFullyInspected)
        #expect(inspected.packageSHA256 == sourceHashBefore)
        #expect(inspected.entries.filter { $0.kind == .file }.allSatisfy { $0.sha256 != nil })

        let bundle = try #require(inspected.appBundles.first)
        #expect(bundle.displayName == "Demo App")
        #expect(bundle.bundleIdentifier == "com.example.demo")
        #expect(bundle.minimumOSVersion == "16.0")
        #expect(bundle.permissions.map(\.key) == ["NSCameraUsageDescription"])
        #expect(bundle.urlSchemes == ["ipalens-demo"])
        #expect(bundle.frameworks.contains { $0.name == "Injected.dylib" && $0.isInjectedCodeCandidate })
        #expect(bundle.extensions.first?.bundleIdentifier == "com.example.demo.share")
        #expect(bundle.machO?.slices.first?.architecture == "arm64")

        let plistPreview = try await engine.preview(
            url: fixture.ipa,
            entryPath: "Payload/Demo.app/Info.plist"
        )
        guard case .plist(.dictionary(let plist)) = plistPreview else {
            Issue.record("Expected a property-list preview")
            return
        }
        #expect(plist["CFBundleIdentifier"] == .string("com.example.demo"))

        let textPreview = try await engine.preview(
            url: fixture.ipa,
            entryPath: "Payload/Demo.app/readme.txt"
        )
        guard case .text(let text) = textPreview else {
            Issue.record("Expected a text preview")
            return
        }
        #expect(text.text.contains("needle for content search"))

        let audioPreview = try await engine.preview(
            url: fixture.ipa,
            entryPath: "Payload/Demo.app/tone.wav"
        )
        guard case .audio(let audio) = audioPreview else {
            Issue.record("Expected an audio preview")
            return
        }
        #expect(audio.originalFileName == "tone.wav")
        #expect(audio.fileSize == Int64(FixtureFactory.wavSilence().count))
        #expect(try Data(contentsOf: audio.fileURL) == FixtureFactory.wavSilence())
        let materializedAudioURL = audio.fileURL

        let videoPreview = try await engine.preview(
            url: fixture.ipa,
            entryPath: "Payload/Demo.app/clip.mp4"
        )
        guard case .video(let video) = videoPreview else {
            Issue.record("Expected a video preview")
            return
        }
        #expect(video.originalFileName == "clip.mp4")
        #expect(video.fileSize == Int64(FixtureFactory.mp4Stub().count))
        #expect(try Data(contentsOf: video.fileURL) == FixtureFactory.mp4Stub())
        let materializedVideoURL = video.fileURL

        let search = try await engine.search(
            url: fixture.ipa,
            query: "needle",
            options: .init(includeContents: true)
        )
        #expect(search.contains { $0.path.hasSuffix("readme.txt") && $0.matchKind == "Content" })

        let exported = fixture.root.appendingPathComponent("exported-readme.txt")
        let exportHash = try await engine.exportEntry(
            url: fixture.ipa,
            entryPath: "Payload/Demo.app/readme.txt",
            destinationURL: exported
        )
        let exportedHash = try SHA256.hash(fileAt: exported)
        let exportedText = try String(contentsOf: exported, encoding: .utf8)
        #expect(exportHash == exportedHash)
        #expect(exportedText.contains("needle"))

        let sourceHashAfter = try SHA256.hash(fileAt: fixture.ipa)
        #expect(sourceHashBefore == sourceHashAfter)

        let report = InspectionReportV1(snapshot: inspected)
        let json = try String(decoding: report.jsonData(), as: UTF8.self)
        #expect(json.contains("\"schemaVersion\" : 1"))
        #expect(!json.contains(fixture.root.path))
        #expect(report.markdown().contains("# IPALens Inspection Report"))
        #expect(report.markdown().contains("- **Package:** Demo.ipa"))

        await engine.forget(url: fixture.ipa)
        #expect(!FileManager.default.fileExists(atPath: materializedAudioURL.path))
        #expect(!FileManager.default.fileExists(atPath: materializedVideoURL.path))
    }

    @Test func malformedZipFailsWithoutChangingSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Broken.ipa")
        try Data("not a zip".utf8).write(to: file)
        let before = try SHA256.hash(fileAt: file)

        await #expect(throws: (any Error).self) {
            _ = try await IPAInspectionEngine().index(url: file)
        }
        let after = try SHA256.hash(fileAt: file)
        #expect(before == after)
    }

    @Test func removesStaleTemporaryDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("IPALens", isDirectory: true)
        let stale = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)],
            ofItemAtPath: stale.path
        )
        TemporaryDirectoryManager.removeStaleDirectories(olderThan: 1)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }
}

private enum FixtureFactory {
    struct Fixture {
        let root: URL
        let ipa: URL
    }

    static func makeIPA() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let app = source.appendingPathComponent("Payload/Demo.app", isDirectory: true)
        let frameworks = app.appendingPathComponent("Frameworks", isDirectory: true)
        let extensionBundle = app.appendingPathComponent("PlugIns/Share.appex", isDirectory: true)
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: extensionBundle, withIntermediateDirectories: true)

        let info: [String: Any] = [
            "CFBundleDisplayName": "Demo App",
            "CFBundleName": "Demo",
            "CFBundleIdentifier": "com.example.demo",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "42",
            "MinimumOSVersion": "16.0",
            "CFBundleExecutable": "Demo",
            "NSCameraUsageDescription": "Used to scan a demo code.",
            "CFBundleURLTypes": [["CFBundleURLSchemes": ["ipalens-demo"]]],
            "NSAppTransportSecurity": [
                "NSAllowsArbitraryLoads": false,
                "NSExceptionDomains": ["example.com": [:]]
            ]
        ]
        try writePlist(info, to: app.appendingPathComponent("Info.plist"))
        try machO64(linkedLibrary: "@rpath/Injected.dylib").write(to: app.appendingPathComponent("Demo"))
        try machO64(linkedLibrary: "/usr/lib/libSystem.B.dylib").write(to: frameworks.appendingPathComponent("Injected.dylib"))
        try Data("needle for content search\n".utf8).write(to: app.appendingPathComponent("readme.txt"))
        try wavSilence().write(to: app.appendingPathComponent("tone.wav"))
        try mp4Stub().write(to: app.appendingPathComponent("clip.mp4"))
        try writePlist(
            ["NSPrivacyTracking": false, "NSPrivacyCollectedDataTypes": []],
            to: app.appendingPathComponent("PrivacyInfo.xcprivacy")
        )

        let extensionInfo: [String: Any] = [
            "CFBundleDisplayName": "Share",
            "CFBundleIdentifier": "com.example.demo.share",
            "NSExtension": ["NSExtensionPointIdentifier": "com.apple.share-services"]
        ]
        try writePlist(extensionInfo, to: extensionBundle.appendingPathComponent("Info.plist"))

        let ipa = root.appendingPathComponent("Demo.ipa")
        try FileManager.default.zipItem(
            at: source,
            to: ipa,
            shouldKeepParent: false,
            compressionMethod: .deflate
        )
        return Fixture(root: root, ipa: ipa)
    }

    static func writePlist(_ object: Any, to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
        try data.write(to: url)
    }

    static func machO64(linkedLibrary: String) -> Data {
        let pathData = Data(linkedLibrary.utf8) + Data([0])
        let dylibCommandSize = ((24 + pathData.count + 7) / 8) * 8
        let codeSignatureSize = 16
        var data = Data()
        appendUInt32(0xfeedfacf, to: &data)
        appendUInt32(0x0100000c, to: &data)
        appendUInt32(0, to: &data)
        appendUInt32(2, to: &data)
        appendUInt32(2, to: &data)
        appendUInt32(UInt32(dylibCommandSize + codeSignatureSize), to: &data)
        appendUInt32(0, to: &data)
        appendUInt32(0, to: &data)

        appendUInt32(0x0c, to: &data)
        appendUInt32(UInt32(dylibCommandSize), to: &data)
        appendUInt32(24, to: &data)
        appendUInt32(0, to: &data)
        appendUInt32(0, to: &data)
        appendUInt32(0, to: &data)
        data.append(pathData)
        if data.count < 32 + dylibCommandSize {
            data.append(Data(repeating: 0, count: 32 + dylibCommandSize - data.count))
        }

        appendUInt32(0x1d, to: &data)
        appendUInt32(UInt32(codeSignatureSize), to: &data)
        appendUInt32(0, to: &data)
        appendUInt32(0, to: &data)
        return data
    }

    static func wavSilence() -> Data {
        let sampleCount = 800
        var data = Data("RIFF".utf8)
        appendUInt32(UInt32(36 + sampleCount), to: &data)
        data.append(Data("WAVEfmt ".utf8))
        appendUInt32(16, to: &data)
        appendUInt16(1, to: &data)
        appendUInt16(1, to: &data)
        appendUInt32(8_000, to: &data)
        appendUInt32(8_000, to: &data)
        appendUInt16(1, to: &data)
        appendUInt16(8, to: &data)
        data.append(Data("data".utf8))
        appendUInt32(UInt32(sampleCount), to: &data)
        data.append(Data(repeating: 128, count: sampleCount))
        return data
    }

    static func mp4Stub() -> Data {
        var data = Data()
        var boxSize = UInt32(24).bigEndian
        withUnsafeBytes(of: &boxSize) { data.append(contentsOf: $0) }
        data.append(Data("ftypisom".utf8))
        data.append(Data(repeating: 0, count: 4))
        data.append(Data("isommp42".utf8))
        return data
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
