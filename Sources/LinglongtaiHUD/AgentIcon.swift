import LinglongtaiShared
import SwiftUI

struct AgentIcon: View {
    let kind: AgentKind
    let size: CGFloat
    @ObservedObject private var presence = AgentPresence.shared

    var body: some View {
        Group {
            if let icon = presence.icons[kind] {
                Image(nsImage: icon).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: kind.symbolName).resizable().scaledToFit().padding(size * 0.18)
                    .foregroundStyle(.secondary)
                    .help("未安装应用，使用通用占位图标")
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(L(kind.displayName))
    }
}
