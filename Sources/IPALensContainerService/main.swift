import Darwin
import CryptoKit
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
    private let pluginSessionsLock = NSLock()
    private var pluginSessions: [String: PluginProcessSession] = [:]

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

    func startVerifiedPluginComponent(
        atPath executablePath: String,
        expectedSHA256: String,
        arguments: [String],
        environment: [String: String],
        withReply reply: @escaping @Sendable (String?, String?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                let executable = URL(fileURLWithPath: executablePath).standardizedFileURL
                try verifySigningComponent(at: executable, expectedSHA256: expectedSHA256)
                guard arguments.count <= 64,
                      arguments.allSatisfy({ $0.utf8.count <= 16 * 1_024 }),
                      Set(environment.keys).isSubset(of: ["IPALENS_APPLE_ID", "IPALENS_APPLE_PASSWORD"]) else {
                    throw ServiceError.invalidPluginRequest
                }
                let identifier = UUID().uuidString
                let session = try PluginProcessSession(
                    executable: executable,
                    arguments: arguments,
                    additionalEnvironment: environment
                )
                pluginSessionsLock.lock()
                pluginSessions[identifier] = session
                pluginSessionsLock.unlock()
                reply(identifier, nil)
            } catch {
                reply(nil, error.localizedDescription)
            }
        }
    }

    func pollPluginComponentSession(
        _ sessionIdentifier: String,
        afterOffset: Int,
        withReply reply: @escaping @Sendable (Data?, Int, Bool, Int32, String?) -> Void
    ) {
        pluginSessionsLock.lock()
        let session = pluginSessions[sessionIdentifier]
        pluginSessionsLock.unlock()
        guard let session else {
            reply(nil, afterOffset, true, -1, "The extension session is no longer available.")
            return
        }
        let snapshot = session.snapshot(afterOffset: afterOffset)
        reply(snapshot.data, snapshot.nextOffset, snapshot.finished, snapshot.status, snapshot.error)
        if snapshot.finished {
            pluginSessionsLock.lock()
            pluginSessions.removeValue(forKey: sessionIdentifier)
            pluginSessionsLock.unlock()
        }
    }

    func writePluginComponentSession(
        _ sessionIdentifier: String,
        input: Data,
        withReply reply: @escaping @Sendable (String?) -> Void
    ) {
        pluginSessionsLock.lock()
        let session = pluginSessions[sessionIdentifier]
        pluginSessionsLock.unlock()
        guard input.count <= 16 * 1_024, let session else {
            reply("The extension session is unavailable or the response is too large.")
            return
        }
        do {
            try session.write(input)
            reply(nil)
        } catch {
            reply(error.localizedDescription)
        }
    }

    func cancelPluginComponentSession(
        _ sessionIdentifier: String,
        withReply reply: @escaping @Sendable () -> Void
    ) {
        pluginSessionsLock.lock()
        let session = pluginSessions.removeValue(forKey: sessionIdentifier)
        pluginSessionsLock.unlock()
        session?.cancel()
        reply()
    }

    func cancelActiveOperation() {
        stateLock.lock()
        isCancelled = true
        let process = activeProcess
        stateLock.unlock()
        terminate(process)
        pluginSessionsLock.lock()
        let sessions = Array(pluginSessions.values)
        pluginSessions.removeAll()
        pluginSessionsLock.unlock()
        sessions.forEach { $0.cancel() }
    }

    private func verifySigningComponent(at url: URL, expectedSHA256: String) throws {
        let expectedSuffix = "/com.eripum9.ipalens.extension.signing/1.0.0/Components/IPALensSigningExtension"
        guard url.path.hasSuffix(expectedSuffix),
              url.path.contains("/Library/Application Support/IPALens/Plugins/"),
              expectedSHA256.count == 64,
              expectedSHA256.allSatisfy({ $0.isHexDigit }) else {
            throw ServiceError.invalidPluginRequest
        }
        var information = stat()
        guard lstat(url.path, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG,
              information.st_uid == getuid(),
              information.st_size > 0,
              information.st_size <= 40 * 1_024 * 1_024 else {
            throw ServiceError.invalidPluginRequest
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expectedSHA256.lowercased() else { throw ServiceError.pluginVerificationFailed }
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

private final class PluginProcessSession: @unchecked Sendable {
    struct Snapshot {
        let data: Data
        let nextOffset: Int
        let finished: Bool
        let status: Int32
        let error: String?
    }

    private static let maximumOutputBytes = 16 * 1_024 * 1_024
    private let lock = NSLock()
    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private var output = Data()
    private var finished = false
    private var terminationStatus: Int32 = 0
    private var errorMessage: String?

    init(executable: URL, arguments: [String], additionalEnvironment: [String: String]) throws {
        process.executableURL = executable
        process.arguments = arguments
        var environment = ["PATH": "/usr/bin:/usr/sbin:/bin:/sbin", "LC_ALL": "C", "TERM": "dumb"]
        let inherited = ProcessInfo.processInfo.environment
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "SSH_AUTH_SOCK"] {
            if let value = inherited[key] { environment[key] = value }
        }
        environment.merge(additionalEnvironment) { _, new in new }
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.append(data)
        }
        process.terminationHandler = { [weak self] process in
            self?.markFinished(status: process.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }
    }

    func snapshot(afterOffset offset: Int) -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        let safeOffset = max(0, min(offset, output.count))
        let data = output.subdata(in: safeOffset..<output.count)
        return Snapshot(
            data: data,
            nextOffset: output.count,
            finished: finished,
            status: terminationStatus,
            error: errorMessage
        )
    }

    func write(_ data: Data) throws {
        lock.lock()
        let canWrite = !finished
        lock.unlock()
        guard canWrite else { throw ServiceError.pluginSessionFinished }
        var line = data
        if line.last != 0x0A { line.append(0x0A) }
        try inputPipe.fileHandleForWriting.write(contentsOf: line)
    }

    func cancel() {
        outputPipe.fileHandleForReading.readabilityHandler = nil
        try? inputPipe.fileHandleForWriting.close()
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }

    private func append(_ data: Data) {
        var shouldCancel = false
        lock.lock()
        if output.count + data.count > Self.maximumOutputBytes {
            errorMessage = "The extension produced more than 16 MiB of diagnostic output."
            shouldCancel = true
        } else {
            output.append(data)
        }
        lock.unlock()
        if shouldCancel { cancel() }
    }

    private func markFinished(status: Int32) {
        let remaining = outputPipe.fileHandleForReading.readDataToEndOfFile()
        lock.lock()
        if output.count + remaining.count <= Self.maximumOutputBytes { output.append(remaining) }
        finished = true
        terminationStatus = status
        lock.unlock()
        outputPipe.fileHandleForReading.readabilityHandler = nil
        try? inputPipe.fileHandleForWriting.close()
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
    case invalidPluginRequest
    case pluginVerificationFailed
    case pluginSessionFinished

    var errorDescription: String? {
        switch self {
        case .invalidRequest: "The disk-image request was invalid."
        case .invalidResponse: "hdiutil returned invalid mount information."
        case .noMountableVolume: "The disk image did not expose a mountable volume."
        case .timeout: "The disk-image operation timed out."
        case .excessiveOutput: "hdiutil produced too much diagnostic output."
        case .captureUnavailable: "IPALens could not create bounded diagnostic output files."
        case .toolFailed(let detail): detail
        case .invalidPluginRequest: "The executable extension request was invalid."
        case .pluginVerificationFailed: "The executable extension no longer matches its signed component hash."
        case .pluginSessionFinished: "The executable extension session has already finished."
        }
    }
}

private let delegate = ServiceDelegate()
private let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
