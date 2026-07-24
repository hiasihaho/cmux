// swift-tools-version: 6.1
import PackageDescription

// macOS compile-verification package for the shared CLI (CLI/*.swift).
//
// The Linux port compiles the CLI via linux/Package.swift (target CmuxCLI,
// symlink Sources/CmuxCLI -> ../../CLI). The macOS app compiles the same
// sources through cmux.xcodeproj — which needs full Xcode plus the
// GhosttyKit xcframework. This package mirrors the Linux target's shape on
// macOS with plain Command Line Tools, so "shared-source changes must keep
// building on macOS" (linux/README.md, UPSTREAM.md) is checkable on any
// Mac — including a GPU-less VM where the app itself cannot run.
//
// Differences from the Linux target, both deliberate:
//  - no swift-crypto: on macOS the CLI's hashing uses CryptoKit
//    (#if canImport(CryptoKit) in CLI/cmux.swift, cmux_open.swift);
//  - no --allow-shlib-undefined linker flag (a Fedora-specific workaround).
//
// Usage:  cd macos-verify && swift build
let package = Package(
    name: "cmux-macos-verify",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "cmux", targets: ["CmuxCLI"])
    ],
    dependencies: [
        .package(path: "../Packages/macOS/CmuxFoundation"),
        .package(path: "../Packages/macOS/CmuxSettings"),
        .package(path: "../Packages/macOS/CMUXAgentLaunch"),
        .package(path: "../Packages/macOS/CmuxControlSocket"),
    ],
    targets: [
        // Symlink to ../linux/Sources/CmuxCLI — the canonical SwiftPM file set
        // for the shared CLI: the CLI/ directory plus the handful of app
        // Sources/*.swift files the Xcode CLI target also compiles (JSONCParser,
        // Remote*Bootstrap, AgentHibernationLifecycleState, …). Reusing the
        // Linux target's directory keeps that list in exactly one place.
        .executableTarget(
            name: "CmuxCLI",
            dependencies: [
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
                .product(name: "CmuxSettings", package: "CmuxSettings"),
                .product(name: "CMUXAgentLaunch", package: "CMUXAgentLaunch"),
                .product(name: "CmuxControlSocket", package: "CmuxControlSocket"),
            ],
            path: "Sources/CmuxCLI",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
