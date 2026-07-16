import Foundation

/// Short handle refs ("workspace:1", "surface:2", …) matching the macOS v2
/// protocol: ordinals are assigned per kind in encounter order and stay
/// stable for the app's lifetime. Only accessed on the GTK main thread.
final class RefRegistry {

    static let shared = RefRegistry()

    private var ordinals: [String: [UUID: Int]] = [:]
    private var reverse: [String: UUID] = [:]

    func ref(kind: String, uuid: UUID) -> String {
        var forKind = ordinals[kind] ?? [:]
        if let existing = forKind[uuid] {
            return "\(kind):\(existing)"
        }
        let ordinal = forKind.count + 1
        forKind[uuid] = ordinal
        ordinals[kind] = forKind
        let ref = "\(kind):\(ordinal)"
        reverse[ref] = uuid
        return ref
    }

    func resolve(_ ref: String) -> UUID? {
        reverse[ref]
    }
}
