import SwiftUI
import Combine

private final class DurationExplanationState: ObservableObject {
    @Published var explains = false
}

struct AIWorkDurationRow: View {
    @ObservedObject private var duration = AIWorkDurationStore.shared
    @StateObject private var explanation = DurationExplanationState()
    var body: some View {
        Button { explanation.explains.toggle() } label: {
            HStack(spacing: 7) {
                Image(systemName: "clock").foregroundStyle(.white.opacity(0.42))
                Text("今日 AI 工作").foregroundStyle(.white.opacity(0.58))
                Text("· \(duration.summary.label)").monospacedDigit().foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 0)
                if duration.summary.incomplete { Text("统计不完整").foregroundStyle(.white.opacity(0.4)) }
                Image(systemName: "info.circle").foregroundStyle(.white.opacity(0.35))
            }
            .font(HUDTypography.caption)
            .padding(.horizontal, 20).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("今日 AI 工作 \(duration.summary.label)\(duration.summary.incomplete ? "，统计不完整" : "")，查看统计说明")
        .popover(isPresented: $explanation.explains) {
            VStack(alignment: .leading, spacing: 8) {
                Text("只计可确认的 AI 工作时间").font(.headline)
                Text("根据已接入 Claude Code、Codex、WorkBuddy 的真实执行回调统计，按今天本地日期汇总。并行区间只算一次，等待审批和回复不计入。")
                Text("只累计真实事件之间可确认的区间；当前尚未闭合的执行尾段、轮次不明及超过 30 分钟无回调的区间不推算，因此可能低于实际时间。豆包、Claude Chat 暂不纳入。")
                Text("不是你注视屏幕或前台使用 AI 的时间。数据仅在本机，不生成排行榜。")
            }.font(.callout).frame(width: 310).padding(18)
        }
    }
}
