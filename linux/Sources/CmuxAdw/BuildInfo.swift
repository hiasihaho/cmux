import Foundation

/// Which build is this?
///
/// Answering that required indirect inference on 2026-09-01 ("is the VM
/// running what I shipped, or an older flatpak?"), so the answer now ships
/// with the binary. Written at package time and installed beside the
/// executable; a build without the file reports `dev`, which is the honest
/// answer rather than a marketing version that says nothing about the code.
enum BuildInfo {

    static let payload: [String: Any] = load()

    private static func load() -> [String: Any] {
        for url in candidates() {
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            var info = object
            info["source"] = url.path
            return info
        }
        return ["build": "dev", "source": "none"]
    }

    private static func candidates() -> [URL] {
        var urls: [URL] = []
        if let override = ProcessInfo.processInfo.environment["CMUX_BUILD_INFO"], !override.isEmpty {
            urls.append(URL(fileURLWithPath: override))
        }
        let executable = URL(fileURLWithPath: "/proc/self/exe").resolvingSymlinksInPath()
        let binDirectory = executable.deletingLastPathComponent()
        // <prefix>/bin/cmux-adw -> <prefix>/share/cmux/build-info.json (the
        // Flatpak layout), plus a flat file beside a dev binary.
        urls.append(binDirectory.deletingLastPathComponent()
            .appendingPathComponent("share/cmux/build-info.json"))
        urls.append(binDirectory.appendingPathComponent("build-info.json"))
        return urls
    }
}
