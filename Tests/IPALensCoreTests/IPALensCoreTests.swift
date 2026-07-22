import CryptoKit
import Foundation
import IPALensPluginKit
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

@Suite("Text source detection")
struct TextSourceDetectionTests {
    @Test func recognizesLanguagesAndShebangs() {
        #expect(TextFileSupport.syntax(name: "server.cjs", contents: nil) == "JavaScript")
        #expect(TextFileSupport.syntax(name: "tool.py", contents: nil) == "Python")
        #expect(TextFileSupport.syntax(name: "View.java", contents: nil) == "Java")
        #expect(TextFileSupport.syntax(name: "Feature.swift", contents: nil) == "Swift")
        #expect(TextFileSupport.syntax(name: "Page.html", contents: nil) == "HTML")
        #expect(TextFileSupport.syntax(name: "run", contents: "#!/usr/bin/env node\n") == "JavaScript")
    }

    @Test func decodesUnicodeButRejectsBinaryContent() throws {
        let utf8 = try #require(TextFileSupport.decode(Data("Hello, 世界".utf8), allowLegacyEncoding: false))
        #expect(utf8 == "Hello, 世界")

        var utf16 = Data([0xFF, 0xFE])
        utf16.append(try #require("Hello".data(using: .utf16LittleEndian)))
        #expect(TextFileSupport.decode(utf16, allowLegacyEncoding: false) == "Hello")
        #expect(TextFileSupport.decode(Data([0x00, 0x01, 0x02, 0xFF]), allowLegacyEncoding: false) == nil)
    }
}

@Suite("Inspection engine")
struct InspectionEngineTests {
    @Test func indexesInspectsPreviewsSearchesAndExports() async throws {
        let fixture = try FixtureFactory.makeIPA()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let sourceHashBefore = try SHA256.hash(fileAt: fixture.ipa)
        let engine = PackageInspectionEngine()
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

        let sourcePreviews = [
            ("server.cjs", "JavaScript"),
            ("package.json", "JSON"),
            ("tool.py", "Python"),
            ("Page.html", "HTML"),
            ("View.java", "Java"),
            ("Feature.swift", "Swift"),
            ("run-node", "JavaScript"),
            ("notes.weirdsource", "Plain Text")
        ]
        for (fileName, expectedSyntax) in sourcePreviews {
            let preview = try await engine.preview(
                url: fixture.ipa,
                entryPath: "Payload/Demo.app/\(fileName)"
            )
            guard case .text(let source) = preview else {
                Issue.record("Expected a text preview for \(fileName)")
                continue
            }
            #expect(source.syntax == expectedSyntax)
        }

        let initialLargeSource = try await engine.preview(
            url: fixture.ipa,
            entryPath: "Payload/Demo.app/large.swift",
            textByteLimit: 64
        )
        guard case .text(let initialPage) = initialLargeSource else {
            Issue.record("Expected a paged source preview")
            return
        }
        #expect(initialPage.isTruncated)
        #expect(initialPage.displayedByteCount == 64)
        let expandedLargeSource = try await engine.preview(
            url: fixture.ipa,
            entryPath: "Payload/Demo.app/large.swift",
            textByteLimit: 256
        )
        guard case .text(let expandedPage) = expandedLargeSource else {
            Issue.record("Expected an expanded source preview")
            return
        }
        #expect(expandedPage.displayedByteCount == 256)
        #expect(expandedPage.text.count > initialPage.text.count)

        let binaryPreview = try await engine.preview(
            url: fixture.ipa,
            entryPath: "Payload/Demo.app/blob.weirdsource"
        )
        guard case .hex = binaryPreview else {
            Issue.record("Expected unknown binary content to remain a hex preview")
            return
        }

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

        let m4aPreview = try await engine.preview(
            url: fixture.ipa,
            entryPath: "Payload/Demo.app/tone.m4a"
        )
        guard case .audio(let m4a) = m4aPreview else {
            Issue.record("Expected an M4A audio preview")
            return
        }
        #expect(m4a.originalFileName == "tone.m4a")
        #expect(try Data(contentsOf: m4a.fileURL) == FixtureFactory.mp4Stub())

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
            _ = try await PackageInspectionEngine().index(url: file)
        }
        let after = try SHA256.hash(fileAt: file)
        #expect(before == after)
    }

