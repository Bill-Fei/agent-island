import LinglongtaiShared
import SwiftUI

struct HUDRootView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var surface: IslandSurface

    var body: some View {
        let frame = surface.frame
        let shape = NotchSurfaceShape(shoulder: frame.shoulder, bottomRadius: frame.bottomRadius)
        ZStack(alignment: .top) {
            shape.fill(.black).opacity(frame.shellOpacity)
            ZStack(alignment: .top) {
                HUDActivityContent(store: store, surface: surface, layout: surface.layout, presentation: .compact,
                                   animationActive: store.presentation == .compact && frame.compactOpacity >= 0.99)
                    .frame(width: animatedWingLayout.contentWidth,
                           height: surface.layout.notchHeight)
                    .opacity(frame.compactOpacity)
                    .allowsHitTesting(store.presentation == .compact && frame.compactOpacity >= 0.95)
                    .accessibilityHidden(store.presentation != .compact)
                HUDActivityContent(store: store, surface: surface, layout: surface.layout, presentation: .medium,
                                   animationActive: store.presentation == .medium && frame.mediumOpacity >= 0.99)
                    .frame(width: animatedWingLayout.contentWidth,
                           height: surface.layout.notchHeight)
                    .opacity(frame.mediumOpacity)
                    .allowsHitTesting(store.presentation == .medium && frame.mediumOpacity >= 0.95)
                    .accessibilityHidden(store.presentation != .medium)
                // Only geometry observes the animation clock. History and
                // details react to task changes, not every spring sample.
                HUDExpandedContent(store: store)
                    .frame(width: IslandLayout.heavyContentSize.width, height: IslandLayout.heavyContentSize.height)
                    .scaleEffect(frame.heavyScale, anchor: .top)
                    .padding(.top, surface.layout.safeTop + 6)
                    .opacity(frame.heavyOpacity)
                    .allowsHitTesting(store.presentation == .heavy && frame.heavyOpacity >= 0.95)
                    .accessibilityHidden(store.presentation != .heavy)
            }
            .frame(width: frame.width, height: frame.height, alignment: .top)
            .clipShape(shape)
            if store.presentation == .collapsed {
                shape.fill(.clear).contentShape(shape)
                    .onTapGesture { store.toggleExpanded() }
                    .accessibilityLabel("Agent 灵动岛，点击查看任务")
            }
        }
        .frame(width: frame.width, height: frame.height, alignment: .top)
        .frame(width: IslandLayout.canvasSize.width, height: IslandLayout.canvasSize.height, alignment: .top)
        .transaction { $0.animation = nil }
        .preferredColorScheme(.dark)
    }

    private var animatedWingLayout: IslandWingLayout {
        IslandWingLayout(surfaceWidth: surface.frame.width,
                         centerExclusionWidth: surface.layout.centerExclusionWidth,
                         shoulderInset: min(surface.frame.shoulder, surface.frame.height / 2))
    }
}

/// The per-frame work is limited to fitting already-built wing content.
private struct HUDActivityWing<Content: View>: View {
    @ObservedObject var surface: IslandSurface
    let presentation: IslandPresentation
    let alignment: Alignment
    let content: Content

    var body: some View {
        let frame = surface.frame
        let layout = surface.layout
        let current = IslandWingLayout(surfaceWidth: frame.width, centerExclusionWidth: layout.centerExclusionWidth,
                                       shoulderInset: min(frame.shoulder, frame.height / 2))
        let destination = IslandWingLayout(surfaceWidth: layout.size(for: presentation).width,
                                          centerExclusionWidth: layout.centerExclusionWidth,
                                          shoulderInset: min(presentation == .medium ? 8 : 6, layout.notchHeight / 2))
        let naturalWidth = max(presentation == .compact ? 32 : 1, destination.wingWidth)
        let scale = current.fitScale(contentWidth: naturalWidth, contentHeight: layout.notchHeight,
                                     requestedScale: presentation == .compact ? frame.compactScale : frame.mediumScale,
                                     availableHeight: frame.height)
        content
            .frame(width: naturalWidth, height: layout.notchHeight, alignment: alignment)
            .scaleEffect(scale, anchor: alignment == .leading ? .leading : .trailing)
            .frame(width: current.wingWidth, height: layout.notchHeight, alignment: alignment)
            .clipped()
    }
}

private struct HUDActivityContent: View {
    @ObservedObject var store: TaskStore
    let surface: IslandSurface
    let layout: IslandLayout
    let presentation: IslandPresentation
    let animationActive: Bool

    var body: some View {
        if presentation == .compact { compactView } else { mediumView }
    }

