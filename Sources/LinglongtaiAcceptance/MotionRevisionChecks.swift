import Foundation
import CoreGraphics
import LinglongtaiShared

/// Geometry checks are independent of AppKit. They do not certify pointer
/// tracking, frame pacing, or the appearance of the real hardware seam.
func runMotionRevisionChecks(check: (String, Bool) -> Void) {
    let dt = 1.0 / 120
    let metrics = IslandMetrics(notchWidth: 184, notchHeight: 32)

    check("compact is a persistent width-only task state",
          IslandInteraction().presentation(hasLiveEvent: true, autoPop: true,
                                           hoverEnabled: true, prefersMedium: false) == .compact)
    check("default compact and medium wings use the new widths",
          metrics.size(for: .compact) == CGSize(width: 296, height: 32) &&
          metrics.size(for: .medium) == CGSize(width: 412, height: 32))

    var motion = IslandMotion()
    motion.configure(metrics, initial: true)
    motion.setTarget(.compact)
    var compactHeightIsConstant = true
    var compactOpacityIsMonotone = true
    var previousOpacity = 0.0
    for _ in 0..<240 {
        motion.advance(by: dt)
        compactHeightIsConstant = compactHeightIsConstant && abs(motion.frame.height - 32) < 0.001
        compactOpacityIsMonotone = compactOpacityIsMonotone && motion.frame.compactOpacity >= previousOpacity
        previousOpacity = motion.frame.compactOpacity
    }
    check("compact stays at notch height throughout its opening",
          compactHeightIsConstant && motion.isSettled && motion.frame.compactOpacity == 1)
    check("compact reveal stays latched across the opening rebound", compactOpacityIsMonotone)

    motion.setTarget(.medium)
    var noBlankHandoff = true
    for _ in 0..<240 {
        motion.advance(by: dt)
        noBlankHandoff = noBlankHandoff && motion.frame.compactOpacity + motion.frame.mediumOpacity >= 0.99
        compactHeightIsConstant = compactHeightIsConstant && abs(motion.frame.height - 32) < 0.001
    }
    check("compact to medium crossfades its content without a blank handoff",
          noBlankHandoff && compactHeightIsConstant && motion.frame.mediumOpacity == 1)

    let contractions: [(IslandPresentation, IslandPresentation)] = [
        (.heavy, .medium), (.heavy, .compact), (.heavy, .collapsed),
        (.medium, .compact), (.medium, .collapsed), (.compact, .collapsed)
    ]
    for (from, to) in contractions {
        var shrinking = IslandMotion()
        shrinking.configure(metrics, initial: true)
        shrinking.setTarget(from)
        for _ in 0..<240 { shrinking.advance(by: dt) }
        shrinking.setTarget(to)
        var previous = shrinking.frame
        let beforeClose = previous
        var monotone = true
        var cornersAreMonotone = true
        var sourceOpacityIsMonotone = true
        var previousSourceOpacity = contentOpacity(previous, for: from)
        let destination = metrics.size(for: to)
        for index in 0..<240 {
            shrinking.advance(by: dt)
            let frame = shrinking.frame
            if index == 0 {
                check("\(from.rawValue) to \(to.rawValue) starts shell, corners and content on the same first frame",
                      frame.width < beforeClose.width && frame.shoulder < beforeClose.shoulder &&
                      contentOpacity(frame, for: from) < previousSourceOpacity && contentOpacity(frame, for: from) > 0 &&
                      (from != .heavy || frame.height < beforeClose.height && frame.bottomRadius < beforeClose.bottomRadius))
            }
            monotone = monotone && frame.width <= previous.width + 0.0001 &&
                frame.height <= previous.height + 0.0001 &&
                frame.width >= destination.width - 0.0001 &&
                frame.height >= destination.height - 0.0001
            cornersAreMonotone = cornersAreMonotone && frame.shoulder <= previous.shoulder + 0.0001 &&
                frame.bottomRadius <= previous.bottomRadius + 0.0001
            sourceOpacityIsMonotone = sourceOpacityIsMonotone &&
                contentOpacity(frame, for: from) <= previousSourceOpacity
            previousSourceOpacity = contentOpacity(frame, for: from)
            previous = frame
        }
        check("\(from.rawValue) to \(to.rawValue) contracts monotonically without undershoot",
              monotone && shrinking.isSettled)
        check("\(from.rawValue) to \(to.rawValue) never replays old glyphs or snaps its corners at the end",
              cornersAreMonotone && sourceOpacityIsMonotone && previousSourceOpacity == 0)
    }

    var reversal = IslandMotion()
    reversal.configure(metrics, initial: true)
    reversal.setTarget(.heavy)
    for _ in 0..<240 { reversal.advance(by: dt) }
    reversal.setTarget(.compact)
    reversal.advance(by: dt)
    let leavingOpacity = reversal.frame.heavyOpacity
    let leavingHeight = reversal.frame.height
    let leavingFrame = reversal.frame
    reversal.setTarget(.heavy)
    check("heavy re-entry retargets from the exact rendered frame without a content or geometry jump",
          reversal.frame == leavingFrame)
    reversal.advance(by: dt)
    check("heavy re-entry preserves visible content and the current shell",
          leavingOpacity > 0 && reversal.frame.heavyOpacity >= leavingOpacity &&
          abs(reversal.frame.height - leavingHeight) < 20 && reversal.frame.heavyScale <= 1)

    var interrupted = IslandMotion()
    interrupted.configure(metrics, initial: true)
    interrupted.setTarget(.heavy)
    for _ in 0..<12 { interrupted.advance(by: dt) }
    interrupted.setTarget(.collapsed)
    var previous = interrupted.frame
    var interruptedCloseIsMonotone = true
    for _ in 0..<240 {
        interrupted.advance(by: dt)
        interruptedCloseIsMonotone = interruptedCloseIsMonotone &&
            interrupted.frame.width <= previous.width + 0.0001 &&
            interrupted.frame.height <= previous.height + 0.0001 &&
            interrupted.frame.width >= 184 && interrupted.frame.height >= 32
        previous = interrupted.frame
    }
    check("closing during outward motion immediately stops outward travel",
          interruptedCloseIsMonotone && interrupted.isSettled && interrupted.frame.shellOpacity == 0)

    var simultaneous = IslandMotion()
    simultaneous.configure(metrics, initial: true)
    simultaneous.setTarget(.heavy)
    simultaneous.advance(by: dt)
    check("opening starts content, shoulder and shell growth on its first frame without a near-end reveal gate",
          simultaneous.frame.width > 184 && simultaneous.frame.height > 32 && simultaneous.frame.shoulder > 0 &&
          simultaneous.frame.heavyOpacity > 0 && simultaneous.frame.heavyOpacity < 1 && simultaneous.frame.heavyScale < 1)
    var openingOpacity = simultaneous.frame.heavyOpacity
    var openingDoesNotFlash = true
    var maximumWidth = simultaneous.frame.width
    var maximumHeight = simultaneous.frame.height
    for _ in 0..<240 {
        simultaneous.advance(by: dt)
        openingDoesNotFlash = openingDoesNotFlash && simultaneous.frame.heavyOpacity >= openingOpacity
        openingOpacity = simultaneous.frame.heavyOpacity
        maximumWidth = max(maximumWidth, simultaneous.frame.width)
        maximumHeight = max(maximumHeight, simultaneous.frame.height)
    }
    check("soft expansion retains a bounded small rebound while content stays monotonic",
          openingDoesNotFlash && maximumWidth > 736 && maximumWidth < 743 && maximumHeight > 448 && maximumHeight < 454)
    check("all settled destination content has unscaled text", simultaneous.frame.heavyScale == 1)
    simultaneous.setTarget(.collapsed)
    var shellFadesBeforeHome = false
    var shellNeverReappears = true
    var previousShellOpacity = simultaneous.frame.shellOpacity
    for _ in 0..<240 {
        simultaneous.advance(by: dt)
        let frame = simultaneous.frame
        shellFadesBeforeHome = shellFadesBeforeHome ||
            (frame.shellOpacity < 1 && frame.shellOpacity > 0 && (frame.width > 184 || frame.height > 32))
        shellNeverReappears = shellNeverReappears && frame.shellOpacity <= previousShellOpacity
        previousShellOpacity = frame.shellOpacity
    }
    check("hardware shell fades on approach instead of adding a late disappearing phase",
          shellFadesBeforeHome && shellNeverReappears && simultaneous.frame.shellOpacity == 0 && simultaneous.isSettled)

    for scaleState in [IslandPresentation.compact, .medium, .heavy] {
        var scaled = IslandMotion()
        scaled.configure(metrics, initial: true)
        scaled.setTarget(scaleState)
        for _ in 0..<240 { scaled.advance(by: dt) }
        check("\(scaleState.rawValue) content is rendered at full scale once stable", contentScale(scaled.frame, for: scaleState) == 1)
        scaled.setTarget(.collapsed)
        scaled.advance(by: dt)
        check("\(scaleState.rawValue) glyph layer shrinks with the first shell contraction",
              contentScale(scaled.frame, for: scaleState) < 1 && contentScale(scaled.frame, for: scaleState) > 0)
        let size = metrics.size(for: scaleState)
        var scaledContentFits = true
        for _ in 0..<240 {
            scaled.advance(by: dt)
            let scale = contentScale(scaled.frame, for: scaleState)
            scaledContentFits = scaledContentFits && scale * size.width <= scaled.frame.width + 0.0001 &&
                scale * size.height <= scaled.frame.height + 0.0001
        }
        check("\(scaleState.rawValue) fixed content cannot exceed its shrinking outline", scaledContentFits)
    }

    var rapid = IslandMotion()
    rapid.configure(metrics, initial: true)
    rapid.setTarget(.medium)
    for _ in 0..<240 { rapid.advance(by: dt) }
    var rapidNeverJumps = true
    var unusedLayersNeverReappear = true
    for destination in [IslandPresentation.heavy, .compact, .heavy, .medium, .collapsed, .heavy, .collapsed] {
        let before = rapid.frame
        rapid.setTarget(destination)
        rapidNeverJumps = rapidNeverJumps && rapid.frame == before
        var last = rapid.frame
        for _ in 0..<7 {
            rapid.advance(by: dt)
            for contentState in [IslandPresentation.compact, .medium, .heavy] where contentState != destination {
                unusedLayersNeverReappear = unusedLayersNeverReappear &&
                    contentOpacity(rapid.frame, for: contentState) <= contentOpacity(last, for: contentState)
            }
            last = rapid.frame
        }
    }
    for _ in 0..<240 { rapid.advance(by: dt) }
    check("rapid interrupted transitions preserve current values and never revive a non-target content layer",
          rapidNeverJumps && unusedLayersNeverReappear && rapid.isSettled && rapid.frame.shellOpacity == 0)

    let narrow = IslandMetrics(activityWidth: 100)
    let wide = IslandMetrics(activityWidth: 500)
    var assigned = IslandMetrics()
    assigned.activityWidth = 400
    check("activity width is clamped on initialization and assignment",
          narrow.activityWidth == 200 && wide.activityWidth == 300 && assigned.activityWidth == 300)
    check("compact wings stay between 108 and 140 points",
          narrow.size(for: .compact).width == 292 && wide.size(for: .compact).width == 324)

    var recalibrated = IslandMotion()
    recalibrated.configure(metrics, initial: true)
    recalibrated.setTarget(.medium)
    for _ in 0..<240 { recalibrated.advance(by: dt) }
    let widthBeforeChange = recalibrated.frame.width
    recalibrated.configure(wide)
    var dynamicWidthKeepsContent = recalibrated.frame.width == widthBeforeChange
    for _ in 0..<240 {
        recalibrated.advance(by: dt)
        dynamicWidthKeepsContent = dynamicWidthKeepsContent &&
            recalibrated.frame.mediumOpacity == 1 && recalibrated.frame.height == 32
    }
    check("live width tuning animates geometry without resetting content or height",
          dynamicWidthKeepsContent && recalibrated.frame.width == 484 && recalibrated.isSettled)

    let cameraProtected = IslandMetrics(notchWidth: 128, notchHeight: 20, activityWidth: 200,
                                       physicalWidth: 184, physicalHeight: 32)
    check("negative calibration keeps detail below the physical camera",
          cameraProtected.size(for: .heavy).height == 448 && cameraProtected.size(for: .compact).height == 20)
    check("extreme negative width calibration preserves compact and medium content wings",
          (cameraProtected.size(for: .compact).width - cameraProtected.centerExclusionWidth - 24) / 2 >= 32 &&
          (cameraProtected.size(for: .medium).width - cameraProtected.centerExclusionWidth - 32) / 2 >= 78)
    check("collapsed dimensions always return to physical hardware despite calibration",
          cameraProtected.size(for: .collapsed) == CGSize(width: 184, height: 32))
    var hardwareOnly = IslandMotion()
    hardwareOnly.configure(cameraProtected, initial: true)
    check("initial motion starts at physical hardware dimensions",
          hardwareOnly.frame.width == 184 && hardwareOnly.frame.height == 32 && hardwareOnly.frame.shellOpacity == 0)
    hardwareOnly.setTarget(.compact)
    hardwareOnly.advance(by: dt, reduceMotion: true)
    hardwareOnly.setTarget(.collapsed)
    hardwareOnly.advance(by: dt, reduceMotion: true)
    check("collapsed calibrated hardware has no painted idle shell",
          hardwareOnly.frame.shellOpacity == 0 && hardwareOnly.frame.compactOpacity == 0 &&
          hardwareOnly.frame.width == 184 && hardwareOnly.frame.height == 32 && hardwareOnly.isSettled)

    var shortNotch = IslandMotion()
    shortNotch.configure(cameraProtected, initial: true)
    shortNotch.setTarget(.compact)
    for _ in 0..<240 { shortNotch.advance(by: dt) }
    shortNotch.setTarget(.collapsed)
    var previousHeight = shortNotch.frame.height
    var physicalCloseIsMonotone = true
    for _ in 0..<240 {
        shortNotch.advance(by: dt)
        physicalCloseIsMonotone = physicalCloseIsMonotone &&
            shortNotch.frame.height >= previousHeight - 0.0001 &&
            shortNotch.frame.height <= 32.0001
        previousHeight = shortNotch.frame.height
    }
    check("closing a short calibrated activity grows to hardware height without rebound",
          physicalCloseIsMonotone && shortNotch.frame.height == 32 && shortNotch.isSettled)

    let positiveCalibration = IslandMetrics(notchWidth: 280, notchHeight: 56,
                                           physicalWidth: 184, physicalHeight: 32)
    hardwareOnly.configure(positiveCalibration)
    hardwareOnly.advance(by: dt)
    check("recalibrating idle hardware neither changes its dimensions nor reveals paint",
          hardwareOnly.frame.width == 184 && hardwareOnly.frame.height == 32 && hardwareOnly.frame.shellOpacity == 0)
}

private func contentOpacity(_ frame: IslandMotionFrame, for state: IslandPresentation) -> Double {
    switch state {
    case .collapsed: return 0
    case .compact: return frame.compactOpacity
    case .medium: return frame.mediumOpacity
    case .heavy: return frame.heavyOpacity
    }
}

private func contentScale(_ frame: IslandMotionFrame, for state: IslandPresentation) -> Double {
    switch state {
    case .collapsed: return 1
    case .compact: return frame.compactScale
    case .medium: return frame.mediumScale
    case .heavy: return frame.heavyScale
    }
}
