import Darwin
import Foundation
import IPALensPluginKit

struct PreparedPackageSource: Sendable {
    let index: ArchiveIndex
    let sourceKind: PackageSourceKind
    let platform: PlatformIdentifier
    let definition: PlatformDefinitionV1
    let plugin: PluginReference?
    let temporaryRoot: URL?
    let mountedDevices: [String]
}

enum ContainerPreparer {
    static func sweepStaleSessions() {
        let fileManager = FileManager.default
        let root = containersRoot
        guard let sessions = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for sessionURL in sessions {
            let stateURL = sessionURL.appendingPathComponent("Session.json")
            if let data = try? Data(contentsOf: stateURL),
               let state = try? JSONDecoder().decode(ContainerSessionState.self, from: data) {
                guard state.processIdentifier != getpid(), !isProcessRunning(state.processIdentifier) else { continue }
                for device in state.mountedDevices.reversed() {
                    detach(device: device)
                }
                try? fileManager.removeItem(at: sessionURL)
            } else if let modified = try? sessionURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      modified < Date().addingTimeInterval(-24 * 60 * 60) {
                try? fileManager.removeItem(at: sessionURL)
            }
        }
    }

    static func prepare(url: URL, plugin: PluginManifestV1?) throws -> PreparedPackageSource {
        let fileExtension = url.pathExtension.lowercased()
        if fileExtension == "ipa" {
            return PreparedPackageSource(
                index: try ArchiveIndexer.build(url: url),
                sourceKind: .ipaArchive,
                platform: .iOS,
                definition: .iOS,
                plugin: nil,
                temporaryRoot: nil,
                mountedDevices: []
            )
        }

        guard let plugin,
              plugin.id == PluginManager.macOSPluginID,
              plugin.platform.platformIdentifier == PlatformIdentifier.macOS.rawValue else {
            throw IPAInspectionError.requiredPluginMissing(PluginManager.macOSPluginID)
        }
        let reference = PluginReference(id: plugin.id, version: plugin.version)

        switch fileExtension {
        case "zip":
            return PreparedPackageSource(
                index: try ArchiveIndexer.build(url: url),
                sourceKind: .zipArchive,
                platform: .macOS,
                definition: plugin.platform,
                plugin: reference,
                temporaryRoot: nil,
                mountedDevices: []
            )
        case "app":
            return PreparedPackageSource(
                index: try DirectoryIndexer.build(roots: [(url.lastPathComponent, url)]),
                sourceKind: .applicationBundle,
                platform: .macOS,
                definition: plugin.platform,
                plugin: reference,
                temporaryRoot: nil,
                mountedDevices: []
            )
        case "dmg":
            return try prepareDiskImage(url: url, plugin: plugin, reference: reference)
        case "pkg", "mpkg":
            return try prepareInstallerPackage(url: url, plugin: plugin, reference: reference)
        default:
            throw IPAInspectionError.unsupportedSourceType(fileExtension)
        }
    }