    private func wingLayout(for presentation: IslandPresentation) -> IslandWingLayout {
        IslandWingLayout(surfaceWidth: layout.size(for: presentation).width,
                         centerExclusionWidth: layout.centerExclusionWidth,
                         shoulderInset: min(presentation == .medium ? 8 : 6, layout.notchHeight / 2))
    }

    private func activityWing<Content: View>(for presentation: IslandPresentation,
                                            alignment: Alignment,
                                            @ViewBuilder content: () -> Content) -> some View {
        HUDActivityWing(surface: surface, presentation: presentation, alignment: alignment, content: content())
    }

    private var compactView: some View {
        let markSize = min(24, max(8, surface.layout.notchHeight - 4))
        let indicator = CompactTaskIndicator(symbol: compactSymbol,
                                             count: store.compactCountText,
                                             needsAttention: store.waitingCount > 0,
                                             height: min(22, max(8, surface.layout.notchHeight - 4)),
                                             executing: store.activeTaskIsExecuting,
                                             visible: animationActive)
        return HStack(spacing: 0) {
            Button(action: store.toggleExpanded) {
                activityWing(for: .compact, alignment: .leading) {
                    IslandAgentStack(tasks: store.islandIconTasks, size: markSize,
                                     availableWidth: wingLayout(for: .compact).wingWidth)
                        .modifier(AgentActivityEffect(executing: store.activeTaskIsExecuting,
                                                      visible: animationActive))
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("展开 \(store.primaryAgentName) 任务详情")
            Color.clear.frame(width: layout.centerExclusionWidth)
            Group {
                if let task = store.activeTask, store.approvalRequest(for: task) != nil {
                    Button { store.reviewApproval(for: task) } label: {
                        activityWing(for: .compact, alignment: .trailing) {
                            CompactTaskIndicator(symbol: "hand.raised", count: "", needsAttention: true,
                                                 height: min(22, max(8, surface.layout.notchHeight - 4)))
                        }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("查看并批准本次请求")
                    .accessibilityLabel("查看并批准本次请求")
                } else {
                    Button(action: store.toggleExpanded) {
                        activityWing(for: .compact, alignment: .trailing) {
                            indicator
                        }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(store.mediumStatusText)，展开任务详情")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(store.primaryAgentName)，\(store.mediumStatusText)")
        .help("\(store.mediumStatusText) · 连续悬停 0.2 秒查看详情")
    }

    private var compactSymbol: String {
        guard let task = store.activeTask else { return "ellipsis" }
        if store.needsUserAttention(task) { return "hand.raised" }
        if task.status == .waiting || store.displayedStatus(for: task) == "等待状态更新" { return "clock" }
        switch task.status {
        case .running: return "ellipsis"
        case .queued: return "clock"
        case .completed: return "checkmark"
        case .failed: return "exclamationmark"
        case .cancelled: return "minus"
        case .waiting: return "clock"
        }
    }

    private var mediumView: some View {
        let iconSize = min(24, surface.layout.notchHeight - 4)
        let iconWidth = IslandAgentStack.width(size: iconSize, count: store.islandIconTasks.count,
                                              availableWidth: wingLayout(for: .medium).wingWidth)
        let labelWidth = max(0, wingLayout(for: .medium).wingWidth - iconWidth - 6)
        return HStack(spacing: 0) {
            Button(action: store.toggleExpanded) {
                activityWing(for: .medium, alignment: .leading) {
                    HStack(spacing: 6) {
                        IslandAgentStack(tasks: store.islandIconTasks, size: iconSize, availableWidth: iconWidth)
                            .modifier(AgentActivityEffect(executing: store.activeTaskIsExecuting,
                                                          visible: animationActive))
                            .fixedSize()
                        IslandAgentLabel(text: store.calibrationPreview == nil ? store.primaryAgentName : "尺寸预览",
                                         width: labelWidth,
                                         active: animationActive)
                            .id(store.activeTask?.id)
                    }
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("展开 \(store.primaryAgentName) 任务详情")
            // Equal outside insets leave all spare space toward the camera.
            // Its full exclusion width remains unavailable for content.
            Color.clear.frame(width: layout.centerExclusionWidth)
            activityWing(for: .medium, alignment: .trailing) { mediumStatus }
        }
        .help("连续悬停 0.2 秒或点击查看详情")
        .popover(item: Binding(get: { store.reviewingApproval }, set: { if $0 == nil { store.closeApproval() } }), arrowEdge: .top) { request in
            ApprovalReviewView(request: request, store: store)
        }
    }

    private var mediumStatus: some View {
        Group {
            if let task = store.activeTask, store.failedApprovals.contains(task.id) {
                detailButton(title: "未提交决定", tint: .orange)
                    .help("请在原应用核实；没有自动批准")
            } else if let task = store.activeTask, store.approvalRequest(for: task) != nil,
                      store.calibrationPreview == nil {
                Button("批准…") { store.reviewApproval(for: task) }
                    .buttonStyle(.plain).foregroundStyle(.orange)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.18), in: Capsule())
                    .help("查看本次请求并直接批准，无需打开应用")
            } else if let task = store.activeTask, store.approvalFeedback(for: task) != nil {
                detailButton(title: "等待回执", tint: .orange)
            } else {
                detailButton(title: store.mediumStatusText, tint: .white.opacity(0.8))
            }
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
    }

    private func detailButton(title: String, tint: Color) -> some View {
        Button(action: store.toggleExpanded) {
            IslandAgentLabel(text: title, width: wingLayout(for: .medium).wingWidth,
                             active: animationActive,
                             isStatus: true, tint: tint)
                .id(store.activeTask?.id)
                .frame(maxWidth: .infinity, minHeight: surface.layout.notchHeight, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)，展开任务详情")
    }

}

private struct HUDExpandedContent: View {
    @ObservedObject var store: TaskStore
    @ObservedObject private var presence = AgentPresence.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                LiveOrb(size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agent 灵动岛")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .tracking(1.2)
                        .foregroundStyle(.white)
                    Text(store.demoPreviewActive ? "演示预览 · 非真实状态" : "你的 Agent 管家")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.48))
                        .lineLimit(1)
                }
                Spacer()
                Metric(value: String(store.liveTasks.count), label: "LIVE", tint: .mint)
                Metric(value: String(store.waitingCount), label: "REVIEW", tint: .orange)
                Button(action: store.toggleExpanded) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.64))
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .help("收起灵动岛")
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 13)

            Divider().overlay(Color.white.opacity(0.1))

            HStack(spacing: 0) {
                taskList.frame(width: 274)
                Divider().overlay(Color.white.opacity(0.1))
                detailPane
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var taskList: some View {
        let tasks = store.sortedTasks
        let selectedID = store.selectedTask?.id
        return VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("最近 24 小时")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.46))
                Spacer()
                Text("进行中优先").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 7) {
                    if tasks.isEmpty {
                        Text("最近 24 小时暂无会话记录").font(.system(size: 12))
                            .foregroundStyle(.secondary).padding(.vertical, 24)
                    }
                    ForEach(tasks) { task in
                        TaskRow(task: task, isSelected: selectedID == task.id,
                                isStale: store.displayedStatus(for: task) == "等待状态更新",
                                needsAttention: store.needsUserAttention(task)) {
                            store.select(task)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .padding(.top, 14)
        .background(Color.white.opacity(0.035))
    }

    private var detailPane: some View {
        Group {
            if let task = store.selectedTask {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 12) {
                        AgentAvatar(task: task, size: 42)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(task.agent)
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                        }
                        Spacer()
                        Text(store.displayedStatus(for: task))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    Text(task.title)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .padding(.top, 24)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("当前步骤").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            Text(store.currentStepText(for: task))
                                .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                            Text("已执行步骤").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            if task.returnedToolSteps.isEmpty {
                                Text("尚未收到工具完成事件").font(.system(size: 12)).foregroundStyle(.secondary)
                            } else {
                                Text(task.hasUnidentifiedToolSteps ? "收到 \(task.returnedToolSteps.count) 条工具返回记录 · 未提供唯一步骤标识" : "\(task.returnedToolSteps.count) 个工具步骤已返回")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                ForEach(Array(task.returnedToolSteps.prefix(30))) { step in
                                    HStack(alignment: .top) {
                                        Image(systemName: step.state == .failed ? "exclamationmark.circle" : "arrow.turn.down.right")
                                        Text(step.label + (step.state == .failed ? " · 返回错误" : " · 已返回"))
                                        Spacer()
                                        Text(step.updatedAt, style: .time).foregroundStyle(.secondary)
                                    }.font(.system(size: 12))
                                }
                                if task.returnedToolSteps.count > 30 {
                                    Text("显示最近 30 条，计数包含全部返回记录").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.top, 16)

                    Spacer()
                    actionBar(for: task)
                }
                .padding(22)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.white.opacity(0.42))
                    Text("等待任务事件")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.58))
                    ForEach(AgentCatalog.supportedKinds, id: \.self) { kind in
                        HStack {
                            Text(kind.displayName)
                            Spacer()
                            Text(store.connectionLabel(for: kind)).foregroundStyle(.secondary)
                        }
                        .font(.system(size: 11))
                    }
                    .padding(.horizontal, 24)
                    Text("收到真实事件后显示；不推测任务进度。")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func actionBar(for task: AgentTask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 8) {
            if store.approvalRequest(for: task) != nil {
                ActionButton(title: "批准请求…", systemName: "hand.raised", tint: .orange) {
                    store.reviewApproval(for: task)
                }
            }
            if task.profile.kind != .custom {
                ActionButton(title: "打开应用", systemName: "arrow.up.forward", tint: .mint) {
                    presence.open(task.profile.kind)
                }
                .disabled(!presence.canOpen(task.profile.kind))
                .help("打开桌面应用；终端和 IDE 任务请回到原会话处理。")
            }
            Spacer()
          }
          HStack {
            if store.displayedStatus(for: task) == "等待状态更新" {
                Button("从岛上移除") { store.dismissTask(task) }
                    .font(.system(size: 10))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("只移除本地显示，不会停止 Agent；后续真实事件仍可再次出现。")
            }
            Text(store.approvalFeedback(for: task) ?? (store.needsUserAttention(task) && store.approvalRequest(for: task) == nil ? "需在原应用确认" : "由真实事件更新"))
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.32))
          }
        }
    }
}


