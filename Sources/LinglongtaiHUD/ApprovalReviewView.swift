import AppKit
import LinglongtaiShared
import SwiftUI

/// Call-style approval card grown from the notch: who asks, what will run,
/// time left, then Deny / Allow as two equal pills. Risky requests turn Allow
/// orange and require a press-and-hold. Full parameters stay one tap away.
struct ApprovalReviewView: View {
    let request: ApprovalRelay.Request
    @ObservedObject var store: TaskStore
    @ObservedObject private var conversationTitles = ConversationTitleStore.shared

    static let contentWidth = IslandMetrics.approvalWidth - 2 * 18

    private var expanded: Bool { store.approvalReviewExpanded }
    private var task: AgentTask? { store.tasks.first(where: { $0.id == request.taskID }) }
    private var isPending: Bool { task.flatMap { store.approvalRequest(for: $0) } == request }
    private var needsHold: Bool { store.approvalNeedsHold(request) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            commandBox
            if isPending { decisionButtons } else {
                Text("请求已过期或已处理，请回原应用核实")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, minHeight: Self.buttonHeight)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 14)
        .frame(width: Self.contentWidth,
               height: IslandMetrics.approvalContentHeight(expanded: expanded), alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Header — avatar, conversation, action, queue and time left

    private var header: some View {
        HStack(spacing: 10) {
            AgentIcon(kind: request.provider, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .lineLimit(1).truncationMode(.tail)
                Text(actionSummary).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            }
            Spacer(minLength: 6)
            let queue = store.pendingApprovalTasks.count
            if queue > 1 {
                Text("1/\(queue)").font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit().foregroundStyle(.white.opacity(0.55))
            }
            if isPending { ApprovalCountdownRing(expiresAt: request.expiresAt) }
        }
    }

    private var title: String {
        let conversation = task.map { conversationTitles.title(for: $0) } ?? ""
        return conversation.isEmpty ? "\(request.provider.displayName) 请求批准" : conversation
    }

    /// One plain line for what will happen, from the classified tool label.
    private var actionSummary: String {
        switch request.tool {
        case "执行命令": return "要在终端运行命令"
        case "编辑文件": return "要修改文件"
        case "读取文件": return "要读取文件"
        case "检索文件": return "要搜索文件"
        case "读取网页": return "要打开网页"
        case "搜索资料": return "要上网搜索"
        default: return "要使用一个工具"
        }
    }

    // MARK: Command

    private var fields: [ApprovalShortcut.Field]? { ApprovalShortcut.fields(fromContext: request.context) }

    /// What the card is really about: the longest argument (usually the command).
    private var primary: ApprovalShortcut.Field? {
        fields?.filter { $0.key != "working_directory" }.max { $0.value.count < $1.value.count }
    }

    private var directory: String? {
        fields?.first(where: { $0.key == "working_directory" }).map { ($0.value as NSString).abbreviatingWithTildeInPath }
    }

    private var riskLabels: [String] {
        if let fields { return ApprovalRisk.labels(in: fields) }
        return ApprovalRisk.matches(in: request.context).map(\.label).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    private var hasMore: Bool {
        guard let fields, let primary else { return true }
        return fields.contains { $0.key != "working_directory" && $0.key != primary.key }
            || primary.value.contains("\n") || primary.value.count > 90
    }

    private var commandBox: some View {
        VStack(alignment: .leading, spacing: 5) {
            if expanded {
                ScrollView(showsIndicators: false) { allParameters }
            } else {
                Text(highlighted(primary?.value ?? request.context))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(2).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 6) {
                if !riskLabels.isEmpty {
                    Label("高风险：\(riskLabels.joined(separator: "、"))", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(HUDColorTokens.attention).lineLimit(1)
                } else if let directory, !expanded {
                    Text(directory).foregroundStyle(.white.opacity(0.4)).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if hasMore {
                    Button(expanded ? "收起" : "展开全文") { store.approvalReviewExpanded.toggle() }
                        .buttonStyle(.plain).foregroundStyle(HUDColorTokens.info)
                }
            }
            .font(.system(size: 10.5))
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: expanded ? .infinity : nil, alignment: .topLeading)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder private var allParameters: some View {
        if let fields {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(fields) { field in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(field.key).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                        Text(field.key == "working_directory" ? AttributedString(field.value) : highlighted(field.value))
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(highlighted(request.context)).font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func highlighted(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        for match in ApprovalRisk.matches(in: text) {
            guard let lower = AttributedString.Index(match.range.lowerBound, within: result),
                  let upper = AttributedString.Index(match.range.upperBound, within: result) else { continue }
            result[lower..<upper].foregroundColor = HUDColorTokens.attention
            result[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        }
        return result
    }

    // MARK: Decision — two equal pills, like answering a call

    static let buttonHeight: CGFloat = 32
    /// Clean system-style green (no grey in it) that reads as "go" on black.
    static let allowFill = Color(red: 0.20, green: 0.72, blue: 0.40)

    private var decisionButtons: some View {
        HStack(spacing: 10) {
            Button { store.respondToApproval(request, decision: .deny) } label: {
                pill(icon: "xmark", title: "拒绝", key: "⌘⌫", tint: .white, fill: .white.opacity(0.16))
            }
            .buttonStyle(.plain)
            if needsHold {
                ApprovalHoldButton(store: store)
            } else {
                Button { store.respondToApproval(request, decision: .allow) } label: {
                    pill(icon: "checkmark", title: "允许", key: "⌘↩", tint: .white, fill: Self.allowFill)
                }
                .buttonStyle(.plain)
                .help("只允许这一次，不授予长期权限")
            }
        }
        .padding(.top, 2)
    }

    /// Equal pills that fill the row, like answering a call.
    private func pill(icon: String, title: String, key: String, tint: Color, fill: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold))
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(key).font(.system(size: 10, design: .rounded)).opacity(0.55)
        }
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity, minHeight: Self.buttonHeight, maxHeight: Self.buttonHeight)
        .background(fill, in: Capsule())
        .contentShape(Capsule())
    }
}

/// Orange Allow for risky requests: fills left to right while held; lets go = no decision.
private struct ApprovalHoldButton: View {
    @ObservedObject var store: TaskStore

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: store.approvalHoldStartedAt == nil)) { context in
            let progress = store.approvalHoldStartedAt.map {
                min(1, max(0, context.date.timeIntervalSince($0) / TaskStore.approvalHoldDuration))
            } ?? 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color(red: 0.52, green: 0.33, blue: 0.16))
                GeometryReader { proxy in
                    Capsule().fill(Color(red: 0.82, green: 0.5, blue: 0.22))
                        .frame(width: proxy.size.width * progress)
                }
                HStack(spacing: 5) {
                    Image(systemName: "hand.tap.fill").font(.system(size: 10, weight: .bold))
                    Text(progress > 0 ? "继续按住…" : "长按允许").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, minHeight: ApprovalReviewView.buttonHeight, maxHeight: ApprovalReviewView.buttonHeight)
            .clipShape(Capsule())
        }
        .contentShape(Capsule())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in if store.approvalHoldStartedAt == nil { store.beginApprovalHold() } }
            .onEnded { _ in store.cancelApprovalHold() })
        .help("高风险操作：按住 0.6 秒才会允许，松开即取消")
        .accessibilityLabel("长按允许高风险操作")
    }
}

/// Seconds left before the request falls back to the app; red for the last ten.
struct ApprovalCountdownRing: View {
    let expiresAt: Date
    static let total: TimeInterval = 45

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let remaining = max(0, expiresAt.timeIntervalSince(context.date))
            let tint = remaining <= 10 ? HUDColorTokens.danger : HUDColorTokens.attention
            ZStack {
                Circle().stroke(Color.white.opacity(0.14), lineWidth: 2.5)
                Circle().trim(from: 0, to: min(1, remaining / Self.total))
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(remaining.rounded(.up)))")
                    .font(.system(size: 9, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(tint)
            }
            .frame(width: 24, height: 24)
            .help("还剩 \(Int(remaining.rounded(.up))) 秒，超时后回 App 处理")
        }
    }
}