    @Test func inspectsDirectMacApplicationWithDownloadedPlatformDefinition() async throws {
        let fixture = try FixtureFactory.makeMacApplication()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let infoURL = fixture.app.appendingPathComponent("Contents/Info.plist")
        let infoHashBefore = try SHA256.hash(fileAt: infoURL)
        let engine = PackageInspectionEngine()
        let plugin = FixtureFactory.macOSPlugin()

        let indexed = try await engine.index(url: fixture.app, plugin: plugin)
        #expect(indexed.sourceKind == .applicationBundle)
        #expect(indexed.platform == .macOS)
        #expect(indexed.plugin?.id == PluginManager.macOSPluginID)
        #expect(indexed.entries.contains { $0.path == "DemoMac.app/Contents/Info.plist" })
        #expect(indexed.entries.contains { $0.kind == .symbolicLink })

        let inspected = try await engine.inspect(url: fixture.app, indexedSnapshot: indexed, plugin: plugin)
        let bundle = try #require(inspected.appBundles.first)
        #expect(bundle.displayName == "Demo Mac App")
        #expect(bundle.bundleIdentifier == "com.example.demomac")
        #expect(bundle.minimumOSVersion == "13.0")
        #expect(bundle.frameworks.contains { $0.name == "DemoKit.framework" })
        #expect(bundle.extensions.contains { $0.bundleIdentifier == "com.example.demomac.helper" })
        #expect(inspected.packageSHA256?.isEmpty == false)

        let preview = try await engine.preview(
            url: fixture.app,
            entryPath: "DemoMac.app/Contents/Info.plist"
        )
        guard case .plist(.dictionary(let plist)) = preview else {
            Issue.record("Expected a macOS property-list preview")
            return
        }
        #expect(plist["CFBundleIdentifier"] == .string("com.example.demomac"))
        #expect(try SHA256.hash(fileAt: infoURL) == infoHashBefore)

        let report = InspectionReportV2(snapshot: inspected)
        #expect(report.markdown().contains("- **Platform:** macOS"))
        #expect(String(decoding: try report.jsonData(), as: UTF8.self).contains("\"schemaVersion\" : 2"))
        await engine.forget(url: fixture.app)
    }

    @Test func inspectsMacZIPDiskImageAndInstallerPackageWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["IPALENS_TEST_SYSTEM_CONTAINERS"] == "1" else { return }
        let fixture = try FixtureFactory.makeMacApplication()
        let outputRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("IPALens-ContainerTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            try? FileManager.default.removeItem(at: outputRoot)
        }

        let zip = outputRoot.appendingPathComponent("DemoMac.zip")
        try FileManager.default.zipItem(at: fixture.root, to: zip, shouldKeepParent: false)
        let dmg = outputRoot.appendingPathComponent("DemoMac.dmg")
        try FixtureFactory.runSystemTool(
            "/usr/bin/hdiutil",
            ["create", "-quiet", "-format", "UDZO", "-srcfolder", fixture.root.path, dmg.path]
        )
        let pkg = outputRoot.appendingPathComponent("DemoMac.pkg")
        try FixtureFactory.runSystemTool(
            "/usr/bin/pkgbuild",
            ["--root", fixture.root.path, "--identifier", "com.example.demomac.fixture", "--version", "1.0", pkg.path]
        )

        let plugin = FixtureFactory.macOSPlugin()
        for (source, expectedKind) in [
            (zip, PackageSourceKind.zipArchive),
            (dmg, PackageSourceKind.diskImage),
            (pkg, PackageSourceKind.installerPackage)
        ] {
            let sourceHash = try SHA256.hash(fileAt: source)
            let engine = PackageInspectionEngine()
            let indexed = try await engine.index(url: source, plugin: plugin)
            #expect(indexed.sourceKind == expectedKind)
            let inspected = try await engine.inspect(url: source, indexedSnapshot: indexed, plugin: plugin)
            #expect(inspected.platform == .macOS)
            #expect(inspected.appBundles.contains { $0.bundleIdentifier == "com.example.demomac" })
            #expect(try SHA256.hash(fileAt: source) == sourceHash)
            await engine.forget(url: source)
        }
        #expect(!FixtureFactory.mountedDiskImagePaths().contains(dmg.standardizedFileURL.path))
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

    @Test func sweepsAbandonedContainerSessions() throws {
        let session = FileManager.default.temporaryDirectory
            .appendingPathComponent("IPALens/Containers/PKG-Abandoned-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let state: [String: Any] = ["processIdentifier": Int32.max, "mountedDevices": []]
        let data = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
        try data.write(to: session.appendingPathComponent("Session.json"))

        ContainerPreparer.sweepStaleSessions()
        #expect(!FileManager.default.fileExists(atPath: session.path))
    }
}

private enum FixtureFactory {
    struct Fixture {
        let root: URL
        let ipa: URL
    }

