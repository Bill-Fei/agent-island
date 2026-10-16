import AppKit
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
                if let request = store.displayedApproval {
                    ApprovalReviewView(request: request, store: store)
                        .scaleEffect(frame.approvalScale, anchor: .top)
                        .padding(.top, surface.layout.safeTop)
                        .opacity(frame.approvalOpacity)
                        .allowsHitTesting(store.presentation == .approval && frame.approvalOpacity >= 0.95)
                        .accessibilityHidden(store.presentation != .approval)
                }
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
                if let task = store.approvalTask {
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
        if task.status == .waiting || store.displayedStatus(for: task) == "结果未知" { return "clock" }
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
                        IslandAgentLabel(text: store.calibrationPreview == nil ? store.primaryAgentName : "中态预览",
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
    }

    private var mediumStatus: some View {
        Group {
            // A failed decision has no live relay request, so approvalTask is
            // nil by then; the feedback must follow the highlighted task.
            if let outcome = store.approvalOutcome {
                outcomeLabel(outcome)
            } else if store.reviewingApproval != nil, store.approvalMinimized {
                // Ignored card tucked into the notch; hover or click brings it back.
                Button { store.revealApproval() } label: {
                    HStack(spacing: 5) {
                        Circle().fill(HUDColorTokens.attention).frame(width: 6, height: 6)
                            .modifier(AgentActivityEffect(executing: true, visible: animationActive))
                        Text(store.pendingApprovalTasks.count > 1 ? "\(store.pendingApprovalTasks.count) 个待批" : "待批")
                    }
                    .foregroundStyle(HUDColorTokens.attention)
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(HUDColorTokens.attention.opacity(0.18), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("有请求等你批准，移到岛上即可展开")
            } else if let task = store.activeTask, store.failedApprovals.contains(task.id) {
                failedButton(task: task, text: "回 App 处理")
            } else if let task = store.approvalTask, store.approvalRequest(for: task) != nil,
                      store.calibrationPreview == nil {
                Button("批准…") { store.reviewApproval(for: task) }
                    .buttonStyle(.plain).foregroundStyle(HUDColorTokens.attention)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(HUDColorTokens.attention.opacity(0.18), in: Capsule())
                    .help("查看本次请求并直接批准，无需打开应用")
            } else if let task = store.activeTask, store.approvalFeedback(for: task) != nil {
                detailButton(title: "等 App 确认", tint: HUDColorTokens.attention)
            } else {
                detailButton(title: store.mediumStatusText, tint: .white.opacity(0.8))
            }
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
    }

    @ViewBuilder private func outcomeLabel(_ outcome: TaskStore.ApprovalOutcome) -> some View {
        switch outcome.kind {
        case .allowed:
            Label(outcome.text, systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color(red: 0.3, green: 0.85, blue: 0.45))
                .frame(maxWidth: .infinity, minHeight: surface.layout.notchHeight, alignment: .trailing)
        case .denied:
            Label(outcome.text, systemImage: "xmark.circle.fill")
                .foregroundStyle(.white.opacity(0.7))
                .frame(maxWidth: .infinity, minHeight: surface.layout.notchHeight, alignment: .trailing)
        case .failed:
            if let task = store.tasks.first(where: { $0.id == outcome.taskID }) {
                failedButton(task: task, text: outcome.text)
            }
        }
    }

    /// Failure says what happened and goes straight to where it can be handled.
    private func failedButton(task: AgentTask, text: String) -> some View {
        Button {
            if let url = store.openFailedApproval(task) { NSWorkspace.shared.open(url) }
            else { AgentPresence.shared.open(task.profile.kind) }
        } label: {
            HStack(spacing: 4) {
                Text(text)
                Image(systemName: "arrow.up.forward").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(HUDColorTokens.attention)
            .frame(maxWidth: .infinity, minHeight: surface.layout.notchHeight, alignment: .trailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("没有自动批准；点这里打开对应的对话处理")
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
    @ObservedObject private var conversationTitles = ConversationTitleStore.shared
    @ObservedObject private var stepList = StepListDisclosure.shared

    var body: some View {
        let sections = TaskVisualSection.grouped(store.sortedTasks.map { task in
            TaskVisualItem(task: task, state: visualState(for: task))
        })
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                LinglongtaiBrandMark(size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agent 灵动岛")
                        .font(HUDTypography.pageTitle)
                        .tracking(0.2)
                        .foregroundStyle(.white)
                    Text(store.demoPreviewActive ? "演示预览 · 非真实状态" : "你的 Agent 管家")
                        .font(HUDTypography.caption)
                        .foregroundStyle(.white.opacity(0.48))
                        .lineLimit(1)
                }
                Spacer()
                Metric(value: String(sections.first { $0.group == .active }?.items.count ?? 0), label: "进行中", tint: HUDColorTokens.info)
                Metric(value: String(sections.first { $0.group == .ended }?.items.count ?? 0), label: "已结束", tint: HUDColorTokens.neutral)
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

            HUDSectionDivider()

            TodayUsageBar(usage: store.todayAgentUsage, showsDuration: !store.demoPreviewActive)
            HUDSectionDivider()

            HStack(spacing: 0) {
                taskList(sections: sections).frame(width: IslandLayout.taskListWidth)
                HUDSectionDivider(vertical: true)
                detailPane
                    .frame(width: IslandLayout.detailWidth)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func visualState(for task: AgentTask) -> TaskVisualState {
        TaskVisualState.resolve(task, displayedStatus: store.displayedStatus(for: task),
                                needsAttention: store.needsUserAttention(task))
    }

    private func taskList(sections: [TaskVisualSection]) -> some View {
        let selectedID = store.selectedTask?.id
        return VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("最近 24 小时")
                    .font(HUDTypography.captionEmphasis)
                    .foregroundStyle(.white.opacity(0.46))
                Spacer()
                Text("进行中优先").font(HUDTypography.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)

            ScrollViewReader { scroll in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: 0).id("task-list-top")
                        LazyVStack(spacing: 7) {
                            if sections.isEmpty {
                                Text("最近 24 小时暂无会话记录").font(HUDTypography.body)
                                    .foregroundStyle(.secondary).padding(.vertical, 24)
                            }
                            ForEach(sections) { section in
                                HStack(spacing: 6) {
                                    Text(section.group.title)
                                    Text(String(section.items.count)).monospacedDigit()
                                    Spacer()
                                }
                                .font(HUDTypography.captionEmphasis)
                                .foregroundStyle(.white.opacity(section.group == .ended ? 0.38 : 0.62))
                                .padding(.horizontal, 9)
                                .padding(.top, section.group == sections.first?.group ? 0 : 10)
                                .padding(.bottom, 1)
                                .accessibilityAddTraits(.isHeader)
                                ForEach(section.items) { item in
                                    TaskRow(task: item.task, title: conversationTitles.title(for: item.task),
                                            isSelected: selectedID == item.id, state: item.state,
                                            animationActive: store.presentation == .heavy,
                                            approvalPending: item.task.status == .waiting && item.task.requiresApproval
                                                && store.approvalRequest(for: item.task) != nil) {
                                        store.selectOrReview(item.task)
                                    }
                                    // The outer identity stays the task UUID.
                                    // Reset only the row's semantic presentation
                                    // when SwiftUI moves it between lazy groups.
                                    .id("\(item.id.uuidString)-\(item.state)")
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                    }
                }
                .onChange(of: store.presentation) { presentation in
                    guard presentation == .heavy else { return }
                    resetTaskListToTop(scroll)
                }
                .onAppear {
                    if store.presentation == .heavy { resetTaskListToTop(scroll) }
                }
            }
        }
        .padding(.top, 14)
        .background(Color.white.opacity(0.035))
    }

    private func resetTaskListToTop(_ scroll: ScrollViewProxy) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            scroll.scrollTo("task-list-top", anchor: .top)
        }
    }

    private var detailPane: some View {
        Group {
            if let task = store.selectedTask {
                let state = visualState(for: task)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center, spacing: 8) {
                        AgentAvatar(task: task, size: 32)
                        Text(task.agent)
                            .font(HUDTypography.bodyEmphasis)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.9)
                        Spacer(minLength: 4)
                        if task.profile.kind != .custom {
                            Button {
                                presence.open(task.profile.kind)
                            } label: {
                                Text(presence.opening.contains(task.profile.kind) ? "正在打开…" : "打开应用")
                                    .font(HUDTypography.captionEmphasis)
                                    .foregroundStyle(HUDColorTokens.info)
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 7)
                                    .background(HUDColorTokens.info.opacity(0.14), in: Capsule())
                                    // Match the interaction region to the visible pill,
                                    // including the padding, not only its text glyphs.
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .fixedSize()
                            .disabled(presence.opening.contains(task.profile.kind))
                            .help("打开桌面应用；终端和 IDE 任务请回到原会话处理。")
                        }
                    }

                    if let error = presence.launchErrors[task.profile.kind] {
                        Text(error).font(HUDTypography.caption)
                            .foregroundStyle(HUDColorTokens.attention).padding(.top, 8)
                    }
                    // Fixed identity: which conversation, and its state at a glance.
                    Text(conversationTitles.title(for: task))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 14)
                        .textSelection(.enabled)
                    HStack(spacing: 8) {
                        TaskStateIndicator(state: state, visible: store.presentation == .heavy,
                                           label: state == .completed ? "已完成" : state == .failed ? "出错了" : store.plainStatus(for: task))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(state.tint.opacity(0.14), in: Capsule())
                        Text(task.updatedAt, style: .time).monospacedDigit()
                            .font(HUDTypography.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if state == .failed {
                            Button {
                                store.resyncStatus(for: task)
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(HUDColorTokens.info)
                                    .frame(width: 24, height: 24)
                                    .background(HUDColorTokens.info.opacity(0.14), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .help("重新同步状态；不会重新执行任务")
                            .accessibilityLabel("重新同步状态，不会重新执行任务")
                        }
                    }
                    .padding(.top, 8)

                    // A hairline marks where the fixed part ends; the fade at the
                    // bottom says there is more below.
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                        .padding(.top, 14)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            // Ended turns need no card: the pill and 打开应用 say it all.
                            // Live or unknown turns keep one plain line of what is happening.
                            if state.group != .ended || state == .unknown || state == .untracked {
                                Text(state.unknownExplanation ?? store.currentStepText(for: task))
                                    .font(HUDTypography.body)
                                    .foregroundStyle(.white.opacity(0.72))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            stepDetails(for: task)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 14)
                        // Same as the task list: the scroll runs to the pane's
                        // bottom edge and the breathing room lives inside it.
                        .padding(.bottom, 24)
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                    .mask(
                        VStack(spacing: 0) {
                            Color.black
                            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                                .frame(height: 20)
                        }
                    )

                    if hasDetailActions(for: task) {
                        actionBar(for: task)
                            .padding(.top, 12)
                            .padding(.bottom, 12)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.white.opacity(0.42))
                    Text("等待任务事件")
                        .font(HUDTypography.bodyEmphasis)
                        .foregroundStyle(.white.opacity(0.58))
                    ForEach(AgentCatalog.supportedKinds, id: \.self) { kind in
                        HStack {
                            Text(kind.displayName)
                            Spacer()
                            Text(store.connectionLabel(for: kind)).foregroundStyle(.secondary)
                        }
                        .font(HUDTypography.body)
                    }
                    .padding(.horizontal, 24)
                    Text("收到真实事件后显示；不推测任务进度。")
                        .font(HUDTypography.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Only long turns get a per-step list; the card's second line covers the rest.
    @ViewBuilder private func stepDetails(for task: AgentTask) -> some View {
        if task.hasUnidentifiedToolSteps {
            Text("部分步骤没有编号，次数可能偏多")
                .font(HUDTypography.caption).foregroundStyle(.secondary)
        }
        // The card stays one sentence; how much work happened lives behind
        // a single quiet link, opened only when someone wants it.
        if !task.returnedToolSteps.isEmpty {
            let expanded = stepList.expandedTaskID == task.id
            let failed = task.failedToolStepCount
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    stepList.expandedTaskID = expanded ? nil : task.id
                } label: {
                    HStack(spacing: 4) {
                        Text("\(task.returnedToolSteps.count) 个步骤" + (failed > 0 ? " · \(failed) 次出错" : ""))
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(HUDTypography.caption)
                    .foregroundStyle(HUDColorTokens.info)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expanded {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(task.returnedToolSteps.prefix(30))) { step in
                            HStack(alignment: .top) {
                                Text(step.label + (step.state == .failed ? " · 出错" : ""))
                                    .foregroundStyle(step.state == .failed ? HUDColorTokens.attention : .white.opacity(0.72))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(step.updatedAt, style: .time).monospacedDigit().foregroundStyle(.secondary)
                            }.font(HUDTypography.caption)
                        }
                        if task.returnedToolSteps.count > 30 {
                            Text("只列出最近 30 条").font(HUDTypography.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }

    private func hasDetailActions(for task: AgentTask) -> Bool {
        store.approvalRequest(for: task) != nil || store.displayedStatus(for: task) == "结果未知"
            || detailFooterText(for: task) != nil
    }

    private func detailFooterText(for task: AgentTask) -> String? {
        store.approvalFeedback(for: task)
            ?? store.approvalSurfaceText(for: task)
            ?? (store.needsUserAttention(task) && store.approvalRequest(for: task) == nil ? "在 App 里处理" : nil)
    }

    private func actionBar(for task: AgentTask) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.approvalRequest(for: task) != nil {
                ActionButton(title: "批准请求…", systemName: "hand.raised", tint: HUDColorTokens.attention) {
                    store.reviewApproval(for: task)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                if store.displayedStatus(for: task) == "结果未知" {
                    Button("从岛上移除") { store.dismissTask(task) }
                        .font(HUDTypography.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .help("只移除本地显示，不会停止 Agent；后续真实事件仍可再次出现。")
                }
                Spacer(minLength: 8)
                if let footerText = detailFooterText(for: task) {
                    Text(footerText)
                        .font(HUDTypography.caption)
                        .foregroundStyle(.white.opacity(0.32))
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                }
            }
        }
    }
}


/// Which task's step list is open. Keyed by task so switching tasks closes it.
private final class StepListDisclosure: ObservableObject {
    static let shared = StepListDisclosure()
    @Published var expandedTaskID: UUID?
}

private struct LiveOrb: View {
    var size: CGFloat = 24

    var body: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.08))
            Circle().fill(AngularGradient(colors: [HUDColorTokens.info, HUDColorTokens.claude, Color.white.opacity(0.72), HUDColorTokens.info], center: .center)).padding(4)
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
            Text(value).font(HUDTypography.metric).monospacedDigit().foregroundStyle(tint)
            Text(label).font(HUDTypography.caption).foregroundStyle(.white.opacity(0.35))
        }
        .frame(minWidth: 36)
    }
}

private struct AgentAvatar: View {
    let task: AgentTask?
    let size: CGFloat

    var body: some View {
        let color = task.map { HUDColorTokens.agent($0.profile.kind) } ?? HUDColorTokens.neutral
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
    let title: String
    let isSelected: Bool
    let state: TaskVisualState
    let animationActive: Bool
    let approvalPending: Bool
    let onSelect: () -> Void

    private var isEnded: Bool { state.group == .ended }
    private var isEmphasized: Bool { state.group == .active }

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 10) {
                AgentAvatar(task: task, size: 28)
                    .opacity(isEnded ? 0.56 : state == .unknown || state == .untracked ? 0.72 : 1)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(task.agent)
                            .font(.system(size: 12, weight: isEmphasized ? .semibold : .medium))
                            .foregroundStyle(.white.opacity(isEnded ? 0.58 : state == .unknown || state == .untracked ? 0.76 : 1))
                        Spacer(minLength: 4)
                        Text(task.updatedAt, style: .time)
                            .font(.system(size: 9)).monospacedDigit()
                            .foregroundStyle(.white.opacity(0.42))
                            .fixedSize()
                    }
                    Text(title)
                        .font(HUDTypography.caption)
                        .foregroundStyle(.white.opacity(isEnded ? 0.48 : 0.65))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(title)
                    HStack(spacing: 6) {
                        TaskStateIndicator(state: state, visible: animationActive)
                        Spacer(minLength: 4)
                        if approvalPending {
                            Text("批准…")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(HUDColorTokens.attention)
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(HUDColorTokens.attention.opacity(0.16), in: Capsule())
                        }
                        Text(String(task.id.uuidString.prefix(6)))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.white.opacity(0.09) : Color.white.opacity(isEmphasized ? 0.045 : 0), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .leading) {
                if isEmphasized {
                    Capsule().fill(state.tint.opacity(0.75))
                        .frame(width: 2).padding(.vertical, 12)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(task.agent)，\(title)，\(state.label)\(isSelected ? "，已选中" : "")")
        .accessibilityAddTraits(.isButton)
        .help(title + " · " + state.label)
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
                .font(HUDTypography.captionEmphasis)
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
        case .queued: return HUDColorTokens.neutral
        case .running: return HUDColorTokens.info
        case .waiting: return HUDColorTokens.attention
        case .completed: return HUDColorTokens.success
        case .failed: return HUDColorTokens.danger
        case .cancelled: return HUDColorTokens.neutral
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
