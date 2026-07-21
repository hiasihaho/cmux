#if canImport(CoreGraphics)
public import CoreGraphics
#else
public import Foundation
#endif

/// Fixed widths for sidebar row trailing accessories.
public struct SidebarTrailingAccessoryWidthPolicy {
    /// Width of the row close button.
    public let closeButtonWidth: CGFloat = 16

    public init() {}
}
