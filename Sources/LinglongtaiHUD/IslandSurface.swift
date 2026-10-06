import AppKit
import Combine
import LinglongtaiShared
import SwiftUI

struct IslandLayout: Equatable {
    static let canvasSize = CGSize(width: 760, height: 540)
    static let heavyContentSize = CGSize(width: 640, height: 400)
    var notchWidth: CGFloat = 184
    var notchHeight: CGFloat = 32
    var physicalWidth: CGFloat = 184
    var physicalHeight: CGFloat = 32
    var hasPhysicalNotch = true
    var activityWidth: Double = 228

    init() {}

    init(screen: NSScreen, heightAdjustment: CGFloat, widthAdjustment: CGFloat = 0,
         activityWidth: Double = 228) {
        let left = screen.auxiliaryTopLeftArea ?? .zero
        let right = screen.auxiliaryTopRightArea ?? .zero
        hasPhysicalNotch = screen.safeAreaInsets.top > 0 && !left.isEmpty && !right.isEmpty
        physicalWidth = hasPhysicalNotch ? right.minX - left.maxX : 176
        physicalHeight = hasPhysicalNotch ? screen.safeAreaInsets.top : 24
        notchWidth = max(120, physicalWidth + widthAdjustment)
        notchHeight = max(12, physicalHeight + heightAdjustment)
        self.activityWidth = IslandMetrics(activityWidth: activityWidth).activityWidth
    }

    var metrics: IslandMetrics {
        IslandMetrics(notchWidth: notchWidth, notchHeight: notchHeight,
                      hasPhysicalNotch: hasPhysicalNotch, safeTop: safeTop, activityWidth: activityWidth,
                      physicalWidth: physicalWidth, physicalHeight: physicalHeight)
    }

    var safeTop: CGFloat { max(physicalHeight, notchHeight) }
    var centerExclusionWidth: CGFloat { metrics.centerExclusionWidth }
    func size(for state: IslandPresentation) -> CGSize { metrics.size(for: state) }
}

@MainActor
final class IslandSurface: ObservableObject {
    @Published private(set) var frame = IslandMotionFrame()
    @Published private(set) var layout = IslandLayout()
    private var motion = IslandMotion()
    private var isConfigured = false

    func configure(_ layout: IslandLayout, presentation: IslandPresentation) {
        self.layout = layout
        // Recalibration retargets the spring rather than snapping to collapsed.
        motion.configure(layout.metrics, initial: !isConfigured)
        isConfigured = true
        motion.setTarget(presentation)
        frame = motion.frame
    }

    func setTarget(_ presentation: IslandPresentation) { motion.setTarget(presentation) }

    func advance(by delta: TimeInterval, reduceMotion: Bool) {
        motion.advance(by: delta, reduceMotion: reduceMotion)
        if frame != motion.frame { frame = motion.frame }
    }

    var isSettled: Bool { motion.isSettled }

    func contains(_ point: CGPoint) -> Bool {
        // Negative calibration must not cut the real hardware out of the hover
        // region. When idle, only that physical region remains interactive.
        if layout.hasPhysicalNotch {
            let hardwareRect = CGRect(x: (IslandLayout.canvasSize.width - layout.physicalWidth) / 2,
                                      y: 0, width: layout.physicalWidth, height: layout.physicalHeight)
            let overHardware = NotchSurfaceShape(shoulder: 0, bottomRadius: min(9, layout.physicalHeight * 0.3))
                .path(in: hardwareRect).contains(point)
            if frame.shellOpacity == 0 { return overHardware }
            if overHardware { return true }
        }
        let rect = CGRect(x: (IslandLayout.canvasSize.width - frame.width) / 2, y: 0,
                          width: frame.width, height: frame.height)
        return NotchSurfaceShape(shoulder: frame.shoulder, bottomRadius: frame.bottomRadius)
            .path(in: rect).contains(point)
    }
}

/// One continuous contour for paint, clipping and pointer hit testing.
struct NotchSurfaceShape: Shape {
    var shoulder: CGFloat
    var bottomRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let s = min(max(0, shoulder), rect.height / 2)
        let r = min(max(0, bottomRadius), (rect.height - s) / 2)
        let left = rect.minX + s
        let right = rect.maxX - s
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: left, y: rect.minY + s),
                          control: CGPoint(x: left, y: rect.minY))
        path.addLine(to: CGPoint(x: left, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: left + r, y: rect.maxY),
                          control: CGPoint(x: left, y: rect.maxY))
        path.addLine(to: CGPoint(x: right - r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: right, y: rect.maxY - r),
                          control: CGPoint(x: right, y: rect.maxY))
        path.addLine(to: CGPoint(x: right, y: rect.minY + s))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: right, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
