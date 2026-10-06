import Foundation

/// A conservative estimate of how wide a glyph run needs to be, deliberately
/// framework-free: no AppKit, no SwiftUI, so the acceptance target can exercise
/// it in isolation. It only ever measures a string the surface is about to
/// render — it never invents a size for text it has not seen.
public enum IslandTextMeasure: Sendable {
    public static func width(of text: String, fontSize: Double, bold: Bool = false) -> Double {
        var total = 0.0
        for scalar in text.unicodeScalars { total += advance(for: scalar) * fontSize }
        return bold ? total * 1.04 : total
    }

    /// CJK and full-width forms are square; Latin runs narrower, uppercase wider
    /// than lowercase. Every unsupported range falls back to a narrow advance,
    /// which keeps the estimate under-measuring rather than over-clipping.
    private static func advance(for scalar: Unicode.Scalar) -> Double {
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
             0xFE30...0xFE4F, 0xFF00...0xFF60, 0x20000...0x3FFFD: return 1.0
        case 0x41...0x5A: return 0.66
        case 0x30...0x39: return 0.56
        case 0x61...0x7A: return 0.53
        case 0x20: return 0.28
        default: return 0.35
        }
    }
}

/// What the medium surface actually has to show, in points per side.
public struct IslandContentWidth: Equatable, Sendable {
    /// Distance between the avatar and the agent name, mirrors HUDView.
    public static let iconGap: Double = 6

    public let left: Double
    public let right: Double

    public init(left: Double, right: Double) {
        self.left = left
        self.right = right
    }

    public var widest: Double { max(left, right) }

    public static func medium(agentName: String, statusText: String, iconSize: Double,
                              statusReserve: Double = 0) -> IslandContentWidth {
        let name = IslandTextMeasure.width(of: agentName, fontSize: 13, bold: true)
        let status = IslandTextMeasure.width(of: statusText, fontSize: 12)
        return IslandContentWidth(left: iconSize + Self.iconGap + name,
                                  right: status + statusReserve)
    }

    /// Wings mirror each other around the camera, so every extra point of
    /// content costs two points of surface. Quantising keeps a three-point text
    /// change from resizing the outline; the cap hands pathological strings back
    /// to the existing marquee instead of spanning the display.
    public func wingWidth(step: Double = 8, minimum: Double = 56, maximum: Double = 150) -> Double {
        guard widest.isFinite else { return minimum }
        let quantised = ceil(widest / step) * step
        return min(maximum, max(minimum, quantised))
    }
}
