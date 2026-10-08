import LinglongtaiShared
import SwiftUI

struct TaskStateIndicator: View {
    let state: TaskVisualState
    let visible: Bool
    var label: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 5) {
            if state.animates && !reduceMotion {
                CompactActivityGlyph(height: 20, active: visible)
                    .frame(width: 12, height: 12)
            } else {
                Image(systemName: state.symbol)
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 12, height: 12)
            }
            Text(label ?? state.label)
                .font(HUDTypography.captionEmphasis)
                .lineLimit(1)
        }
        .foregroundStyle(state.tint)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label ?? state.label)
    }
}

extension TaskVisualState {
    var tint: Color {
        switch self {
        case .attention: return HUDColorTokens.attention
        case .executing: return HUDColorTokens.info
        case .failed: return HUDColorTokens.danger
        case .completed: return HUDColorTokens.success.opacity(0.78)
        default: return HUDColorTokens.neutral
        }
    }
}
