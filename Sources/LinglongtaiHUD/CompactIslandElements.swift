import LinglongtaiShared
import SwiftUI

/// A quiet, consistent mount for the actual installed application icon.
/// Brand artwork is never recolored or replaced by an invented color orb.
struct CompactAgentMark: View {
    let task: AgentTask?
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(Color.white.opacity(0.065))
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.09), lineWidth: 0.5)
                }
            if let task, task.profile.kind != .custom {
                AgentIcon(kind: task.profile.kind, size: max(6, size - 2))
            } else if let task {
                Text(String(task.agent.prefix(1)).uppercased())
                    .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.84))
            } else {
                Image(systemName: "sparkle")
                    .font(.system(size: size * 0.48, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A state indicator, not a progress meter: no invented percentage or animation.
struct CompactTaskIndicator: View {
    let symbol: String
    let count: String
    let needsAttention: Bool
    let height: CGFloat
    var executing: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var countLabel: String? {
        guard let value = Int(count), value > 1 else { return nil }
        return value > 9 ? "9+" : String(value)
    }

    var body: some View {
        HStack(spacing: 3) {
            if executing && !reduceMotion {
                CompactActivityGlyph(height: height)
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
        .foregroundStyle(needsAttention ? Color.orange.opacity(0.95) : Color.white.opacity(0.72))
        .padding(.horizontal, 4)
        .frame(minWidth: height, minHeight: height, maxHeight: height)
        .background(needsAttention ? Color.orange.opacity(0.12) : Color.white.opacity(0.055), in: Capsule())
        .overlay {
            Capsule().strokeBorder(needsAttention ? Color.orange.opacity(0.2) : Color.white.opacity(0.09), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }
}

private struct CompactActivityGlyph: View {
    let height: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            HStack(alignment: .center, spacing: 1.5) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule(style: .continuous)
                        .frame(width: 2, height: max(3, height * 0.24 * CGFloat(AgentActivityMotion.barScale(
                            elapsed: context.date.timeIntervalSinceReferenceDate,
                            index: index
                        ))))
                }
            }
            .frame(width: min(10, height * 0.48), height: height * 0.56)
            .accessibilityHidden(true)
        }
    }
}