private struct LiveOrb: View {
    var size: CGFloat = 24

    var body: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.08))
            Circle().fill(AngularGradient(colors: [.mint, .blue, .orange, .mint], center: .center)).padding(4)
            Circle().fill(Color.black.opacity(0.82)).padding(7)
            Circle().fill(Color.white.opacity(0.86)).frame(width: 3, height: 3)
        }
        .frame(width: size, height: size)
    }
}

private struct Metric: View {
    let value: String
    let label: String
    let tint: Color

    var body: some View {
        VStack(spacing: 1) {
            Text(value).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(tint)
            Text(label).font(.system(size: 8, weight: .bold, design: .rounded)).tracking(0.7).foregroundStyle(.white.opacity(0.35))
        }
        .frame(minWidth: 36)
    }
}

private struct AgentAvatar: View {
    let task: AgentTask?
    let size: CGFloat

    var body: some View {
        let color = Color(hex: task?.colorHex ?? "#A7B0C5")
        return ZStack {
            if task == nil || task?.profile.kind == .custom {
                Circle().fill(color.opacity(0.25))
                Circle().stroke(color.opacity(0.75), lineWidth: 1)
            }
            if let task {
                if task.profile.kind == .custom {
                    Text(String(task.agent.prefix(1)).uppercased())
                        .font(.system(size: size * 0.38, weight: .bold, design: .rounded))
                        .foregroundStyle(color)
                } else {
                    AgentIcon(kind: task.profile.kind, size: size)
                }
            } else {
                Image(systemName: "sparkles").foregroundStyle(color)
            }
        }
        .frame(width: size, height: size)
    }
}

