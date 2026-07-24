#!/bin/sh
# Build the full cmux macOS app on an Intel Mac (e.g. the ultmos verify VM).
# Run ON the Mac, from the repo root's parent of macos-verify (any cwd works).
#
# Why this exists — the codebase requires Swift 6.2 (isolated deinit et al.)
# but the last Intel-capable Xcode is 16.4 (Swift 6.1.2), and production
# Xcode toolchains refuse -enable-experimental-feature. The only working
# Intel recipe (proven 2026-07-24, POC-0003 increment 1) is a hybrid:
#   - Xcode 16.4 provides xcodebuild, the SDK, and SwiftPM manifest parsing
#     (manifests are tools-6.0; the OSS toolchain's manifest compile crashes
#     on Xcode's legacy-driver invocation, so SWIFT_EXEC must be a build
#     SETTING, never an exported environment variable);
#   - the swift.org 6.2.3 toolchain provides the source compiler;
#   - -Xfrontend -enable-cross-import-overlays restores overlay resolution
#     (e.g. _Translation_SwiftUI's translationPresentation) that Apple's
#     driver enables by default and the OSS driver does not.
#
# Prerequisites on the Mac (one-time):
#   - Xcode 16.4 at /Applications/Xcode.app, xcode-select'ed, license accepted
#   - swift.org toolchain: swift-6.2.3-RELEASE-osx.pkg installed
#   - zig 0.15.2 reachable at /usr/local/bin/zig (Ghostty CLI helper phase)
#   - rustup (stable, minimal profile) in ~/.cargo (diff-sidecar phase)
#   - GhosttyKit.xcframework built: cd ghostty && zig build \
#       -Demit-xcframework=true -Dxcframework-target=native \
#       -Doptimize=ReleaseFast -Di18n=false   (no gettext on stock macOS)
#   - repo-root symlink: GhosttyKit.xcframework -> ghostty/macos/GhosttyKit.xcframework
#   - vendor/bonsplit present (submodule; rsync it if the tree came git-less)
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TC=/Library/Developer/Toolchains/swift-6.2.3-RELEASE.xctoolchain

exec xcodebuild \
    -project "$ROOT/cmux.xcodeproj" \
    -scheme cmux \
    -configuration Debug \
    -destination "platform=macOS" \
    -derivedDataPath "$HOME/cmux-derived" \
    CODE_SIGNING_ALLOWED=NO \
    SWIFT_EXEC="$TC/usr/bin/swiftc" \
    "OTHER_SWIFT_FLAGS=\$(inherited) -Xfrontend -enable-cross-import-overlays" \
    "$@" build
