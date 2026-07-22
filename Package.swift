// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "IPALens",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "IPALensCore", targets: ["IPALensCore"]),
        .executable(name: "IPALens", targets: ["IPALens"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/weichsel/ZIPFoundation.git",
            exact: "0.9.20"
        )
    ],
    targets: [
        .target(
            name: "IPALensCore",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ]
        ),
        .executableTarget(
            name: "IPALens",
            dependencies: ["IPALensCore"],
            path: "Sources/IPALensApp"
        ),
        .testTarget(
            name: "IPALensCoreTests",
            dependencies: [
                "IPALensCore",
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