    struct MacFixture {
        let root: URL
        let app: URL
    }

    static func macOSPlugin() -> PluginManifestV1 {
        PluginManifestV1(
            id: PluginManager.macOSPluginID,
            name: "macOS App Support",
            version: "1.0.0",
            publisher: "IPALens Project",
            description: "Adds read-only macOS application inspection.",
            capabilities: [.applicationBundle, .zipArchive, .diskImage, .installerPackage],
            platform: PlatformDefinitionV1(
                platformIdentifier: "macos",
                displayName: "macOS App Support",
                appBundleSuffix: ".app",
                infoPlistRelativePath: "Contents/Info.plist",
                executableDirectory: "Contents/MacOS",
                frameworksDirectories: ["Contents/Frameworks"],
                componentDirectories: ["Contents/PlugIns", "Contents/XPCServices", "Contents/Library/LoginItems"],
                componentSuffixes: [".appex", ".xpc", ".plugin", ".bundle", ".app"],
                minimumSystemVersionKey: "LSMinimumSystemVersion",
                privacyManifestNames: ["PrivacyInfo.xcprivacy"]
            )
        )
    }

    static func makeMacApplication() throws -> MacFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let app = root.appendingPathComponent("DemoMac.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let frameworks = contents.appendingPathComponent("Frameworks", isDirectory: true)
        let framework = frameworks.appendingPathComponent("DemoKit.framework", isDirectory: true)
        let helper = contents.appendingPathComponent("XPCServices/DemoHelper.xpc/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: helper, withIntermediateDirectories: true)

        try writePlist([
            "CFBundleDisplayName": "Demo Mac App",
            "CFBundleName": "DemoMac",
            "CFBundleIdentifier": "com.example.demomac",
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "13.0",
            "CFBundleExecutable": "DemoMac"
        ], to: contents.appendingPathComponent("Info.plist"))
        try machO64(linkedLibrary: "@rpath/DemoKit.framework/DemoKit")
            .write(to: macOS.appendingPathComponent("DemoMac"))
        try Data("framework".utf8).write(to: framework.appendingPathComponent("DemoKit"))
        try writePlist([
            "CFBundleDisplayName": "Demo Helper",
            "CFBundleIdentifier": "com.example.demomac.helper"
        ], to: helper.appendingPathComponent("Info.plist"))
        try FileManager.default.createSymbolicLink(
            at: frameworks.appendingPathComponent("CurrentDemoKit"),
            withDestinationURL: framework
        )
        return MacFixture(root: root, app: app)
    }

    static func runSystemTool(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/usr/sbin", "LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "IPALensTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)]
            )
        }
    }

    static func mountedDiskImagePaths() -> Set<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info", "-plist"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = object as? [String: Any],
              let images = dictionary["images"] as? [[String: Any]] else { return [] }
        return Set(images.compactMap { ($0["image-path"] as? String).map { URL(fileURLWithPath: $0).standardizedFileURL.path } })
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
        try Data("const express = require(\"express\");\n".utf8).write(to: app.appendingPathComponent("server.cjs"))
        try Data("{\"name\":\"ipalens-fixture\",\"private\":true}\n".utf8).write(to: app.appendingPathComponent("package.json"))
        try Data("def inspect_package(path):\n    return path\n".utf8).write(to: app.appendingPathComponent("tool.py"))
        try Data("<html><body><script>const ready = true;</script></body></html>\n".utf8).write(to: app.appendingPathComponent("Page.html"))
        try Data("final class View { String title = \"IPALens\"; }\n".utf8).write(to: app.appendingPathComponent("View.java"))
        try Data("struct Feature { let enabled = true }\n".utf8).write(to: app.appendingPathComponent("Feature.swift"))
        try Data(String(repeating: "let expandedValue = 1\n", count: 100).utf8).write(to: app.appendingPathComponent("large.swift"))
        try Data("#!/usr/bin/env node\nconsole.log(\"IPALens\");\n".utf8).write(to: app.appendingPathComponent("run-node"))
        try Data("readable content with an uncommon extension\n".utf8).write(to: app.appendingPathComponent("notes.weirdsource"))
        try Data([0x00, 0x01, 0x02, 0xFF, 0x10]).write(to: app.appendingPathComponent("blob.weirdsource"))
        try wavSilence().write(to: app.appendingPathComponent("tone.wav"))
        try mp4Stub().write(to: app.appendingPathComponent("tone.m4a"))
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
