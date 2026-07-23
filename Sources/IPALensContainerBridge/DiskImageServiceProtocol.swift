import Foundation

public enum DiskImageServiceConstants {
    public static let serviceName = "com.eripum9.IPALens.ContainerService"
}

@objc(IPALensDiskImageServiceProtocol)
public protocol IPALensDiskImageServiceProtocol {
    func attachDiskImage(
        atPath imagePath: String,
        mountRootPath: String,
        withReply reply: @escaping @Sendable ([String]?, [String]?, Bool, String?) -> Void
    )

    func detachDiskImageDevices(
        _ devices: [String],
        withReply reply: @escaping @Sendable (String?) -> Void
    )

    func startVerifiedPluginComponent(
        atPath executablePath: String,
        expectedSHA256: String,
        arguments: [String],
        environment: [String: String],
        withReply reply: @escaping @Sendable (String?, String?) -> Void
    )

    func pollPluginComponentSession(
        _ sessionIdentifier: String,
        afterOffset: Int,
        withReply reply: @escaping @Sendable (Data?, Int, Bool, Int32, String?) -> Void
    )

    func writePluginComponentSession(
        _ sessionIdentifier: String,
        input: Data,
        withReply reply: @escaping @Sendable (String?) -> Void
    )

    func cancelPluginComponentSession(
        _ sessionIdentifier: String,
        withReply reply: @escaping @Sendable () -> Void
    )
}
