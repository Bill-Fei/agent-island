import Foundation
import LinglongtaiShared

func runWingLayoutRevisionChecks(check: (String, Bool) -> Void) {
    for widthAdjustment in [-56.0, 0, 96] {
        for activityWidth in [200.0, 228, 300] {
            let metrics = IslandMetrics(notchWidth: max(120, 184 + widthAdjustment),
                                        activityWidth: activityWidth,
                                        physicalWidth: 184, physicalHeight: 32)
            for state in [IslandPresentation.compact, .medium] {
                let layout = IslandWingLayout(surfaceWidth: metrics.size(for: state).width,
                                              centerExclusionWidth: metrics.centerExclusionWidth,
                                              shoulderInset: state == .medium ? 8 : 6)
                let label = "\(state.rawValue), calibration \(widthAdjustment), wings \(activityWidth)"
                check("wing layout: 12 pt symmetric visible-side inset for \(label)",
                      layout.leadingContentEdge - layout.shoulderInset == 12 &&
                      layout.surfaceWidth - layout.shoulderInset - layout.trailingContentEdge == 12)
                check("wing layout: equal wings preserve camera gap for \(label)",
                      abs(2 * layout.wingWidth + layout.centerExclusionWidth - layout.contentWidth) < 0.001 &&
                      layout.centerExclusionWidth >= metrics.physicalWidth && layout.wingWidth >= 26)
            }

            var motion = IslandMotion()
            motion.configure(metrics, initial: true)
            var cameraSafe = true
            var wingsFit = true
            for destination in [IslandPresentation.medium, .heavy, .medium, .compact, .collapsed] {
                motion.setTarget(destination)
                for _ in 0..<150 {
                    motion.advance(by: 1.0 / 120)
                    let frame = motion.frame
                    let current = IslandWingLayout(surfaceWidth: frame.width,
                                                   centerExclusionWidth: metrics.centerExclusionWidth,
                                                   shoulderInset: min(frame.shoulder, frame.height / 2))
                    cameraSafe = cameraSafe && current.centerExclusionWidth >= metrics.physicalWidth &&
                        abs(current.contentWidth - 2 * current.wingWidth - current.centerExclusionWidth) < 0.001
                    for state in [IslandPresentation.compact, .medium] {
                        let natural = IslandWingLayout(surfaceWidth: metrics.size(for: state).width,
                                                       centerExclusionWidth: metrics.centerExclusionWidth,
                                                       shoulderInset: state == .medium ? 8 : 6)
                        let width = max(state == .compact ? 32 : 1, natural.wingWidth)
                        let scale = current.fitScale(contentWidth: width, contentHeight: metrics.notchHeight,
                                                     requestedScale: state == .compact ? frame.compactScale : frame.mediumScale,
                                                     availableHeight: frame.height)
                        wingsFit = wingsFit && width * scale <= current.wingWidth + 0.001 &&
                            metrics.notchHeight * scale <= frame.height + 0.001 && scale >= 0 && scale <= 1
                    }
                }
            }
            let label = "calibration \(widthAdjustment), wings \(activityWidth)"
            check("wing layout: unscaled camera exclusion on every open/close frame, \(label)", cameraSafe)
            check("wing layout: every scaled wing fits without entering the camera, \(label)", wingsFit)
        }
    }
}
