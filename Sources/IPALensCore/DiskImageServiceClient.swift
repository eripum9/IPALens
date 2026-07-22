import Foundation
import IPALensContainerBridge

struct DiskImageMountResponse: Sendable {
    let mountPaths: [String]
    let devices: [String]
}

enum DiskImageServiceClient {
    static var embeddedServiceIsAvailable: Bool {
        FileManager.default.fileExists(atPath: embeddedServiceURL.path)
    }

    static func attach(imageURL: URL, mountRoot: URL) throws -> DiskImageMountResponse {
        let connection = makeConnection()
        let state = ReplyState()
        let semaphore = DispatchSemaphore(value: 0)
        let finish: @Sendable (Result<DiskImageMountResponse, Error>) -> Void = { result in
            if state.finish(result) { semaphore.signal() }
        }
        connection.interruptionHandler = {
            finish(.failure(DiskImageClientError.connectionInterrupted))
        }
        connection.invalidationHandler = {
            finish(.failure(DiskImageClientError.connectionInvalidated))
        }
        connection.resume()
        defer { connection.invalidate() }

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            finish(.failure(error))
        }) as? IPALensDiskImageServiceProtocol else {
            throw DiskImageClientError.serviceUnavailable
        }
        // The helper is deliberately outside App Sandbox. Passing the host's app-scoped
        // bookmark across a differently identified, ad-hoc-signed XPC service makes the
        // bookmark unresolvable; the original user-selected path is sufficient here.
        proxy.attachDiskImage(
            atPath: imageURL.path,
            mountRootPath: mountRoot.path
        ) { mountPaths, devices, encrypted, errorMessage in
            if encrypted {
                finish(.failure(IPAInspectionError.encryptedDiskImageUnsupported))
            } else if let errorMessage {
                finish(.failure(IPAInspectionError.containerToolFailed("hdiutil", errorMessage)))
            } else if let mountPaths, let devices {
                finish(.success(.init(mountPaths: mountPaths, devices: devices)))
            } else {
                finish(.failure(DiskImageClientError.invalidResponse))
            }
        }

        let deadline = Date().addingTimeInterval(130)
        while semaphore.wait(timeout: .now() + .milliseconds(100)) == .timedOut {
            if Task.isCancelled {
                connection.invalidate()
                throw CancellationError()
            }
            if Date() >= deadline {
                connection.invalidate()
                throw DiskImageClientError.timeout
            }
        }
        guard let result = state.resolvedResult() else { throw DiskImageClientError.invalidResponse }
        return try result.get()
    }

    static func detach(devices: [String]) {
        guard !devices.isEmpty else { return }
        let connection = makeConnection()
        let semaphore = DispatchSemaphore(value: 0)
        connection.resume()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            semaphore.signal()
        }) as? IPALensDiskImageServiceProtocol else {
            connection.invalidate()
            return
        }
        proxy.detachDiskImageDevices(devices) { _ in semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + 25)
        connection.invalidate()
    }

    private static var embeddedServiceURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/XPCServices", isDirectory: true)
            .appendingPathComponent("IPALensContainerService.xpc", isDirectory: true)
    }

    private static func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(serviceName: DiskImageServiceConstants.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: IPALensDiskImageServiceProtocol.self)
        return connection
    }
}

private final class ReplyState: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<DiskImageMountResponse, Error>?

    func finish(_ result: Result<DiskImageMountResponse, Error>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard self.result == nil else { return false }
        self.result = result
        return true
    }

    func resolvedResult() -> Result<DiskImageMountResponse, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

private enum DiskImageClientError: LocalizedError {
    case serviceUnavailable
    case connectionInterrupted
    case connectionInvalidated
    case invalidResponse
    case timeout

    var errorDescription: String? {
        switch self {
        case .serviceUnavailable: "IPALens could not start its disk-image service."
        case .connectionInterrupted: "The disk-image service was interrupted."
        case .connectionInvalidated: "The disk-image service connection closed unexpectedly."
        case .invalidResponse: "The disk-image service returned an invalid response."
        case .timeout: "The disk-image service timed out."
        }
    }
}
