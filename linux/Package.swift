// swift-tools-version: 6.1
import PackageDescription
import Foundation

// Dual-target: GNOME 49 (default, e.g. Fedora 43 host) vs GNOME 50
// (e.g. Fedora 44 container). adwaita-swift `main` tracks the GNOME 50 SDK
// and uses C symbols (gtk_picture_set_isolate_contents, …) that GTK 4.20
// headers don't have, so the 49 build pins the last GNOME-49-compatible
// revision. Select with: CMUX_GNOME=50 swift build
let gnome50 = ProcessInfo.processInfo.environment["CMUX_GNOME"] == "50"

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
    dependencies: [adwaitaSwift],
    targets: [
        .systemLibrary(
            name: "CVte",
            path: "Sources/CVte",
            pkgConfig: "vte-2.91-gtk4"
        ),
        .executableTarget(
            name: "CmuxAdw",
            dependencies: [
                "CVte",
                .product(name: "Adwaita", package: "adwaita-swift")
            ],
            path: "Sources/CmuxAdw",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Symlink to ../CLI — the CLI is shared, unmodified source with the
        // macOS app (Linux differences live behind #if inside CLI/cmux.swift).
        .executableTarget(
            name: "CmuxCLI",
            path: "Sources/CmuxCLI",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
