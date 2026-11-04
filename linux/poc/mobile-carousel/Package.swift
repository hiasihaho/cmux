// swift-tools-version: 6.1
import PackageDescription

// Standalone spike — NOT part of the cmux-adw build. Answers one question
// before anything touches the product shell: does a full-width VTE pane
// carousel with a GNOME-style overview feel right on a phone-sized RDP
// window (Guacamole → gnome-remote-desktop)? See
// docs/linux-port/poc/0004-mobile-carousel.md.
//
// Same adwaita-swift pin as linux/Package.swift (GNOME 49 SDK).
let package = Package(
    name: "mobile-carousel",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            url: "https://git.aparoksha.dev/aparoksha/adwaita-swift",
            revision: "664cadd3d242f504cbcdcdfed4e3af42d58a6b84"
        ),
    ],
    targets: [
        .systemLibrary(name: "CVte", path: "Sources/CVte", pkgConfig: "vte-2.91-gtk4"),
        .systemLibrary(name: "CAdwShim", path: "Sources/CAdwShim", pkgConfig: "libadwaita-1"),
        .systemLibrary(name: "CWebKit", path: "Sources/CWebKit", pkgConfig: "webkitgtk-6.0"),
        .executableTarget(
            name: "MobileCarousel",
            dependencies: [
                .product(name: "Adwaita", package: "adwaita-swift"),
                "CVte",
                "CAdwShim",
            ],
            path: "Sources/MobileCarousel",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.unsafeFlags(["-Xlinker", "--allow-shlib-undefined"])]
        ),
        // Spike v2 (2026-11-04): the two-level workflow shell — workspaces
        // (one per worktree) as AdwTabView + AdwTabOverview, inside each a
        // carousel of shell + preview (WebKit). v1 above stays untouched.
        .executableTarget(
            name: "MobileWorkflow",
            dependencies: [
                .product(name: "Adwaita", package: "adwaita-swift"),
                "CVte",
                "CAdwShim",
                "CWebKit",
            ],
            path: "Sources/MobileWorkflow",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.unsafeFlags(["-Xlinker", "--allow-shlib-undefined"])]
        ),
    ]
)
