// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "IPALens",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "IPALensContainerBridge", targets: ["IPALensContainerBridge"]),
        .library(name: "IPALensPluginKit", targets: ["IPALensPluginKit"]),
        .library(name: "IPALensCore", targets: ["IPALensCore"]),
        .executable(name: "IPALens", targets: ["IPALens"]),
        .executable(name: "IPALensContainerService", targets: ["IPALensContainerService"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/weichsel/ZIPFoundation.git",
            exact: "0.9.20"
        )
    ],
    targets: [
        .target(name: "IPALensContainerBridge"),
        .target(
            name: "IPALensPluginKit",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ]
        ),
        .target(
            name: "IPALensCore",
            dependencies: [
                "IPALensContainerBridge",
                "IPALensPluginKit",
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ]
        ),
        .executableTarget(
            name: "IPALens",
            dependencies: ["IPALensCore", "IPALensPluginKit"],
            path: "Sources/IPALensApp"
        ),
        .executableTarget(
            name: "IPALensContainerService",
            dependencies: ["IPALensContainerBridge"]
        ),
        .testTarget(
            name: "IPALensCoreTests",
            dependencies: [
                "IPALensCore",
                "IPALensPluginKit",
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ]
        ),
        .testTarget(
            name: "IPALensPluginKitTests",
            dependencies: [
                "IPALensPluginKit",
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