private struct StatusBadge: View {
    let status: AgentTaskStatus

    var body: some View {
        Label(status.label, systemImage: status.symbolName)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(status.tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(status.tint.opacity(0.13), in: Capsule())
    }
}

private struct TaskRow: View {
    let task: AgentTask
    let isSelected: Bool
    let isStale: Bool
    let needsAttention: Bool
    let onSelect: () -> Void

    private var isEnded: Bool { [.completed, .failed, .cancelled].contains(task.status) }
    private var stateText: String {
        if isStale { return "等待更新" }
        if needsAttention { return "待确认" }
        switch task.status {
        case .running: return "进行中"
        case .queued: return "排队中"
        case .waiting: return "等待中"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已停止"
        }
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                AgentAvatar(task: task, size: 28)
                    .opacity(isEnded ? 0.55 : 1)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text(task.agent)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(isEnded ? 0.6 : 1))
                        if needsAttention {
                            Image(systemName: "hand.raised.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.orange)
                        }
                    }
                    Text(task.title)
                        .font(.system(size: 10, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.48))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Label(stateText, systemImage: isStale || (task.status == .waiting && !needsAttention) ? "clock" : task.status.symbolName)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(isEnded || isStale || (task.status == .waiting && !needsAttention) ? Color.secondary : task.status.tint)
                    .fixedSize()
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 9)
            .background(isSelected ? Color.white.opacity(0.11) : Color.white.opacity(isEnded ? 0.015 : 0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? Color.white.opacity(0.14) : .clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct ActionButton: View {
    let title: String
    let systemName: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemName)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(tint.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private extension AgentTaskStatus {
    var tint: Color {
        switch self {
        case .queued: return .gray
        case .running: return .mint
        case .waiting: return .orange
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .gray
        }
    }
}

private extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let red = Double((value >> 16) & 0xff) / 255
        let green = Double((value >> 8) & 0xff) / 255
        let blue = Double(value & 0xff) / 255
        self.init(red: red, green: green, blue: blue)
    }
}
