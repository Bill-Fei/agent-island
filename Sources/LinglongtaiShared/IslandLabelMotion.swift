import Foundation

/// Bounded back-and-forth label travel. No duplicated accessibility text and
/// no jump from the trailing edge back to the start of a scrolling loop.
public enum IslandLabelMotion {
    public static func overflow(textWidth: Double, viewportWidth: Double) -> Double {
        max(0, textWidth - max(0, viewportWidth))
    }

    public static func offset(elapsed: TimeInterval, textWidth: Double, viewportWidth: Double) -> Double {
        let distance = overflow(textWidth: textWidth, viewportWidth: viewportWidth)
        guard distance > 0.5, viewportWidth > 0 else { return 0 }
        let hold = 0.8
        let travel = max(0.8, distance / 18)
        let phase = max(0, elapsed).truncatingRemainder(dividingBy: 2 * (hold + travel))
        func ease(_ t: Double) -> Double { t * t * (3 - 2 * t) }
        if phase < hold { return 0 }
        if phase < hold + travel { return -distance * ease((phase - hold) / travel) }
        if phase < 2 * hold + travel { return -distance }
        return -distance * (1 - ease((phase - 2 * hold - travel) / travel))
    }
}
