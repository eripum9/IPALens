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
}
