import Foundation

/// Geometry, corner shape and content share one interruptible clock. A content
/// layer never waits for the outline to settle before it starts transitioning.
public struct IslandMotionFrame: Equatable, Sendable {
    public var width = 184.0
    public var height = 32.0
    public var shoulder = 0.0
    public var bottomRadius = 8.0
    public var compactOpacity = 0.0
    public var mediumOpacity = 0.0
    public var heavyOpacity = 0.0
    public var compactScale = 1.0
    public var mediumScale = 1.0
    public var heavyScale = 1.0
    public var shellOpacity = 0.0
    public init() {}
}

public struct IslandMetrics: Equatable, Sendable {
    public var notchWidth: Double
    public var notchHeight: Double
    public var physicalWidth: Double
    public var physicalHeight: Double
    public var hasPhysicalNotch: Bool
    public var safeTop: Double
    /// Total additional width of the two activity wings, in points.
    public var activityWidth: Double {
        didSet { activityWidth = Self.clampedActivityWidth(activityWidth) }
    }
    /// When set, the medium surface is sized from the strings it renders instead
    /// of the fixed medium budget. `nil` keeps the historical fixed width, which
    /// is what the existing revision checks still assert.
    public var mediumWingWidth: Double?

    public init(notchWidth: Double = 184, notchHeight: Double = 32, hasPhysicalNotch: Bool = true,
                safeTop: Double? = nil, activityWidth: Double = 228,
                physicalWidth: Double? = nil, physicalHeight: Double? = nil,
                mediumWingWidth: Double? = nil) {
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
        self.physicalWidth = physicalWidth ?? notchWidth
        self.physicalHeight = physicalHeight ?? notchHeight
        self.hasPhysicalNotch = hasPhysicalNotch
        self.safeTop = max(notchHeight, self.physicalHeight, safeTop ?? notchHeight)
        self.activityWidth = Self.clampedActivityWidth(activityWidth)
        self.mediumWingWidth = mediumWingWidth
    }

    private static func clampedActivityWidth(_ width: Double) -> Double {
        width.isFinite ? min(300, max(200, width)) : 228
    }

    public var centerExclusionWidth: Double { max(physicalWidth, notchWidth) + 12 }

    public func size(for state: IslandPresentation) -> CGSize {
        switch state {
        case .collapsed: return CGSize(width: physicalWidth, height: physicalHeight)
        case .compact:
            let wings = min(140, max(108, activityWidth * 112 / 228))
            let width = max(notchWidth + wings, centerExclusionWidth + 24 + 64)
            return CGSize(width: width, height: notchHeight)
        case .medium:
            // Content-driven sizing: the fixed budget below was calibrated for
            // the longest status string, so short ones paid for space nobody
            // used. Both wings stay equal — the camera keeps them symmetric.
            if let wing = mediumWingWidth {
                let inset = IslandWingLayout.visibleInset + 8
                return CGSize(width: centerExclusionWidth + 2 * (inset + wing), height: notchHeight)
            }
            let width = max(notchWidth + activityWidth, centerExclusionWidth + 32 + 156)
            return CGSize(width: width, height: notchHeight)
        case .heavy: return CGSize(width: 680, height: safeTop + 416)
        }
    }
}

public struct IslandMotion: Sendable {
    public private(set) var frame = IslandMotionFrame()
    public private(set) var target: IslandPresentation = .collapsed
    private var metrics = IslandMetrics()
    private var width = IslandSpring(184)
    private var height = IslandSpring(32)
    private var shoulder = IslandSpring(0)
    private var radius = IslandSpring(8)
    private var transitionElapsed = 0.0
    private var startingCompactOpacity = 0.0
    private var startingMediumOpacity = 0.0
    private var startingHeavyOpacity = 0.0
    private var isContracting = false
    private static let contentDuration = 0.18
    private static let contentStates: [IslandPresentation] = [.compact, .medium, .heavy]

    public init() {}

    public mutating func configure(_ metrics: IslandMetrics, initial: Bool = false) {
        self.metrics = metrics
        if initial {
            let home = metrics.size(for: .collapsed)
            width.snap(to: home.width)
            height.snap(to: home.height)
            shoulder.snap(to: 0)
            radius.snap(to: min(9, home.height * 0.3))
            target = .collapsed
            transitionElapsed = Self.contentDuration
            startingCompactOpacity = 0
            startingMediumOpacity = 0
            startingHeavyOpacity = 0
            isContracting = false
            frame = IslandMotionFrame()
            frame.width = width.value
            frame.height = height.value
            frame.bottomRadius = radius.value
            frame.shellOpacity = metrics.hasPhysicalNotch ? 0 : 1
        }
        // Recalibration retargets geometry without restarting the content clock.
        applyGeometry(target)
    }

