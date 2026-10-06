import LinglongtaiShared
import SwiftUI

/// Keep brand artwork recognizable and its layout fixed. Freeze on departure so
/// the existing shell/content exit animation remains the sole transition owner.
struct AgentActivityEffect: ViewModifier {
    let executing: Bool
    let visible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var clock = IslandMotionClock()

    private var running: Bool { executing && visible && !reduceMotion }

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !clock.running)) { context in
            let elapsed = clock.running ? context.date.timeIntervalSince(clock.startedAt) : clock.frozenElapsed
            let breath = executing && !reduceMotion ? AgentActivityMotion.breath(elapsed: elapsed) : 0
            content
                .opacity(executing && !reduceMotion ? 0.82 + 0.18 * breath : 1)
        }
        .onAppear { clock.setRunning(running) }
        .onChange(of: running) { clock.setRunning($0) }
        .onChange(of: executing) { if !$0 { clock.reset() } }
    }
}