    static func cleanup(_ source: PreparedPackageSource) {
        for device in source.mountedDevices.reversed() {
            detach(device: device)
        }
        if let temporaryRoot = source.temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    private static func prepareDiskImage(
        url: URL,
        plugin: PluginManifestV1,
        reference: PluginReference
    ) throws -> PreparedPackageSource {
        let encryptionResult = try run(
            executable: URL(fileURLWithPath: "/usr/bin/hdiutil"),
            arguments: ["isencrypted", "-plist", url.path],
            timeout: 20
        )
        if encryptionResult.status == 0,
           let plist = try? PropertyListSerialization.propertyList(from: encryptionResult.stdout, format: nil),
           let dictionary = plist as? [String: Any],
           dictionary["encrypted"] as? Bool == true {
            throw IPAInspectionError.encryptedDiskImageUnsupported
        }

        let temporaryRoot = try makeTemporaryRoot(prefix: "DMG")
        let mountRoot = temporaryRoot.appendingPathComponent("Mounts", isDirectory: true)
        try FileManager.default.createDirectory(at: mountRoot, withIntermediateDirectories: true)
        var attachedDevices: [String] = []
        let devicesBeforeAttach = mountedDevices(forImageAt: url)
        do {
            let result = try run(
                executable: URL(fileURLWithPath: "/usr/bin/hdiutil"),
                arguments: [
                    "attach", "-readonly", "-nobrowse", "-noautoopen", "-noautofsck",
                    "-verify", "-plist", "-mountroot", mountRoot.path, url.path
                ],
                timeout: 120
            )
            guard result.status == 0 else {
                throw IPAInspectionError.containerToolFailed("hdiutil", result.stderrText)
            }
            let plist = try PropertyListSerialization.propertyList(from: result.stdout, format: nil)
            guard let dictionary = plist as? [String: Any],
                  let entities = dictionary["system-entities"] as? [[String: Any]] else {
                throw IPAInspectionError.containerToolFailed("hdiutil", "The mount response was not valid property-list data.")
            }
            let devices = entities.compactMap { $0["dev-entry"] as? String }
            attachedDevices = devices
            try updateSession(at: temporaryRoot, mountedDevices: devices)
            let mountPaths = entities.compactMap { $0["mount-point"] as? String }
            guard !mountPaths.isEmpty else {
                for device in devices.reversed() {
                    detach(device: device)
                }
                throw IPAInspectionError.containerToolFailed("hdiutil", "The disk image did not expose a mountable volume.")
            }
            let roots = mountPaths.enumerated().map { offset, path in
                let volumeURL = URL(fileURLWithPath: path, isDirectory: true)
                let baseName = volumeURL.lastPathComponent.isEmpty ? "Volume" : volumeURL.lastPathComponent
                let logicalName = mountPaths.count == 1 ? baseName : "\(baseName)-\(offset + 1)"
                return (logicalName, volumeURL)
            }
            return PreparedPackageSource(
                index: try DirectoryIndexer.build(roots: roots),
                sourceKind: .diskImage,
                platform: .macOS,
                definition: plugin.platform,
                plugin: reference,
                temporaryRoot: temporaryRoot,
                mountedDevices: devices
            )
        } catch {
            let newlyMounted = mountedDevices(forImageAt: url).subtracting(devicesBeforeAttach)
            for device in Set(attachedDevices).union(newlyMounted).sorted().reversed() {
                detach(device: device)
            }
            try? FileManager.default.removeItem(at: temporaryRoot)
            throw error
        }
    }

    private static func prepareInstallerPackage(
        url: URL,
        plugin: PluginManifestV1,
        reference: PluginReference
    ) throws -> PreparedPackageSource {
        let sourceSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let available = try FileManager.default.temporaryDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage ?? Int64.max
        let required = min(
            ArchiveSafetyLimits.maximumUncompressedSize,
            max(sourceSize * 3, sourceSize + ArchiveSafetyLimits.minimumFreeSpaceReserve)
        )
        guard available >= required else {
            throw IPAInspectionError.insufficientDiskSpace(required: required, available: available)
        }

        let temporaryRoot = try makeTemporaryRoot(prefix: "PKG")
        let expanded = temporaryRoot.appendingPathComponent("Expanded", isDirectory: true)
        do {
            let result = try run(
                executable: URL(fileURLWithPath: "/usr/sbin/pkgutil"),
                arguments: ["--expand-full", url.path, expanded.path],
                timeout: 300,
                monitor: { try auditExpandingDirectory(expanded) }
            )
            guard result.status == 0 else {
                throw IPAInspectionError.containerToolFailed("pkgutil", result.stderrText)
            }
            return PreparedPackageSource(
                index: try DirectoryIndexer.build(roots: [(url.deletingPathExtension().lastPathComponent, expanded)]),
                sourceKind: .installerPackage,
                platform: .macOS,
                definition: plugin.platform,
                plugin: reference,
                temporaryRoot: temporaryRoot,
                mountedDevices: []
            )
        } catch {
            try? FileManager.default.removeItem(at: temporaryRoot)
            throw error
        }
    }

    private static func makeTemporaryRoot(prefix: String) throws -> URL {
        let root = containersRoot.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try updateSession(at: root, mountedDevices: [])
        return root
    }

    private static var containersRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("IPALens/Containers", isDirectory: true)
    }

    private struct ContainerSessionState: Codable {
        let processIdentifier: Int32
        let mountedDevices: [String]
    }