    public mutating func setTarget(_ next: IslandPresentation) {
        guard next != target else { return }
        isContracting = rank(next) < rank(target)
        target = next
        // Capture the rendered values, never reset a layer to fully visible.
        // Reversing halfway through close resumes its partial opacity instead
        // of replaying a disappeared label or jumping to a fresh enter state.
        startingCompactOpacity = frame.compactOpacity
        startingMediumOpacity = frame.mediumOpacity
        startingHeavyOpacity = frame.heavyOpacity
        transitionElapsed = 0
        applyGeometry(next)
    }

    private mutating func applyGeometry(_ state: IslandPresentation) {
        let size = metrics.size(for: state)
        let monotonic = isContracting || state == .collapsed
        width.retarget(size.width, monotonic: monotonic)
        height.retarget(size.height, monotonic: monotonic)
        switch state {
        case .collapsed: shoulder.retarget(0, monotonic: true)
        case .compact: shoulder.retarget(6, monotonic: monotonic)
        case .medium: shoulder.retarget(8, monotonic: monotonic)
        case .heavy: shoulder.retarget(20, monotonic: monotonic)
        }
        radius.retarget(state == .heavy ? 26 : min(9, size.height * 0.3), monotonic: monotonic)
    }

    public mutating func advance(by delta: TimeInterval, reduceMotion: Bool = false) {
        let dt = min(max(delta, 0), 0.05)
        width.advance(by: dt, reduceMotion: reduceMotion)
        height.advance(by: dt, reduceMotion: reduceMotion)
        shoulder.advance(by: dt, reduceMotion: reduceMotion)
        radius.advance(by: dt, reduceMotion: reduceMotion)

        transitionElapsed = reduceMotion ? Self.contentDuration : min(Self.contentDuration, transitionElapsed + dt)
        let progress = Self.smoothstep(transitionElapsed / Self.contentDuration)
        for state in Self.contentStates {
            let start = startingOpacity(for: state)
            let destination = state == target ? 1.0 : 0.0
            setOpacity(start + (destination - start) * progress, for: state)
        }

        frame.width = width.value
        frame.height = height.value
        frame.shoulder = max(0, shoulder.value)
        frame.bottomRadius = max(0, radius.value)
        // Each fixed-layout layer scales as a single unit with the current
        // outline. Without this, shrinking the clipping path slices stationary
        // glyphs into a brief row of fragments. Views use a top-centred anchor.
        frame.compactScale = contentScale(for: .compact)
        frame.mediumScale = contentScale(for: .medium)
        frame.heavyScale = contentScale(for: .heavy)
        // The physical notch itself is the final collapsed surface; calibration
        // never leaves a painted extension under the hardware while idle.
        if target == .collapsed && metrics.hasPhysicalNotch {
            let home = metrics.size(for: .collapsed)
            let remaining = max(abs(frame.width - home.width), abs(frame.height - home.height))
            // Fade the last few points as they approach the physical notch,
            // not in a second disappearing phase after all geometry settles.
            frame.shellOpacity = reduceMotion ? 0 : min(frame.shellOpacity, Self.smoothstep(remaining / 8))
        } else {
            frame.shellOpacity = reduceMotion || !metrics.hasPhysicalNotch ? 1 : min(1, frame.shellOpacity + dt / 0.08)
        }
    }

    private func rank(_ state: IslandPresentation) -> Int {
        switch state {
        case .collapsed: return 0
        case .compact: return 1
        case .medium: return 2
        case .heavy: return 3
        }
    }

    private func opacity(for state: IslandPresentation) -> Double {
        switch state {
        case .collapsed: return 0
        case .compact: return frame.compactOpacity
        case .medium: return frame.mediumOpacity
        case .heavy: return frame.heavyOpacity
        }
    }

    private mutating func setOpacity(_ value: Double, for state: IslandPresentation) {
        switch state {
        case .collapsed: break
        case .compact: frame.compactOpacity = value
        case .medium: frame.mediumOpacity = value
        case .heavy: frame.heavyOpacity = value
        }
    }

    private func startingOpacity(for state: IslandPresentation) -> Double {
        switch state {
        case .collapsed: return 0
        case .compact: return startingCompactOpacity
        case .medium: return startingMediumOpacity
        case .heavy: return startingHeavyOpacity
        }
    }

    private func contentScale(for state: IslandPresentation) -> Double {
        let size = metrics.size(for: state)
        return max(0, min(1, frame.width / max(1, size.width), frame.height / max(1, size.height)))
    }

    private static func smoothstep(_ value: Double) -> Double {
        let value = max(0, min(1, value))
        return value * value * (3 - 2 * value)
    }

    private var geometryIsSettled: Bool {
        width.isSettled && height.isSettled && shoulder.isSettled && radius.isSettled
    }

    public var isSettled: Bool {
        geometryIsSettled &&
            Self.contentStates.allSatisfy { opacity(for: $0) == ($0 == target ? 1 : 0) } &&
            (target != .collapsed || !metrics.hasPhysicalNotch || frame.shellOpacity == 0)
    }
}
