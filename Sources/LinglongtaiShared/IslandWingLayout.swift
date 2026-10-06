import Foundation

/// The two activity wings share the same visible inset and usable width.
/// Shoulder inset is added before the 12 pt content margin, so a notched
/// surface is measured from its visible vertical side, not its top bounds.
public struct IslandWingLayout: Equatable, Sendable {
    public static let visibleInset: Double = 12
    public let surfaceWidth: Double
    public let centerExclusionWidth: Double
    public let shoulderInset: Double

    public init(surfaceWidth: Double, centerExclusionWidth: Double, shoulderInset: Double = 0) {
        self.surfaceWidth = surfaceWidth
        self.centerExclusionWidth = centerExclusionWidth
        self.shoulderInset = max(0, shoulderInset)
    }

    public var outerInset: Double { shoulderInset + Self.visibleInset }
    // During a collapse the wings can disappear, but the camera gap never
    // scales or compresses with them.
    public var contentWidth: Double { max(centerExclusionWidth, surfaceWidth - 2 * outerInset) }
    public var wingWidth: Double { max(0, (contentWidth - centerExclusionWidth) / 2) }
    public var leadingContentEdge: Double { outerInset }
    public var trailingContentEdge: Double { surfaceWidth - outerInset }

    public func fitScale(contentWidth: Double, contentHeight: Double,
                         requestedScale: Double, availableHeight: Double) -> Double {
        max(0, min(1, requestedScale, wingWidth / max(1, contentWidth),
                   availableHeight / max(1, contentHeight)))
    }
}
