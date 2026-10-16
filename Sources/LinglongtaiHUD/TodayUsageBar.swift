import LinglongtaiShared
import SwiftUI

/// Retained real turns today, shown as distribution rather than completion progress.
struct TodayUsageBar: View {
    let usage: [AgentUsageCount]
    var showsDuration = true

    private var total: Int { usage.reduce(0) { $0 + $1.count } }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 16) {
                HStack(spacing: 6) {
                    Text("今日活跃")
                        .foregroundStyle(.white.opacity(0.66))
                    Text("· \(total) 轮")
                        .foregroundStyle(.white.opacity(0.9))
                        .monospacedDigit()
                }
                .font(HUDTypography.captionEmphasis)
                .fixedSize()
                UsageBarSegments(usage: usage, total: total)
                    .frame(height: 8)
            }
            HStack(spacing: 16) {
                if usage.isEmpty {
                    Text("今天还没有真实轮次记录")
                        .font(HUDTypography.caption)
                        .foregroundStyle(.white.opacity(0.42))
                } else {
                    ForEach(usage) { item in
                        HStack(spacing: 5) {
                            Circle()
                                .fill(HUDColorTokens.agent(item.kind))
                                .frame(width: 5, height: 5)
                            Text(L(item.kind.displayName))
                                .font(HUDTypography.caption)
                            Text("\(item.count)")
                                .font(HUDTypography.captionEmphasis)
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.78))
                        }
                        .foregroundStyle(.white.opacity(0.58))
                    }
                }
                Spacer(minLength: 0)
                if showsDuration { AIWorkDurationRow() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .help("统计保留记录中今日有活动的轮次；色段表示各 Agent 占比，不是任务完成进度。")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        if usage.isEmpty { return L("今日没有真实轮次记录") }
        let details = usage.map { LF("%@ %lld 轮", L($0.kind.displayName), $0.count) }.joined(separator: L("，"))
        return LF("今日活跃轮次共 %lld 轮，%@，非模型调用次数", total, details)
    }
}

private struct UsageBarSegments: View {
    let usage: [AgentUsageCount]
    let total: Int

    var body: some View {
        GeometryReader { proxy in
            let items = usage.filter { $0.count > 0 }
            let gap: CGFloat = 2
            let usableWidth = max(0, proxy.size.width - gap * CGFloat(max(0, items.count - 1)))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.06))
                HStack(spacing: gap) {
                    ForEach(items) { item in
                        Capsule()
                            .fill(LinearGradient(
                                colors: [HUDColorTokens.agent(item.kind).opacity(0.75), HUDColorTokens.agent(item.kind)],
                                startPoint: .top, endPoint: .bottom
                            ))
                            .frame(width: usableWidth * CGFloat(item.count) / CGFloat(max(total, 1)))
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
    }
}
