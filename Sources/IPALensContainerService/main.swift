import Darwin
import Foundation
import IPALensContainerBridge

private final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        let service = DiskImageService()
        connection.exportedInterface = NSXPCInterface(with: IPALensDiskImageServiceProtocol.self)
        connection.exportedObject = service
        connection.invalidationHandler = { service.cancelActiveOperation() }
        connection.interruptionHandler = { service.cancelActiveOperation() }
        connection.resume()
        return true
    }
}

private final class DiskImageService: NSObject, IPALensDiskImageServiceProtocol, @unchecked Sendable {
    private let stateLock = NSLock()
    private var activeProcess: Process?
    private var isCancelled = false

    func attachDiskImage(
        atPath imagePath: String,
        mountRootPath: String,
        withReply reply: @escaping @Sendable ([String]?, [String]?, Bool, String?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                resetCancellation()
                let source = URL(fileURLWithPath: imagePath).standardizedFileURL
                let mountRoot = URL(fileURLWithPath: mountRootPath, isDirectory: true).standardizedFileURL
                guard source.pathExtension.lowercased() == "dmg",
                      source.isFileURL,
                      mountRoot.isFileURL,
                      isRegularFileWithoutFollowingLinks(source),
                      isDirectoryWithoutFollowingLinks(mountRoot),
                      isAllowedMountRoot(mountRoot) else {
                    throw ServiceError.invalidRequest
                }

                let encryption = try run(arguments: ["isencrypted", "-plist", source.path], timeout: 20)
                if encryption.status == 0,
                   let plist = try? PropertyListSerialization.propertyList(from: encryption.stdout, format: nil),
                   let dictionary = plist as? [String: Any],
                   dictionary["encrypted"] as? Bool == true {
                    reply(nil, nil, true, nil)
                    return
                }

                let devicesBefore = mountedDevices(forImageAt: source)
                do {
                    let result = try run(
                        arguments: [
                            "attach", "-readonly", "-nobrowse", "-noautoopen", "-noautofsck",
                            "-verify", "-plist", "-mountroot", mountRoot.path, source.path
                        ],
                        timeout: 120
                    )
                    guard result.status == 0 else { throw ServiceError.toolFailed(result.stderrText) }
                    let plist = try PropertyListSerialization.propertyList(from: result.stdout, format: nil)
                    guard let dictionary = plist as? [String: Any],
                          let entities = dictionary["system-entities"] as? [[String: Any]] else {
                        throw ServiceError.invalidResponse
                    }
                    let devices = entities.compactMap { $0["dev-entry"] as? String }
                    let mountPaths = entities.compactMap { $0["mount-point"] as? String }
                    guard !mountPaths.isEmpty else {
                        detach(devices: devices)
                        throw ServiceError.noMountableVolume
                    }
                    if cancelled() {
                        detach(devices: devices)
                        throw CancellationError()
                    }
                    reply(mountPaths, devices, false, nil)
                } catch {
                    let newlyMounted = mountedDevices(forImageAt: source).subtracting(devicesBefore)
                    detach(devices: Array(newlyMounted))
                    throw error
                }
            } catch is CancellationError {
                reply(nil, nil, false, "The disk-image operation was cancelled.")
            } catch {
                reply(nil, nil, false, error.localizedDescription)
            }
        }
    }

    func detachDiskImageDevices(
        _ devices: [String],
        withReply reply: @escaping @Sendable (String?) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async { [self] in
            resetCancellation()
            var failures: [String] = []
            for device in devices.reversed() {
                guard device.hasPrefix("/dev/disk") else { continue }
                do {
                    let result = try run(arguments: ["detach", device], timeout: 20)
                    if result.status != 0 { failures.append(result.stderrText) }
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
            reply(failures.isEmpty ? nil : failures.joined(separator: "\n"))
        }
    }

    func cancelActiveOperation() {
        stateLock.lock()
        isCancelled = true
        let process = activeProcess
        stateLock.unlock()
        terminate(process)
    }

    private func resetCancellation() {
        stateLock.lock()
        isCancelled = false
        stateLock.unlock()
    }

    private func cancelled() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isCancelled
    }

    private func mountedDevices(forImageAt imageURL: URL) -> Set<String> {
        guard let result = try? run(arguments: ["info", "-plist"], timeout: 20),
              result.status == 0,
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

    private func isAllowedMountRoot(_ url: URL) -> Bool {
        let path = url.path
        let containerMarker = "/Library/Containers/com.eripum9.IPALens/Data/tmp/IPALens/Containers/"
        return (path.contains(containerMarker) || path.hasPrefix("/private/var/folders/"))
            && path.hasSuffix("/Mounts")
    }

    private func isRegularFileWithoutFollowingLinks(_ url: URL) -> Bool {
        var information = stat()
        return lstat(url.path, &information) == 0 && (information.st_mode & S_IFMT) == S_IFREG
    }

    private func isDirectoryWithoutFollowingLinks(_ url: URL) -> Bool {
        var information = stat()
        return lstat(url.path, &information) == 0 && (information.st_mode & S_IFMT) == S_IFDIR
    }

    private func detach(devices: [String]) {
        for device in devices.reversed() where device.hasPrefix("/dev/disk") {
            _ = try? run(arguments: ["detach", device], timeout: 20, observesCancellation: false)
        }
    }

    private struct ProcessResult {
        let status: Int32
        let stdout: Data
        let stderr: Data

        var stderrText: String {
            let text = String(decoding: stderr.prefix(64 * 1_024), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "hdiutil exited with status \(status)." : text
        }
    }

    private func run(
        arguments: [String],
        timeout: TimeInterval,
        observesCancellation: Bool = true
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/usr/sbin", "LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice
        let captureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("IPALens-hdiutil-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: captureRoot, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: captureRoot) }
        let outputURL = captureRoot.appendingPathComponent("stdout")
        let errorURL = captureRoot.appendingPathComponent("stderr")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              FileManager.default.createFile(atPath: errorURL.path, contents: nil) else {
            throw ServiceError.captureUnavailable
        }
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
        }
        process.standardOutput = outputHandle
        process.standardError = errorHandle

        stateLock.lock()
        activeProcess = process
        stateLock.unlock()
        defer {
            stateLock.lock()
            if activeProcess === process { activeProcess = nil }
            stateLock.unlock()
        }
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if observesCancellation && cancelled() {
                terminate(process)
                throw CancellationError()
            }
            if Date() >= deadline {
                terminate(process)
                throw ServiceError.timeout
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        try outputHandle.synchronize()
        try errorHandle.synchronize()
        let outputSize = try fileSize(at: outputURL)
        let errorSize = try fileSize(at: errorURL)
        guard outputSize <= 4 * 1_024 * 1_024, errorSize <= 4 * 1_024 * 1_024 else {
            throw ServiceError.excessiveOutput
        }
        let stdout = try Data(contentsOf: outputURL)
        let stderr = try Data(contentsOf: errorURL)
        return ProcessResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    private func fileSize(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }

    private func terminate(_ process: Process?) {
        guard let process, process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}

private enum ServiceError: LocalizedError {
    case invalidRequest
    case invalidResponse
    case noMountableVolume
    case timeout
    case excessiveOutput
    case captureUnavailable
    case toolFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest: "The disk-image request was invalid."
        case .invalidResponse: "hdiutil returned invalid mount information."
        case .noMountableVolume: "The disk image did not expose a mountable volume."
        case .timeout: "The disk-image operation timed out."
        case .excessiveOutput: "hdiutil produced too much diagnostic output."
        case .captureUnavailable: "IPALens could not create bounded diagnostic output files."
        case .toolFailed(let detail): detail
        }
    }
}

private let delegate = ServiceDelegate()
private let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
