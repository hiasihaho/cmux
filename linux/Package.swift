// swift-tools-version: 6.1
import PackageDescription
import Foundation

// Dual-target: GNOME 49 (default, e.g. Fedora 43 host) vs GNOME 50
// (e.g. Fedora 44 container). adwaita-swift `main` tracks the GNOME 50 SDK
// and uses C symbols (gtk_picture_set_isolate_contents, …) that GTK 4.20
// headers don't have, so the 49 build pins the last GNOME-49-compatible
// revision. Select with: CMUX_GNOME=50 swift build
let gnome50 = ProcessInfo.processInfo.environment["CMUX_GNOME"] == "50"

// Opt-in Ghostty terminal surfaces (experimental): CMUX_GHOSTTY=1 links the
// embedding shim built from the ghostty submodule (branch linux-gtk-embed):
//   cd ../ghostty && zig build lib-gtk -Dapp-runtime=gtk -Dversion-string=1.3.0-dev
// Runtime still requires CMUX_TERM=ghostty to swap the VTE factory.
let ghosttyEmbed = ProcessInfo.processInfo.environment["CMUX_GHOSTTY"] == "1"
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // Package.swift
    .deletingLastPathComponent()  // linux/
    .path
let ghosttyOut = "\(repoRoot)/ghostty/zig-out"

let adwaitaSwift: Package.Dependency = gnome50
    ? .package(url: "https://git.aparoksha.dev/aparoksha/adwaita-swift", branch: "main")
    : .package(
        url: "https://git.aparoksha.dev/aparoksha/adwaita-swift",
        revision: "664cadd3d242f504cbcdcdfed4e3af42d58a6b84"
    )

let package = Package(
    name: "cmux-linux",
    products: [
        .executable(name: "cmux-adw", targets: ["CmuxAdw"]),
        .executable(name: "cmux", targets: ["CmuxCLI"])
    ],
    dependencies: [
        adwaitaSwift,
        // Upstream's CLI (shared source via the Sources/CmuxCLI symlink)
        // imports these three internal packages; they live in the repo and
        // build on Linux with a handful of #if guards.
        .package(path: "../Packages/macOS/CmuxFoundation"),
        .package(path: "../Packages/macOS/CmuxSettings"),
        .package(path: "../Packages/macOS/CMUXAgentLaunch"),
        .package(path: "../Packages/macOS/CmuxControlSocket"),
        // CryptoKit substitute: the CLI's hashing goes through swift-crypto off-macOS.
        .package(url: "https://github.com/apple/swift-crypto", from: "3.0.0"),
    ],
    targets: [
        .systemLibrary(
            name: "CVte",
            path: "Sources/CVte",
            pkgConfig: "vte-2.91-gtk4"
        ),
        .systemLibrary(
            name: "CWebKit",
            path: "Sources/CWebKit",
            pkgConfig: "webkitgtk-6.0"
        ),
        .executableTarget(
            name: "CmuxAdw",
            dependencies: [
                "CVte",
                "CWebKit",
                .product(name: "Adwaita", package: "adwaita-swift"),
                // Shared workstream (Feed) engine — same model the macOS app uses.
                .product(name: "CMUXAgentLaunch", package: "CMUXAgentLaunch")
            ] + (ghosttyEmbed ? ["CGhosttyEmbed"] : []),
            path: "Sources/CmuxAdw",
            swiftSettings: [.swiftLanguageMode(.v5)]
                + (ghosttyEmbed
                    ? [.unsafeFlags(["-Xcc", "-I\(ghosttyOut)/include"])]
                    : []),
            linkerSettings: ghosttyEmbed
                ? [.unsafeFlags([
                    "-L\(ghosttyOut)/lib",
                    "-Xlinker", "-rpath", "-Xlinker", "\(ghosttyOut)/lib",
                ])]
                : []
        ),
        // Symlink to ../CLI — the CLI is shared, unmodified source with the
        // macOS app (Linux differences live behind #if inside CLI/cmux.swift).
        .executableTarget(
            name: "CmuxCLI",
            dependencies: [
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
                .product(name: "CmuxSettings", package: "CmuxSettings"),
                .product(name: "CMUXAgentLaunch", package: "CMUXAgentLaunch"),
                .product(name: "CmuxControlSocket", package: "CmuxControlSocket"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/CmuxCLI",
            swiftSettings: [.swiftLanguageMode(.v5)],
            // Fedora's libswiftObservation.so leaves swift::threading::fatal
            // undefined (resolved from libswiftCore at runtime); plain swiftc
            // accepts that, SwiftPM's stricter link line must be told to.
            linkerSettings: [.unsafeFlags(["-Xlinker", "--allow-shlib-undefined"])]
        )
    ] + (ghosttyEmbed
        // Declared only when opted in so `#if canImport(CGhosttyEmbed)`
        // is cleanly false in default (VTE-only) builds.
        ? [.systemLibrary(
            name: "CGhosttyEmbed",
            path: "Sources/CGhosttyEmbed",
            pkgConfig: "gtk4"
        )]
        : [])
)
