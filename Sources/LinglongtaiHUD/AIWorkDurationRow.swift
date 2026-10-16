import Combine
import LinglongtaiShared
import SwiftUI

private final class DurationExplanationState: ObservableObject {
    @Published var explains = false
}

struct AIWorkDurationRow: View {
    @ObservedObject private var duration = AIWorkDurationStore.shared
    @StateObject private var explanation = DurationExplanationState()
    var body: some View {
        Button { explanation.explains.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.42))
                Text("AI 工作 · \(duration.summary.label)")
                    .foregroundStyle(.white.opacity(0.68))
                    .monospacedDigit()
                Image(systemName: "info.circle")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .font(HUDTypography.caption)
            .lineLimit(1)
            .fixedSize()
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L(duration.summary.incomplete ? "AI 工作统计不完整，点击查看说明" : "点击查看 AI 工作时间统计说明"))
        .accessibilityLabel(LF(duration.summary.incomplete ? "今日 AI 工作 %@，统计不完整，查看统计说明" : "今日 AI 工作 %@，查看统计说明", duration.summary.label))
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
