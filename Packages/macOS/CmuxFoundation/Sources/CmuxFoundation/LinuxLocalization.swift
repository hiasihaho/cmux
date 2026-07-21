// String(localized:) for Linux.
//
// corelibs Foundation has neither `String.LocalizationValue` nor the
// `String(localized:defaultValue:)` family. The CLI is not localized on
// Linux (there is no bundle to look keys up in), so the honest behavior is
// exactly what macOS falls back to with no matching table: the development
// string. The interpolation type therefore just composes its literal text.
#if !canImport(Darwin)
public import Foundation

extension String {
    public struct LocalizationValue: ExpressibleByStringInterpolation, Sendable {
        let composed: String
        public init(stringLiteral value: String) { composed = value }
        public init(stringInterpolation: Interpolation) {
            composed = stringInterpolation.parts.joined()
        }
        public struct Interpolation: StringInterpolationProtocol, Sendable {
            var parts: [String] = []
            public init(literalCapacity: Int, interpolationCount: Int) {}
            public mutating func appendLiteral(_ literal: String) { parts.append(literal) }
            public mutating func appendInterpolation<T>(_ value: T) { parts.append("\(value)") }
        }
    }

    /// Development-string fallback: the key is ignored, `defaultValue` wins.
    public init(
        localized key: StaticString,
        defaultValue: String.LocalizationValue,
        table: String? = nil,
        bundle: Bundle? = nil,
        locale: Locale = .current,
        comment: StaticString? = nil
    ) {
        self = defaultValue.composed
    }

    /// Single-argument form: the "key" IS the development string.
    public init(
        localized keyAndValue: String.LocalizationValue,
        table: String? = nil,
        bundle: Bundle? = nil,
        locale: Locale = .current,
        comment: StaticString? = nil
    ) {
        self = keyAndValue.composed
    }
}
#endif // !canImport(Darwin)
