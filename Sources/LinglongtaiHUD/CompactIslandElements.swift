import LinglongtaiShared
import SwiftUI

/// The installed application icon without an added mount or border.
/// Brand artwork is never recolored or replaced by an invented color orb.
struct CompactAgentMark: View {
    let task: AgentTask?
    let size: CGFloat

    var body: some View {
        ZStack {
            if let task, task.profile.kind != .custom {
                AgentIcon(kind: task.profile.kind, size: size)
            } else if let task {
                Text(String(task.agent.prefix(1)).uppercased())
                    .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.84))
            } else {
                LinglongtaiBrandMark(size: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The current task sits in front; further tasks peek out toward the camera.
struct IslandAgentStack: View {
    let tasks: [AgentTask]
    let size: CGFloat
    let availableWidth: CGFloat

    static func width(size: CGFloat, count: Int, availableWidth: CGFloat) -> CGFloat {
        min(availableWidth, size + CGFloat(max(0, count - 1)) * size * 0.34)
    }

    var body: some View {
        let width = Self.width(size: size, count: tasks.count, availableWidth: availableWidth)
        let step = max(0, width - size) / CGFloat(max(1, tasks.count - 1))
        ZStack(alignment: .leading) {
            if tasks.isEmpty { CompactAgentMark(task: nil, size: size) }
            ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                CompactAgentMark(task: task, size: size)
                    .scaleEffect(index == 0 ? 1 : 0.88)
                    .offset(x: CGFloat(index) * step)
                    .zIndex(Double(tasks.count - index))
            }
        }
        .frame(width: width, height: size, alignment: .leading)
        .accessibilityHidden(true)
    }
}

/// An indeterminate activity signal; never a fabricated completion percentage.
struct CompactTaskIndicator: View {
    let symbol: String
    let count: String
    let needsAttention: Bool
    let height: CGFloat
    var executing: Bool = false
    var visible: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var countLabel: String? {
        guard let value = Int(count), value > 0 else { return nil }
        return value > 9 ? "9+" : String(value)
    }

    var body: some View {
        HStack(spacing: 3) {
            // A count or waiting symbol is not proof of current execution.
            if executing && !needsAttention && !reduceMotion {
                CompactActivityGlyph(height: height, active: visible)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: min(9, height * 0.48), weight: .semibold))
                    .frame(width: min(9, height * 0.48))
            }
            if let countLabel {
                Text(countLabel)
                    .font(.system(size: min(9, height * 0.48), weight: .medium, design: .rounded))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(needsAttention ? HUDColorTokens.attention.opacity(0.95) : HUDColorTokens.info.opacity(0.9))
        .padding(.horizontal, 4)
        .frame(minWidth: height, minHeight: height, maxHeight: height)
        .background(needsAttention ? HUDColorTokens.attention.opacity(0.12) : HUDColorTokens.info.opacity(0.08), in: Capsule())
        .overlay {
            Capsule().strokeBorder(needsAttention ? HUDColorTokens.attention.opacity(0.2) : HUDColorTokens.info.opacity(0.16), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }
}

struct CompactActivityGlyph: View {
    let height: CGFloat
    let active: Bool
    @StateObject private var clock = IslandMotionClock()

    var body: some View {
        let width = min(9, height * 0.48)
        return TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !clock.running)) { context in
            let elapsed = clock.running ? context.date.timeIntervalSince(clock.startedAt) : clock.frozenElapsed
            let glyphHeight = min(12, height * 0.56)
            HStack(alignment: .center, spacing: width / 6) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule(style: .continuous)
                        .frame(width: width * 2 / 9,
                               height: glyphHeight * CGFloat(AgentActivityMotion.barScale(
                                   elapsed: elapsed,
                                   index: index
                               )))
                }
            }
            .frame(width: width, height: glyphHeight)
            .accessibilityHidden(true)
        }
        .onAppear { clock.setRunning(active) }
        .onDisappear { clock.setRunning(false) }
        .onChange(of: active) { clock.setRunning($0) }
    }
}
