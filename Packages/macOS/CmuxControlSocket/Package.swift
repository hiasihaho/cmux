// swift-tools-version: 6.0

import PackageDescription
import Foundation

// Off-macOS the CryptoKit call sites build against swift-crypto instead.
let onDarwin = ProcessInfo.processInfo.environment["OS"] == nil
    && FileManager.default.fileExists(atPath: "/System/Library/Frameworks")

let package = Package(
    name: "CmuxControlSocket",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxControlSocket",
            targets: ["CmuxControlSocket"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxSettings"),
    ] + (onDarwin ? [] : [
        .package(url: "https://github.com/apple/swift-crypto", from: "3.0.0"),
    ]),
    targets: [
        .target(
            name: "CmuxControlSocket",
            dependencies: [
                .product(name: "CmuxSettings", package: "CmuxSettings"),
            ] + (onDarwin ? [] : [
                .product(name: "Crypto", package: "swift-crypto"),
            ]),
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxControlSocketTests",
            dependencies: [
                "CmuxControlSocket",
                .product(name: "CmuxSettings", package: "CmuxSettings"),
            ]
        ),
    ]
)