    private static func updateSession(at root: URL, mountedDevices: [String]) throws {
        let state = ContainerSessionState(processIdentifier: getpid(), mountedDevices: mountedDevices)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: root.appendingPathComponent("Session.json"), options: .atomic)
    }

    private static func isProcessRunning(_ processIdentifier: Int32) -> Bool {
        guard processIdentifier > 0 else { return false }
        return kill(processIdentifier, 0) == 0 || errno == EPERM
    }

    private static func mountedDevices(forImageAt imageURL: URL) -> Set<String> {
        guard let result = try? run(
            executable: URL(fileURLWithPath: "/usr/bin/hdiutil"),
            arguments: ["info", "-plist"],
            timeout: 20,
            observesCancellation: false
        ), result.status == 0,
        let plist = try? PropertyListSerialization.propertyList(from: result.stdout, format: nil),
        let dictionary = plist as? [String: Any],
        let images = dictionary["images"] as? [[String: Any]] else { return [] }
        let expectedPath = imageURL.standardizedFileURL.path
        for image in images {
            guard let path = image["image-path"] as? String,
                  URL(fileURLWithPath: path).standardizedFileURL.path == expectedPath,
                  let entities = image["system-entities"] as? [[String: Any]] else { continue }
            return Set(entities.compactMap { $0["dev-entry"] as? String })
        }
        return []
    }

    private static func detach(device: String) {
        _ = try? run(
            executable: URL(fileURLWithPath: "/usr/bin/hdiutil"),
            arguments: ["detach", device],
            timeout: 20,
            observesCancellation: false
        )
    }

    private static func auditExpandingDirectory(_ root: URL) throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        var entryCount = 0
        var totalSize: Int64 = 0
        while let value = enumerator.nextObject() as? URL {
            entryCount += 1
            guard entryCount <= ArchiveSafetyLimits.maximumEntryCount else {
                throw IPAInspectionError.entryLimitExceeded(entryCount)
            }
            let properties = try value.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            if properties.isSymbolicLink == true {
                enumerator.skipDescendants()
            } else if properties.isRegularFile == true {
                let (next, overflow) = totalSize.addingReportingOverflow(Int64(properties.fileSize ?? 0))
                guard !overflow, next <= ArchiveSafetyLimits.maximumUncompressedSize else {
                    throw IPAInspectionError.sizeLimitExceeded(overflow ? .max : next)
                }
                totalSize = next
            }
        }
        let available = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage ?? Int64.max
        guard available >= ArchiveSafetyLimits.minimumFreeSpaceReserve else {
            throw IPAInspectionError.insufficientDiskSpace(
                required: ArchiveSafetyLimits.minimumFreeSpaceReserve,
                available: available
            )
        }
    }

    private struct ProcessResult {
        let status: Int32
        let stdout: Data
        let stderr: Data
        var stderrText: String {
            let value = String(decoding: stderr.prefix(64 * 1_024), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? "The system tool exited with status \(status)." : value
        }
    }

    private static func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        monitor: (() throws -> Void)? = nil,
        observesCancellation: Bool = true
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/usr/sbin", "LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("IPALens-Process-\(UUID().uuidString).stdout")
        let errorURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("IPALens-Process-\(UUID().uuidString).stderr")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              FileManager.default.createFile(atPath: errorURL.path, contents: nil) else {
            throw IPAInspectionError.containerToolFailed(executable.lastPathComponent, "Temporary output files could not be created.")
        }
        let standardOutput = try FileHandle(forWritingTo: outputURL)
        let standardError = try FileHandle(forWritingTo: errorURL)
        defer {
            try? standardOutput.close()
            try? standardError.close()
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
        }
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        var nextMonitor = Date()
        while process.isRunning {
            if observesCancellation && Task.isCancelled {
                terminate(process)
                throw CancellationError()
            }
            if Date() >= deadline {
                terminate(process)
                throw IPAInspectionError.containerToolFailed(executable.lastPathComponent, "The operation timed out.")
            }
            if Date() >= nextMonitor {
                do {
                    try monitor?()
                    let outputSize = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    let errorSize = (try? errorURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    guard outputSize <= 4 * 1_024 * 1_024, errorSize <= 4 * 1_024 * 1_024 else {
                        throw IPAInspectionError.containerToolFailed(executable.lastPathComponent, "The system tool produced too much output.")
                    }
                } catch {
                    terminate(process)
                    throw error
                }
                nextMonitor = Date().addingTimeInterval(0.5)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        try standardOutput.close()
        try standardError.close()
        let output = try Data(contentsOf: outputURL)
        let errors = try Data(contentsOf: errorURL)
        guard output.count <= 4 * 1_024 * 1_024, errors.count <= 4 * 1_024 * 1_024 else {
            throw IPAInspectionError.containerToolFailed(executable.lastPathComponent, "The system tool produced too much output.")
        }
        return ProcessResult(status: process.terminationStatus, stdout: output, stderr: errors)
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}
