import Foundation
import IPALensContainerBridge
import IPALensPluginKit

struct PluginComponentPoll: Sendable {
    let data: Data
    let nextOffset: Int
    let finished: Bool
    let status: Int32
    let errorMessage: String?
}

final class PluginComponentSession: @unchecked Sendable {
    private let connection: NSXPCConnection
    private let identifier: String
    private var offset = 0
    private let lock = NSLock()
    private var invalidated = false

    private init(connection: NSXPCConnection, identifier: String) {
        self.connection = connection
        self.identifier = identifier
    }

    static func start(
        installation: PluginInstallation,
        component: PluginComponentV1,
        arguments: [String],
        environment: [String: String] = [:]
    ) async throws -> PluginComponentSession {
        guard installation.trust == .official,
              installation.manifest.resolvedKind == .privilegedExtension,
              installation.manifest.id == PluginManager.signingPluginID,
              installation.manifest.resolvedComponents.contains(component) else {
            throw PluginComponentError.untrustedComponent
        }
        let executable = installation.installationURL
            .appendingPathComponent(component.relativePath)
            .standardizedFileURL
        let connection = NSXPCConnection(serviceName: DiskImageServiceConstants.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: IPALensDiskImageServiceProtocol.self)
        connection.resume()
        do {
            let identifier: String = try await withCheckedThrowingContinuation { continuation in
                let gate = ContinuationGate<String>(continuation)
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                    gate.resume(throwing: error)
                }) as? IPALensDiskImageServiceProtocol else {
                    gate.resume(throwing: PluginComponentError.serviceUnavailable)
                    return
                }
                proxy.startVerifiedPluginComponent(
                    atPath: executable.path,
                    expectedSHA256: component.sha256,
                    arguments: arguments,
                    environment: environment
                ) { identifier, errorMessage in
                    if let identifier {
                        gate.resume(returning: identifier)
                    } else {
                        gate.resume(throwing: PluginComponentError.componentFailed(errorMessage ?? "The extension could not start."))
                    }
                }
            }
            return PluginComponentSession(connection: connection, identifier: identifier)
        } catch {
            connection.invalidate()
            throw error
        }
    }

    func poll() async throws -> PluginComponentPoll {
        let requestedOffset = lock.withLock { offset }
        let value: PluginComponentPoll = try await withCheckedThrowingContinuation { continuation in
            let gate = ContinuationGate<PluginComponentPoll>(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                gate.resume(throwing: error)
            }) as? IPALensDiskImageServiceProtocol else {
                gate.resume(throwing: PluginComponentError.serviceUnavailable)
                return
            }
            proxy.pollPluginComponentSession(identifier, afterOffset: requestedOffset) {
                data, nextOffset, finished, status, errorMessage in
                gate.resume(returning: PluginComponentPoll(
                    data: data ?? Data(),
                    nextOffset: nextOffset,
                    finished: finished,
                    status: status,
                    errorMessage: errorMessage
                ))
            }
        }
        lock.withLock { offset = value.nextOffset }
        if value.finished { invalidate() }
        return value
    }

    func write(_ value: String) async throws {
        let data = Data(value.utf8)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ContinuationGate<Void>(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                gate.resume(throwing: error)
            }) as? IPALensDiskImageServiceProtocol else {
                gate.resume(throwing: PluginComponentError.serviceUnavailable)
                return
            }
            proxy.writePluginComponentSession(identifier, input: data) { errorMessage in
                if let errorMessage {
                    gate.resume(throwing: PluginComponentError.componentFailed(errorMessage))
                } else {
                    gate.resume(returning: ())
                }
            }
        }
    }

    func cancel() async {
        guard !lock.withLock({ invalidated }) else { return }
        await withCheckedContinuation { continuation in
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                continuation.resume()
            }) as? IPALensDiskImageServiceProtocol else {
                continuation.resume()
                return
            }
            proxy.cancelPluginComponentSession(identifier) { continuation.resume() }
        }
        invalidate()
    }

    private func invalidate() {
        let shouldInvalidate = lock.withLock {
            if invalidated { return false }
            invalidated = true
            return true
        }
        if shouldInvalidate { connection.invalidate() }
    }

    deinit { connection.invalidate() }
}

private final class ContinuationGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: sending Value) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }
}

private enum PluginComponentError: LocalizedError {
    case serviceUnavailable
    case untrustedComponent
    case componentFailed(String)

    var errorDescription: String? {
        switch self {
        case .serviceUnavailable: "IPALens could not start its executable-extension service."
        case .untrustedComponent: "Only verified executable components from the official IPALens catalog may run."
        case .componentFailed(let detail): detail
        }
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}
