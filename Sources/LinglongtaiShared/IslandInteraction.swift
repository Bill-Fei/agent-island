import Foundation

public enum IslandPresentation: String, Equatable, Sendable {
    case collapsed, compact, medium, heavy
}

/// One owner for hover intent. Repeated pointer samples never restart a deadline.
public struct IslandInteraction: Equatable, Sendable {
    public private(set) var pointerIsInside = false
    public private(set) var isHovering = false
    public private(set) var explicitlyExpanded = false
    public private(set) var suppressHoverUntilExit = false
    private var pointerChangedAt: TimeInterval = 0

    public init() {}

    public mutating func samplePointer(inside: Bool, at time: TimeInterval) {
        if inside != pointerIsInside {
            pointerIsInside = inside
            pointerChangedAt = time
        }
        // Exiting before the dwell deadline cancels immediately. Once open,
        // retain the short exit grace to avoid flicker at the moving contour.
        let delay: TimeInterval = inside ? 0.2 : (isHovering ? 0.15 : 0)
        guard time - pointerChangedAt >= delay else { return }
        isHovering = inside
        if !inside {
            explicitlyExpanded = false
            suppressHoverUntilExit = false
        }
    }

    public mutating func toggleExpanded(from presentation: IslandPresentation) {
        if presentation == .heavy {
            explicitlyExpanded = false
            suppressHoverUntilExit = true
        } else {
            explicitlyExpanded = true
            suppressHoverUntilExit = false
        }
    }

    public func presentation(hasLiveEvent: Bool, autoPop: Bool, hoverEnabled: Bool,
                             prefersMedium: Bool = true) -> IslandPresentation {
        if explicitlyExpanded || (isHovering && hoverEnabled && !suppressHoverUntilExit) {
            return .heavy
        }
        guard hasLiveEvent && autoPop else { return .collapsed }
        return prefersMedium ? .medium : .compact
    }
}

/// One analytic clock for every surface dimension. Expansion has a small rebound;
/// contraction discards outward velocity and approaches home without overshoot.
public struct IslandSpring: Sendable {
    public private(set) var value: Double
    public private(set) var velocity: Double = 0
    public var target: Double {
        didSet {
            if target != oldValue {
                isContracting = target < value
                forcedMonotonic = false
            }
        }
    }
    private var isContracting = false
    private var forcedMonotonic = false

    public init(_ value: Double) {
        self.value = value
        self.target = value
    }

    public var isSettled: Bool { abs(value - target) < 0.025 && abs(velocity) < 0.25 }

    public mutating func snap(to target: Double) {
        self.target = target
        value = target
        velocity = 0
        isContracting = false
        forcedMonotonic = false
    }

    /// A semantic close can numerically grow a negatively calibrated height
    /// back to the hardware. Both directions must arrive without rebound.
    public mutating func retarget(_ target: Double, monotonic: Bool) {
        self.target = target
        forcedMonotonic = monotonic
        isContracting = target < value
    }

    public mutating func advance(by delta: TimeInterval, reduceMotion: Bool = false) {
        if reduceMotion || isSettled {
            snap(to: target)
            return
        }
        let dt = max(0, delta)
        guard dt > 0 else { return }
        if isContracting || forcedMonotonic {
            // A reversal may arrive while the opening spring still moves out.
            // Clamp that velocity before integrating a critically damped close.
            let omega = 2 * Double.pi / 0.32
            let direction = value >= target ? 1.0 : -1.0
            let distance = abs(value - target)
            let inwardVelocity = min(0, velocity * direction)
            let coefficient = inwardVelocity + omega * distance
            let decay = exp(-omega * dt)
            let remaining = max(0, min(distance, (distance + coefficient * dt) * decay))
            value = target + direction * remaining
            let closingVelocity = min(0, (inwardVelocity - omega * coefficient * dt) * decay)
            velocity = remaining == 0 ? 0 : direction * closingVelocity
            return
        }
        let omega = 2 * Double.pi / 0.48
        let damping = 0.84
        let damped = omega * sqrt(1 - damping * damping)
        let decay = exp(-damping * omega * dt)
        let offset = value - target
        let cosine = cos(damped * dt)
        let sine = sin(damped * dt)
        value = target + decay * (offset * cosine + (velocity + damping * omega * offset) / damped * sine)
        velocity = decay * (velocity * cosine - (damping * omega * velocity + omega * omega * offset) / damped * sine)
    }
}
