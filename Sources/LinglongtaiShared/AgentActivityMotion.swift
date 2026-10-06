import Foundation

/// Indeterminate activity only; never a fabricated completion percentage.
public enum AgentActivityMotion {
    public static func isExecuting(_ task: AgentTask?, now: Date) -> Bool {
        guard let task, task.source.isLive, task.status == .running,
              !task.requiresApproval, task.sourceEvent != "AmbiguousTurn" else { return false }
        let age = now.timeIntervalSince(task.updatedAt)
        return age >= -5 && age <= 120
    }

    /// A quiet 2.4 second breath with zero velocity at the loop boundary.
    public static func breath(elapsed: TimeInterval) -> Double {
        (1 - cos(max(0, elapsed) * 2 * .pi / 2.4)) / 2
    }

    /// Three compact bars take turns breathing to communicate activity without
    /// implying a percentage or a determinate completion state.
    public static func barScale(elapsed: TimeInterval, index: Int) -> Double {
        let phase = max(0, elapsed) * 2 * .pi / 1.35 - Double(index) * 0.85
        return 0.38 + 0.62 * ((1 - cos(phase)) / 2)
    }
}
