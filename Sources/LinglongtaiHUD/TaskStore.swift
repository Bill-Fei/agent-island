import Combine
import Foundation
import LinglongtaiShared

@MainActor
final class TaskStore: ObservableObject {
    static let shared = TaskStore()

    typealias Presentation = IslandPresentation

    enum TaskAction {
        case approve
        case retry
        case stop
    }

    @Published var tasks: [AgentTask] = [] {
        didSet { invalidateTaskCache() }
    }
    @Published private(set) var presentation: Presentation = .collapsed
    private var interaction = IslandInteraction()
    @Published var selectedTaskID: UUID?
    @Published var notice = "等待实时 Agent 事件"
    @Published var autoPopOnEvent: Bool
    @Published var heavyOnHover: Bool
    @Published var notchOffset: Double
    @Published var notchWidthAdjustment: Double
    @Published var activityWidth: Double
    @Published private(set) var automaticActivityWidth: Bool
    @Published private(set) var demoPreviewActive = false
    @Published private(set) var connections: [String: Date] = [:]
    @Published private(set) var reviewingApproval: ApprovalRelay.Request?
    @Published private(set) var submittedApprovals: [UUID: Date] = [:]
    @Published private(set) var failedApprovals: Set<UUID> = []
    private(set) var contextMenuIsOpen = false

    func approvalRequest(for task: AgentTask) -> ApprovalRelay.Request? {
        guard ApprovalRelay.islandApprovalEnabled else { return nil }
        guard let current = tasks.first(where: { $0.id == task.id }),
              current.approvalRequestID == task.approvalRequestID,
              current.updatedAt == task.updatedAt,
              current.source.isLive, current.status == .waiting, current.requiresApproval,
              current.sourceEvent != "AmbiguousTurn", now().timeIntervalSince(current.updatedAt) <= 86_400,
              now().timeIntervalSince(current.updatedAt) >= -5,
              let id = current.approvalRequestID else { return nil }
        return ApprovalRelay.pending(id, taskID: task.id, now: now())
    }

    func approvalFeedback(for task: AgentTask) -> String? {
        if failedApprovals.contains(task.id) { return "未提交决定 · 请在原应用核实" }
        guard let id = task.approvalRequestID, let date = submittedApprovals[id], task.status == .waiting else { return nil }
        return now().timeIntervalSince(date) < 30 ? "已提交决定 · 等待回执" : "尚未收到回执 · 请核实"
    }

    func currentStepText(for task: AgentTask) -> String {
        if let feedback = approvalFeedback(for: task) { return feedback }
        if approvalRequest(for: task) != nil { return "请求单次批准 · 请核对本次工具操作" }
        if displayedStatus(for: task) == "等待状态更新" { return "等待真实活动更新" }
        if task.status == .waiting && task.sourceEvent == "PermissionRequest" {
            return "应用正在核对工具权限，灵动岛不接管审批"
        }
        if task.sourceEvent == "PreToolUse",
           let step = task.toolSteps.filter({ $0.state == .running }).max(by: { $0.updatedAt < $1.updatedAt }) {
            return step.label
        }
        return task.detail
    }

    func reviewApproval(for task: AgentTask) {
        reviewingApproval = approvalRequest(for: task)
        refreshPresentation()
    }

    func closeApproval() {
        reviewingApproval = nil
        resetInteraction()
    }

    func respondToApproval(_ request: ApprovalRelay.Request, decision: ApprovalRelay.Decision) {
        guard let task = tasks.first(where: { $0.id == request.taskID }),
              approvalRequest(for: task) == request,
              ApprovalRelay.respond(to: request, decision: decision) else {
            notice = "批准请求已过期或被处理，请在原应用核实"
            failedApprovals.insert(request.taskID)
            mediumUntil = now().addingTimeInterval(10)
            eventPulseUntil = mediumUntil
            highlightedTaskID = request.taskID
            closeApproval()
            return
        }
        notice = "已提交本次决定，等待 Agent 的真实回调"
        submittedApprovals[request.id] = now()
        failedApprovals.remove(request.taskID)
        closeApproval()
    }
    private var previewTasks: [AgentTask] = [] {
        didSet { invalidateTaskCache() }
    }

    // These values are read from several view branches. Cache them between
    // meaningful store changes so a 120 Hz surface tick never sorts the full
    // history repeatedly just to decide what the ambient island should show.
    private var visibleTasksCache: [AgentTask]?
    private var sortedTasksCache: [AgentTask]?
    private var liveTasksCache: [AgentTask]?
    private var freshLiveTasksCache: [AgentTask]?
    private var waitingCountCache: Int?
    private var usageCache: (day: Date, values: [AgentUsageCount])?
    private var statusSignatureCache: String?
    private var taskCacheExpiresAt = Date.distantPast
    private var visibleStateSignature = ""

    private var eventOffset: UInt64 = 0
    private var eventTimer: Timer?
    private var eventPollInFlight = false
    private var checkpointNeedsRetry = false
    private var checkpointGeneration: UInt64 = 0
    private let checkpointQueue = DispatchQueue(label: "com.billfei.linglongtai.checkpoint", qos: .utility)
    private var doubaoTracker = DoubaoTracker()
    private var lastDoubaoPoll = Date.distantPast
    private var doubaoPollInFlight = false
    private static let doubaoPollInterval: TimeInterval = 3
    private var eventPulseUntil = Date.distantPast
    private var mediumUntil = Date.distantPast
    private var highlightedTaskID: UUID?
    @Published private(set) var calibrationPreview: Presentation?
    private var calibrationUntil = Date.distantPast
    private let now: () -> Date
    private struct Snapshot: Codable, Sendable {
        var tasks: [AgentTask]
        var eventOffset: UInt64
        var connections: [String: Date]?
        var version: Int?
    }

    private let autoPopKey = "dynamicIsland.autoPopOnEvent"
    private let heavyOnHoverKey = "dynamicIsland.heavyOnHover"
    private let notchOffsetKey = "dynamicIsland.notchOffset"
    private let notchWidthAdjustmentKey = "dynamicIsland.notchWidthAdjustment"
    private let activityWidthKey = "dynamicIsland.activityWidth"
    private let automaticActivityWidthKey = "dynamicIsland.automaticActivityWidth"
    private let isAcceptancePreview: Bool
    private var isIsolatedRun: Bool {
        isAcceptancePreview || ProcessInfo.processInfo.arguments.contains("--data-dir")
    }

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
        let arguments = ProcessInfo.processInfo.arguments
        isAcceptancePreview = arguments.contains("--qa-empty") || arguments.contains("--qa-demo")
        autoPopOnEvent = UserDefaults.standard.object(forKey: autoPopKey) as? Bool ?? true
        heavyOnHover = UserDefaults.standard.object(forKey: heavyOnHoverKey) as? Bool ?? true
        notchOffset = UserDefaults.standard.object(forKey: notchOffsetKey) as? Double ?? 0
        notchWidthAdjustment = UserDefaults.standard.object(forKey: notchWidthAdjustmentKey) as? Double ?? 0
        activityWidth = UserDefaults.standard.object(forKey: activityWidthKey) as? Double ?? 228
        automaticActivityWidth = UserDefaults.standard.object(forKey: automaticActivityWidthKey) as? Bool ?? true
        // Acceptance launches are entirely in-memory: never overwrite personal tasks.
        if isAcceptancePreview {
            autoPopOnEvent = true
            heavyOnHover = true
            notchOffset = 0
            notchWidthAdjustment = 0
            activityWidth = 228
            automaticActivityWidth = true
            tasks = arguments.contains("--qa-demo") ? Self.demoTasks : []
            selectedTaskID = sortedTasks.first?.id
            notice = "验收预览 · 不写入个人任务"
            refreshPresentation()
            return
        }
        LinglongtaiPaths.prepare()
        loadTasks()
        selectedTaskID = sortedTasks.first?.id
        consumeEvents()
        refreshPresentation()
        let timer = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollEvents()
                self?.consumeDoubaoTrajectories()
                self?.refreshPresentation()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        eventTimer = timer
    }

    var sortedTasks: [AgentTask] {
        refreshTaskCacheIfNeeded()
        if let sortedTasksCache { return sortedTasksCache }
        let sorted = displayTasks.sorted { lhs, rhs in
            let leftRank = needsUserAttention(lhs) ? 0 : ([.queued, .running, .waiting].contains(lhs.status) ? 1 : 2)
            let rightRank = needsUserAttention(rhs) ? 0 : ([.queued, .running, .waiting].contains(rhs.status) ? 1 : 2)
            if leftRank != rightRank { return leftRank < rightRank }
            if lhs.updatedAt == rhs.updatedAt { return lhs.id.uuidString < rhs.id.uuidString }
            return lhs.updatedAt > rhs.updatedAt
        }
        sortedTasksCache = sorted
        return sorted
    }

    /// Only event-backed rows are allowed to drive the live HUD in normal
    /// mode. Unknown/legacy rows remain on disk for recovery but cannot be
    /// mistaken for current provider progress.
    private var displayTasks: [AgentTask] {
        refreshTaskCacheIfNeeded()
        if let visibleTasksCache { return visibleTasksCache }
        let candidates = demoPreviewActive ? previewTasks : tasks
        let reference = now()
        let visible = candidates.filter {
            ($0.source.isLive || demoPreviewActive || isAcceptancePreview) &&
            reference.timeIntervalSince($0.updatedAt) <= 86_400 &&
            reference.timeIntervalSince($0.updatedAt) >= -5
        }
        visibleTasksCache = visible
        taskCacheExpiresAt = nextTaskCacheBoundary(for: candidates, after: reference)
        return visible
    }

    var selectedTask: AgentTask? {
        guard let selectedTaskID else { return sortedTasks.first }
        return displayTasks.first(where: { $0.id == selectedTaskID }) ?? sortedTasks.first
    }

    var liveTasks: [AgentTask] {
        refreshTaskCacheIfNeeded()
        if let liveTasksCache { return liveTasksCache }
        let live = sortedTasks.filter { $0.source.isLive && [.queued, .running, .waiting].contains($0.status) }
        liveTasksCache = live
        return live
    }

    /// A task can remain visible for a long time without a provider callback,
    /// but that is not evidence that it is still executing. Ambient animation
    /// must follow a fresh real task when one exists; stale rows stay available
    /// for history and the details view.
    var freshLiveTasks: [AgentTask] {
        refreshTaskCacheIfNeeded()
        if let freshLiveTasksCache { return freshLiveTasksCache }
        let fresh = liveTasks.filter { isFresh($0) }
        freshLiveTasksCache = fresh
        return fresh
    }

    var waitingCount: Int {
        refreshTaskCacheIfNeeded()
        if let waitingCountCache { return waitingCountCache }
        let count = displayTasks.filter { needsUserAttention($0) }.count
        waitingCountCache = count
        return count
    }

    private func invalidateTaskCache() {
        visibleTasksCache = nil
        sortedTasksCache = nil
        liveTasksCache = nil
        freshLiveTasksCache = nil
        waitingCountCache = nil
        usageCache = nil
        statusSignatureCache = nil
        taskCacheExpiresAt = .distantPast
    }

    /// Time-dependent presentation rules only change at task boundaries:
    /// visibility at 24 hours / -5 seconds and attention freshness at 120
    /// seconds. Keep the derived arrays stable between those boundaries so
    /// the hover display clock never sorts the full history on every tick.
    private func refreshTaskCacheIfNeeded() {
        guard now() >= taskCacheExpiresAt else { return }
        invalidateTaskCache()
    }

    private func nextTaskCacheBoundary(for candidates: [AgentTask], after reference: Date) -> Date {
        let boundaries = candidates.flatMap { task in
            [
                task.updatedAt.addingTimeInterval(-5),
                task.updatedAt,
                task.updatedAt.addingTimeInterval(120),
                task.updatedAt.addingTimeInterval(DoubaoTrajectory.staleAfter),
                task.updatedAt.addingTimeInterval(86_400)
            ]
        }.filter { $0 >= reference }
        if let boundary = boundaries.min() {
            // Keep the exact 24-hour boundary visible (the filter uses <=),
            // then invalidate on the next clock sample instead of allowing a
            // one-second fallback cache window to hide the transition.
            return boundary == reference ? reference.addingTimeInterval(0.000_001) : boundary
        }
        // There is always a short-lived validity window even for an empty
        // store, so a clock change or newly-created task cannot stay cached.
        return reference.addingTimeInterval(1)
    }

    /// PermissionRequest starts a permission check, which may be handled by
    /// automatic review. Only a live island request proves a user can act here.
    /// Keep the raw lifecycle state intact; this is a presentation distinction.
    func needsUserAttention(_ task: AgentTask) -> Bool {
        guard task.status == .waiting, task.sourceEvent != "AmbiguousTurn", isFresh(task) else { return false }
        if task.approvalRequestID != nil || task.sourceEvent == "PermissionRequest" {
            return approvalRequest(for: task) != nil
        }
        return true // Explicit provider notifications and custom waiting events.
    }

    var hasLiveEvent: Bool {
        !liveTasks.isEmpty || now() < eventPulseUntil
    }

    func latestLiveTask(for kind: AgentKind) -> AgentTask? {
        guard let latest = latestKnownLiveTask(for: kind), isFresh(latest) else { return nil }
        return latest
    }

    func latestKnownLiveTask(for kind: AgentKind) -> AgentTask? {
        tasks.filter { $0.source.isLive && $0.profile.kind == kind }
            .max { $0.updatedAt < $1.updatedAt }
    }

    func statusSummary(for kind: AgentKind) -> String {
        guard let task = liveTasks.first(where: { $0.profile.kind == kind }) else {
            if latestKnownLiveTask(for: kind) != nil { return "当前无进行中的会话" }
            return connections[kind.rawValue] == nil ? "等待首次任务回调" : "已收到连接 · 等待任务"
        }
        let age = max(0, now().timeIntervalSince(task.updatedAt))
        let freshness = age < 120 ? "刚刚" : "更新于 " + Self.relativeAge(age)
        if !isFresh(task) && [.queued, .running, .waiting].contains(task.status) {
            return "尚未收到结束 · \(freshness)"
        }
        if task.status == .running || task.status == .queued {
            let progress = task.progressKnown ? " · \(Int(task.progress * 100))%" : ""
            return "\(task.statusLabel)\(progress) · \(freshness)"
        }
        return "\(displayedStatus(for: task)) · \(freshness)"
    }

    func connectionLabel(for kind: AgentKind) -> String {
        // Doubao has no hook to call back from; its state arrives by trajectory.
        if kind == .doubao { return "读本地轨迹" }
        return connections[kind.rawValue] == nil ? "未收到回调" : "收到过回调"
    }

    func displayedStatus(for task: AgentTask) -> String {
        if task.sourceEvent == "DoubaoAbandoned" || task.sourceEvent == "DoubaoSilent" { return task.statusLabel }
        if task.sourceEvent == "AmbiguousTurn" { return "等待状态更新" }
        if task.source.isLive && !isFresh(task) && [.queued, .running, .waiting].contains(task.status) { return "等待状态更新" }
        if task.status == .waiting && !needsUserAttention(task) {
            if task.sourceEvent == "PermissionRequest" { return "权限检查中" }
            if let id = task.approvalRequestID, submittedApprovals[id] != nil { return "等待回执" }
            return task.approvalRequestID == nil ? "权限检查中" : "等待权限结果"
        }
        return task.statusLabel
    }

    var activeTask: AgentTask? {
        if let waiting = liveTasks.first(where: { needsUserAttention($0) }) { return waiting }
        if now() < eventPulseUntil, let highlightedTaskID,
           let task = tasks.first(where: { $0.id == highlightedTaskID }) { return task }
        if let selectedTask, (selectedTask.source.isLive || demoPreviewActive || isAcceptancePreview),
           (demoPreviewActive || isAcceptancePreview || [.queued, .running, .waiting].contains(selectedTask.status)),
           [.queued, .running, .waiting].contains(selectedTask.status) {
            // Keep a live selection stable while it is fresh. Once it becomes
            // stale, do not let it mask another task that is actively sending
            // real events; the island's executing glyph should describe that
            // fresh task instead of a silent historical row.
            if demoPreviewActive || isAcceptancePreview || isFresh(selectedTask) {
                return selectedTask
            }
            if let fresh = freshLiveTasks.first(where: { $0.status == .running }) ?? freshLiveTasks.first {
                return fresh
            }
            return selectedTask
        }
        if let current = freshLiveTasks.first(where: { $0.status == .running }) ?? freshLiveTasks.first {
            return current
        }
        if let current = liveTasks.first { return current }
        return demoPreviewActive || isAcceptancePreview ? selectedTask : nil
    }

    var primaryAgentName: String {
        activeTask?.agent ?? "Agent 灵动岛"
    }

    var activeTaskIsExecuting: Bool {
        calibrationPreview == nil && AgentActivityMotion.isExecuting(activeTask, now: now())
    }

    /// Preserve task identity, including simultaneous tasks from the same app.
    /// Finished history never creates an ambient icon or increments live counts.
    var islandIconTasks: [AgentTask] {
        guard let front = activeTask else { return [] }
        return [front] + liveTasks.filter { $0.id != front.id }.prefix(3)
    }

    var mediumStatusText: String {
        if calibrationPreview != nil { return "尺寸预览" }
        if waitingCount > 0 { return "\(waitingCount)项待确认" }
        if now() < eventPulseUntil, let task = activeTask,
           [.completed, .failed, .cancelled].contains(task.status) {
            return liveTasks.isEmpty ? task.statusLabel : "1项结束 · \(liveTasks.count)项未结束"
        }
        if liveTasks.count > 1 {
            let fresh = freshLiveTasks.count
            return fresh == liveTasks.count ? "\(fresh)项有活动" : "\(fresh)项活跃 · \(liveTasks.count - fresh)项待更新"
        }
        guard let task = activeTask else { return "等待事件" }
        return displayedStatus(for: task)
    }

    var compactCountText: String {
        waitingCount > 0 ? "\(waitingCount)" : liveTasks.isEmpty ? "" : "\(liveTasks.count)"
    }

    // MARK: - Content-driven medium width

    /// Wing width asked for by the strings the medium surface renders today.
    /// `nil` leaves the historical fixed width untouched.
    @Published private(set) var mediumWingWidth: Double? = nil
    /// Growing applies at once; shrinking waits, because status strings cycle
    /// ("3项进行中" → "运行中" → "3项进行中") and the outline must not breathe.
    private var pendingNarrowWidth: Double? = nil
    private var pendingNarrowSince: Date? = nil
    private static let narrowHold: TimeInterval = 1.5

    /// The status side gains a capsule when it renders "批准…" or a waiting pill.
    private var mediumStatusReserve: Double {
        guard let task = activeTask else { return 0 }
        let decorated = failedApprovals.contains(task.id)
            || approvalRequest(for: task) != nil
            || approvalFeedback(for: task) != nil
            || waitingCount > 0
        return decorated ? 16 : 0
    }

    private func refreshContentWidth() {
        guard automaticActivityWidth else {
            if mediumWingWidth != nil { mediumWingWidth = nil }
            pendingNarrowWidth = nil
            pendingNarrowSince = nil
            return
        }
        let name = calibrationPreview == nil ? primaryAgentName : "尺寸预览"
        let iconSize = min(24, max(0, 32 + notchOffset - 4))
            * (1 + Double(max(0, islandIconTasks.count - 1)) * 0.34)
        let content = IslandContentWidth.medium(agentName: name, statusText: mediumStatusText,
                                               iconSize: iconSize, statusReserve: mediumStatusReserve)
        let target = content.wingWidth()
        guard let current = mediumWingWidth else {
            mediumWingWidth = target
            return
        }
        if target >= current {
            if target != current { mediumWingWidth = target }
            pendingNarrowWidth = nil
            pendingNarrowSince = nil
            return
        }
        if pendingNarrowWidth != target {
            pendingNarrowWidth = target
            pendingNarrowSince = now()
            return
        }
        if let since = pendingNarrowSince, now().timeIntervalSince(since) >= Self.narrowHold {
            mediumWingWidth = target
            pendingNarrowWidth = nil
            pendingNarrowSince = nil
        }
    }

    func samplePointer(inside: Bool, at time: TimeInterval) {
        guard !contextMenuIsOpen else { return }
        guard reviewingApproval == nil else { return }
        let previous = interaction
        interaction.samplePointer(inside: inside, at: time)
        if interaction != previous { refreshPresentation() }
    }

    func resetInteraction() {
        contextMenuIsOpen = false
        reviewingApproval = nil
        interaction = IslandInteraction()
        refreshPresentation()
    }

    func setAutoPopOnEvent(_ enabled: Bool) {
        autoPopOnEvent = enabled
        if !isIsolatedRun { UserDefaults.standard.set(enabled, forKey: autoPopKey) }
        refreshPresentation()
    }

    func setHeavyOnHover(_ enabled: Bool) {
        heavyOnHover = enabled
        if !isIsolatedRun { UserDefaults.standard.set(enabled, forKey: heavyOnHoverKey) }
        refreshPresentation()
    }

    func setNotchOffset(_ offset: Double) {
        notchOffset = min(max(offset, -12), 24)
        if !isIsolatedRun { UserDefaults.standard.set(notchOffset, forKey: notchOffsetKey) }
        previewCalibration(.medium)
    }

    func setNotchWidthAdjustment(_ adjustment: Double) {
        notchWidthAdjustment = min(max(adjustment, -56), 96)
        if !isIsolatedRun {
            UserDefaults.standard.set(notchWidthAdjustment, forKey: notchWidthAdjustmentKey)
        }
        previewCalibration(.medium)
    }

    func setActivityWidth(_ value: Double) {
        setAutomaticActivityWidth(false, preview: false)
        activityWidth = min(max(value, 200), 300)
        if !isIsolatedRun { UserDefaults.standard.set(activityWidth, forKey: activityWidthKey) }
        previewCalibration(.medium)
    }

    func setAutomaticActivityWidth(_ enabled: Bool, preview: Bool = true) {
        if automaticActivityWidth != enabled { automaticActivityWidth = enabled }
        if !isIsolatedRun { UserDefaults.standard.set(enabled, forKey: automaticActivityWidthKey) }
        if preview { previewCalibration(.medium) }
    }

    func previewCalibration(_ state: Presentation = .medium) {
        calibrationPreview = state
        calibrationUntil = now().addingTimeInterval(6)
        refreshPresentation()
    }

    func resetCalibration() {
        setNotchOffset(0)
        setNotchWidthAdjustment(0)
        setActivityWidth(228)
        setAutomaticActivityWidth(true)
    }

    deinit {
        eventTimer?.invalidate()
    }

    func toggleExpanded() {
        interaction.toggleExpanded(from: presentation)
        refreshPresentation()
    }

    func showTaskDetails() {
        calibrationPreview = nil
        calibrationUntil = .distantPast
        if presentation != .heavy { interaction.toggleExpanded(from: presentation) }
        refreshPresentation()
    }

    func beginContextMenu() -> Bool {
        guard presentation == .heavy, !contextMenuIsOpen else { return false }
        contextMenuIsOpen = true
        return true
    }

    func endContextMenu(pointerInside: Bool = false) {
        guard contextMenuIsOpen else { return }
        contextMenuIsOpen = false
        interaction = IslandInteraction()
        // Escape/cancel over the island must not collapse and reopen it.
        if pointerInside { interaction.toggleExpanded(from: .collapsed) }
        refreshPresentation()
    }

    func select(_ task: AgentTask) {
        selectedTaskID = task.id
    }

    func perform(_ action: TaskAction, for task: AgentTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        let updated = tasks[index]
        let commandType: String
        let verb: String
        switch action {
        case .approve:
            reviewApproval(for: updated)
            return
        case .retry:
            commandType = "retry"
            verb = "已发送重试指令"
        case .stop:
            commandType = "stop"
            verb = "已发送停止指令"
        }
        // A button creates a request. The provider must send the resulting
        // state back as a live event before the HUD changes its status.
        notice = "\(verb)给 \(updated.agent)，等待 Agent 回执"
        appendCommand(type: commandType, taskID: updated.id)
        refreshPresentation()
    }

    func clearFinished() {
        if demoPreviewActive {
            previewTasks.removeAll { [.completed, .cancelled].contains($0.status) }
            selectedTaskID = sortedTasks.first?.id
            notice = "演示预览 · 仅清理预览任务"
            return
        }
        tasks.removeAll { [.completed, .cancelled].contains($0.status) }
        if selectedTaskID.flatMap({ id in tasks.first(where: { $0.id == id }) }) == nil {
            selectedTaskID = sortedTasks.first?.id
        }
        notice = "已清理完成任务"
        saveTasks()
        refreshPresentation()
    }

    func dismissTask(_ task: AgentTask) {
        tasks.removeAll { $0.id == task.id }
        if selectedTaskID == task.id { selectedTaskID = sortedTasks.first?.id }
        if highlightedTaskID == task.id {
            highlightedTaskID = nil
            eventPulseUntil = .distantPast
        }
        notice = "已移除本地显示，Agent 任务继续运行"
        saveTasks()
        refreshPresentation()
    }

    func clearAllTasks() {
        if demoPreviewActive {
            endDemoPreview()
            return
        }
        tasks.removeAll()
        eventPulseUntil = .distantPast
        mediumUntil = .distantPast
        highlightedTaskID = nil
        demoPreviewActive = false
        selectedTaskID = nil
        notice = "已清空任务历史"
        saveTasks()
        refreshPresentation()
    }

    func loadDemoTasks() {
        previewTasks = Self.demoTasks.map { task in
            var preview = task
            preview.source = .demo
            return preview
        }
        demoPreviewActive = true
        selectedTaskID = sortedTasks.first?.id
        notice = "演示预览 · 不代表实时 Agent 状态"
        // Demo data is deliberately memory-only. It must never become a
        // persisted snapshot that looks like a real agent is still running.
        refreshPresentation()
    }

    func endDemoPreview() {
        demoPreviewActive = false
        previewTasks = []
        eventPulseUntil = .distantPast
        mediumUntil = .distantPast
        highlightedTaskID = nil
        selectedTaskID = sortedTasks.first?.id
        notice = "已退出演示 · 真实任务未更改"
        refreshPresentation()
    }

    private func loadTasks() {
        if let data = try? Data(contentsOf: LinglongtaiPaths.state),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            tasks = snapshot.tasks
            eventOffset = snapshot.eventOffset
            connections = snapshot.connections ?? [:]
            if snapshot.version != 2 {
                recoverHookMetadata()
                saveTasks()
            }
            return
        }
        guard let data = try? Data(contentsOf: LinglongtaiPaths.tasks),
              let decoded = try? JSONDecoder().decode([AgentTask].self, from: data) else { return }
        let migrated = decoded.map { task in
            guard task.agent == "DeepSeek", task.model == "DeepSeek-V3" else { return task }
            var migrated = task
            migrated.agent = AgentKind.doubao.displayName
            migrated.model = AgentKind.doubao.defaultModel
            migrated.colorHex = AgentKind.doubao.colorHex
            migrated.detail = "已迁移到豆包 Agent"
            return migrated
        }
        // Older builds persisted the four preview rows. Keep the file intact
        // for recovery, but never surface that fixture as current progress.
        let filtered = migrated.filter { $0.source.isLive || !Self.isLegacyDemoFixture($0) }
        if !migrated.isEmpty && filtered.isEmpty {
            tasks = []
            notice = "等待实时 Agent 事件"
        } else {
            tasks = filtered
        }
    }

    /// Earlier builds consumed live hooks but did not persist their origin.
    /// Recover metadata only for existing rows; never replay clears/deletes or
    /// resurrect task history that the user already removed.
    private func recoverHookMetadata() {
        guard let data = try? Data(contentsOf: LinglongtaiPaths.events) else { return }
        let prefix = data.prefix(min(Int(eventOffset), data.count))
        guard let text = String(data: prefix, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            guard let event = try? JSONDecoder().decode(AgentEvent.self, from: Data(line.utf8)),
                  let name = event.sourceEvent, let agent = event.agent, let date = event.createdAt else { continue }
            let key = AgentKind.resolve(agent).rawValue
            connections[key] = max(connections[key] ?? .distantPast, date)
            if let index = tasks.firstIndex(where: { $0.id == event.id && $0.updatedAt == date }) {
                tasks[index].sourceEvent = name
                tasks[index].progressKnown = event.progress != nil
            }
        }
    }

    @discardableResult
    private func saveTasks() -> Bool {
        guard !isAcceptancePreview && !demoPreviewActive else { return false }
        checkpointGeneration += 1
        checkpointNeedsRetry = true
        let persistentTasks = tasks.filter { $0.source != .demo }
        do {
            // One atomic checkpoint contains both data and cursor, preventing
            // a cursor from skipping events after a failed task write.
            let snapshot = Snapshot(tasks: persistentTasks, eventOffset: eventOffset, connections: connections, version: 2)
            try checkpointQueue.sync { try Self.writeCheckpoint(snapshot) }
            checkpointNeedsRetry = false
            return true
        } catch {
            notice = "任务保存失败，事件将重试"
            return false
        }
    }

    func consumeEvents() {
        if let fileSize = try? LinglongtaiPaths.events.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           eventOffset == UInt64(fileSize) { return }
        guard let batch = try? EventJournal.read(at: LinglongtaiPaths.events, offset: eventOffset) else { return }
        if batch.blockedByOversizedLine { notice = "事件行超过 1MiB，已暂停读取；原日志未改动，请核实数据源" }
        guard batch.end > batch.start else { return }
        eventOffset = batch.end
        for event in batch.events { _ = apply(event) }
        _ = saveTasks()
        refreshPresentation()
    }

    nonisolated private static func writeCheckpoint(_ snapshot: Snapshot) throws {
        try JSONEncoder().encode(snapshot).write(to: LinglongtaiPaths.state, options: .atomic)
        // One encode for authoritative state; compatibility remains optional.
        try? JSONEncoder().encode(snapshot.tasks).write(to: LinglongtaiPaths.tasks, options: .atomic)
    }

    /// Runtime polling does file I/O/decoding and checkpoint encoding off main.
    /// One batch at a time and FIFO atomic checkpoints preserve
    /// the atomic data+cursor contract. Explicit acceptance calls stay synchronous.
    func pollEvents() {
        guard !eventPollInFlight, !isAcceptancePreview else { return }
        if checkpointNeedsRetry {
            eventPollInFlight = true
            saveTasksInBackground { [weak self] in self?.eventPollInFlight = false }
            return
        }
        eventPollInFlight = true
        let offset = eventOffset
        let url = LinglongtaiPaths.events
        Task { @MainActor [weak self] in
            let batch = await Task.detached(priority: .utility) {
                try? EventJournal.read(at: url, offset: offset)
            }.value
            guard let self else { return }
            if batch?.blockedByOversizedLine == true { self.notice = "事件行超过 1MiB，已暂停读取；原日志未改动，请核实数据源" }
            guard let batch, batch.end > batch.start, self.eventOffset == offset else {
                self.eventPollInFlight = false
                return
            }
            self.eventOffset = batch.end
            for event in batch.events { _ = self.apply(event) }
            self.refreshPresentation()
            self.saveTasksInBackground { [weak self] in self?.eventPollInFlight = false }
        }
    }

    private func saveTasksInBackground(completion: (@MainActor () -> Void)? = nil) {
        checkpointGeneration += 1
        let generation = checkpointGeneration
        checkpointNeedsRetry = true
        let snapshot = Snapshot(tasks: tasks.filter { $0.source != .demo },
                                eventOffset: eventOffset, connections: connections, version: 2)
        checkpointQueue.async { [weak self] in
            let succeeded: Bool
            do { try Self.writeCheckpoint(snapshot); succeeded = true }
            catch { succeeded = false }
            Task { @MainActor [weak self] in
                if let self, self.checkpointGeneration == generation {
                    self.checkpointNeedsRetry = !succeeded
                    if !succeeded { self.notice = "任务保存失败，正在重试最新快照" }
                }
                // Never rewind the in-memory cursor: replaying already-applied
                // events after a local clear could resurrect removed rows.
                completion?()
            }
        }
    }

    /// Doubao exposes no hook, so its Agent-mode trajectory is polled instead.
    /// Acceptance runs are in-memory only and never read the personal directory.
    private func consumeDoubaoTrajectories() {
        guard !isIsolatedRun, !demoPreviewActive, !doubaoPollInFlight else { return }
        let current = now()
        guard current.timeIntervalSince(lastDoubaoPoll) >= Self.doubaoPollInterval else { return }
        lastDoubaoPoll = current
        doubaoPollInFlight = true
        let tracker = doubaoTracker
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .utility) {
                var tracker = tracker
                let events = tracker.poll(now: current)
                return (tracker, events)
            }.value
            guard let self else { return }
            self.doubaoTracker = result.0
            self.doubaoPollInFlight = false
            guard !result.1.isEmpty else { return }
            var didChange = false
            for event in result.1 { didChange = self.apply(event) || didChange }
            if didChange {
                self.saveTasksInBackground()
                self.refreshPresentation()
            }
        }
    }

    @discardableResult
    private func apply(_ event: AgentEvent) -> Bool {
        if demoPreviewActive { endDemoPreview() }
        if event.sourceEvent != nil, let agent = event.agent, let date = event.createdAt {
            let kind = AgentKind.resolve(agent)
            connections[kind.rawValue] = max(connections[kind.rawValue] ?? .distantPast, date)
        }
        switch event.type {
        case "connection":
            return true
        case "ambiguous-turn":
            guard let session = event.sessionID else { return false }
            for index in tasks.indices where tasks[index].sessionID == session && tasks[index].agent == event.agent &&
                [.queued, .running, .waiting].contains(tasks[index].status) {
                tasks[index].sourceEvent = "AmbiguousTurn"
                tasks[index].detail = event.detail ?? "同一会话有多个请求，上游未提供轮次，等待明确回调。"
            }
            return true
        case "end-session":
            guard let date = event.createdAt else { return true }
            for index in tasks.indices where
                (event.sessionID != nil ? tasks[index].sessionID == event.sessionID && tasks[index].agent == event.agent : tasks[index].id == event.id) &&
                [.queued, .running, .waiting].contains(tasks[index].status) && date >= tasks[index].updatedAt {
                tasks[index].status = .cancelled
                tasks[index].requiresApproval = false
                tasks[index].sourceEvent = "SessionEnd"
                tasks[index].detail = "会话已关闭"
                tasks[index].updatedAt = date
                if abs(now().timeIntervalSince(date)) <= 120 {
                    mediumUntil = now().addingTimeInterval(10)
                    eventPulseUntil = mediumUntil
                    highlightedTaskID = tasks[index].id
                }
            }
            return true
        case "clear":
            tasks.removeAll()
            eventPulseUntil = .distantPast
            mediumUntil = .distantPast
            highlightedTaskID = nil
            demoPreviewActive = false
            selectedTaskID = nil
            notice = "任务列表已清空"
            return true
        case "delete":
            guard let id = event.id else { return false }
            tasks.removeAll { $0.id == id }
            if highlightedTaskID == id {
                eventPulseUntil = .distantPast
                mediumUntil = .distantPast
                highlightedTaskID = nil
            }
            if selectedTaskID == id { selectedTaskID = sortedTasks.first?.id }
            return true
        case "upsert":
            guard let id = event.id else { return false }
            let obsoleteID = event.replacesTaskID ?? event.legacySessionID
            if let obsoleteID, obsoleteID != id,
               let index = tasks.firstIndex(where: { $0.id == obsoleteID &&
                   (event.replacesTaskID != nil || $0.sessionID == nil) }),
               (event.createdAt ?? .distantPast) >= tasks[index].updatedAt {
                if tasks.contains(where: { $0.id == id }) {
                    tasks.remove(at: index)
                } else {
                    tasks[index].id = id
                }
                if selectedTaskID == obsoleteID { selectedTaskID = id }
            }
            let previousStatus = tasks.first(where: { $0.id == id })?.status
            let previousApproval = tasks.first(where: { $0.id == id })?.approvalRequestID
            let previouslyNeededAttention = tasks.first(where: { $0.id == id }).map { needsUserAttention($0) } ?? false
            // An untimestamped historical event is not evidence of current
            // progress; it remains history until a timestamped update arrives.
            let eventDate = event.createdAt ?? .distantPast
            if let index = tasks.firstIndex(where: { $0.id == id }) {
                var task = tasks[index]
                guard eventDate >= task.updatedAt || !task.source.isLive else { return false }
                if let value = event.agent {
                    let profile = AgentCatalog.profile(for: value)
                    task.agent = profile.name
                    if event.model == nil { task.model = profile.defaultModel }
                    if event.colorHex == nil { task.colorHex = profile.colorHex }
                }
                if let value = event.title { task.title = value }
                if let value = event.status { task.status = value }
                if let value = event.progress {
                    task.progress = min(max(value, 0), 1)
                    task.progressKnown = true
                } else if event.sourceEvent != nil {
                    task.progressKnown = false
                }
                if let value = event.sourceEvent { task.sourceEvent = value }
                if let value = event.sessionID { task.sessionID = value }
                if let value = event.turnID { task.turnID = value }
                if let value = event.detail { task.detail = value }
                if let value = event.model { task.model = value }
                if let value = event.requiresApproval { task.requiresApproval = value }
                if let value = event.colorHex { task.colorHex = value }
                task.source = .liveEvent
                task.updatedAt = eventDate
                task.recordToolEvent(event)
                if event.sourceEvent == "PermissionRequest" {
                    // A new check cannot inherit the previous tool's approval.
                    task.approvalRequestID = event.approvalRequestID
                } else if let requestID = event.approvalRequestID {
                    task.approvalRequestID = requestID
                } else if event.sourceEvent == "Notification", let previousApproval,
                          ApprovalRelay.pending(previousApproval, taskID: id, now: now()) == nil {
                    // The provider's real prompt may appear after relay expiry
                    // or a submitted decision. It supersedes that ended relay.
                    task.approvalRequestID = nil
                    submittedApprovals.removeValue(forKey: previousApproval)
                }
                if task.status != .waiting { task.approvalRequestID = nil }
                if task.status != .waiting || task.approvalRequestID != previousApproval || event.sourceEvent == "Notification" {
                    failedApprovals.remove(id)
                }
                tasks[index] = task
            } else {
                let profile = AgentCatalog.profile(for: event.agent ?? "Agent")
                let taskTitle: String = event.title ?? "未命名任务"
                let taskStatus: AgentTaskStatus = event.status ?? .queued
                let taskProgress: Double = event.progress ?? 0
                let taskDetail: String = event.detail ?? "等待 Agent 提供下一步"
                let taskModel: String = event.model ?? profile.defaultModel
                let taskApproval: Bool = event.requiresApproval ?? false
                let taskColor: String = event.colorHex ?? profile.colorHex
                let taskDate: Date = eventDate
                var task = AgentTask(
                    id: id,
                    agent: profile.name,
                    title: taskTitle,
                    status: taskStatus,
                    progress: taskProgress,
                    detail: taskDetail,
                    model: taskModel,
                    updatedAt: taskDate,
                    requiresApproval: taskApproval,
                    colorHex: taskColor,
                    source: .liveEvent,
                    progressKnown: event.progress != nil,
                    sourceEvent: event.sourceEvent,
                    sessionID: event.sessionID,
                    turnID: event.turnID
                )
                task.recordToolEvent(event)
                task.approvalRequestID = event.approvalRequestID
                tasks.append(task)
            }
            demoPreviewActive = false
            let important = previousStatus == nil || event.sourceEvent == "UserPromptSubmit" ||
                (!previouslyNeededAttention && tasks.first(where: { $0.id == id }).map { needsUserAttention($0) } == true) ||
                (event.approvalRequestID != nil && event.approvalRequestID != previousApproval) ||
                (event.status != previousStatus && [.waiting, .completed, .failed, .cancelled].contains(event.status ?? .running))
            let permissionCheckOnly = event.sourceEvent == "PermissionRequest" && event.approvalRequestID == nil
            if important && !permissionCheckOnly, let createdAt = event.createdAt, abs(now().timeIntervalSince(createdAt)) <= 120 {
                mediumUntil = now().addingTimeInterval(10)
                eventPulseUntil = mediumUntil
                highlightedTaskID = id
            }
            if selectedTaskID == nil { selectedTaskID = id }
            let agentName = tasks.first(where: { $0.id == id })?.agent ?? "Agent"
            notice = "收到 " + agentName + " 的状态更新"
            return true
        default:
            return false
        }
    }

    private func appendCommand(type: String, taskID: UUID) {
        guard !isAcceptancePreview && !demoPreviewActive else { return }
        struct Command: Codable { let type: String; let id: UUID; let createdAt: Date }
        let command = Command(type: type, id: taskID, createdAt: Date())
        guard let data = try? JSONEncoder().encode(command),
              let handle = try? FileHandle(forWritingTo: LinglongtaiPaths.commands) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        handle.write(Data([0x0A]))
        try? handle.close()
    }

    private static func statusRank(_ status: AgentTaskStatus) -> Int {
        switch status {
        case .waiting: return 0
        case .running, .queued: return 1
        case .failed: return 3
        case .completed: return 4
        case .cancelled: return 5
        }
    }

    private static func relativeAge(_ age: TimeInterval) -> String {
        if age < 60 { return "不到 1 分钟" }
        let minutes = Int(age / 60)
        if minutes < 60 { return "\(minutes) 分钟前" }
        return "\(minutes / 60) 小时前"
    }

    private static func isLegacyDemoFixture(_ task: AgentTask) -> Bool {
        let fixture: Set<String> = [
            "Claude|整理本周作品集素材",
            "Codex|检查 Linglongtai HUD 任务链路",
            "豆包|整理参考视频交互节点",
            "Work Buddy|同步今天的工作上下文"
        ]
        return fixture.contains("\(task.agent)|\(task.title)")
    }

    func refreshPresentation() {
        // Publish time-driven changes once at semantic boundaries, even in
        // manual sizing mode. Never publish a blind 0.8-second refresh tick.
        refreshTaskCacheIfNeeded()
        if statusSignatureCache == nil {
            statusSignatureCache = sortedTasks.map { "\($0.id):\(displayedStatus(for: $0))" }.joined(separator: "|") + ":\(waitingCount)"
        }
        let signature = (statusSignatureCache ?? "") + ":\(Calendar.autoupdatingCurrent.startOfDay(for: now()))"
        if signature != visibleStateSignature {
            visibleStateSignature = signature
            objectWillChange.send()
        }
        refreshContentWidth()
        // A menu can extend outside the island: retain its anchor until closed.
        if contextMenuIsOpen {
            if presentation != .heavy { presentation = .heavy }
            return
        }
        if let request = reviewingApproval,
           tasks.first(where: { $0.id == request.taskID }).flatMap({ approvalRequest(for: $0) }) != request {
            reviewingApproval = nil
            interaction = IslandInteraction()
            if let current = tasks.first(where: { $0.id == request.taskID }),
               current.status == .waiting, current.approvalRequestID == request.id {
                notice = "批准请求已过期或被处理，请在原应用核实"
                failedApprovals.insert(request.taskID)
                mediumUntil = now().addingTimeInterval(10)
                eventPulseUntil = mediumUntil
                highlightedTaskID = request.taskID
            }
        }
        if reviewingApproval != nil {
            if presentation != .medium { presentation = .medium }
            return
        }
        if now() >= calibrationUntil, calibrationPreview != nil { calibrationPreview = nil }
        if let calibrationPreview {
            if presentation != calibrationPreview { presentation = calibrationPreview }
            return
        }
        let next = interaction.presentation(
            hasLiveEvent: hasLiveEvent,
            autoPop: autoPopOnEvent,
            hoverEnabled: heavyOnHover,
            prefersMedium: now() < mediumUntil
        )
        if presentation != next { presentation = next }
    }

    private func isFresh(_ task: AgentTask) -> Bool {
        let age = now().timeIntervalSince(task.updatedAt)
        guard !["DoubaoSilent", "DoubaoAbandoned", "AmbiguousTurn"].contains(task.sourceEvent ?? "") else { return false }
        let limit = task.profile.kind == .doubao ? DoubaoTrajectory.staleAfter : 120
        return age >= -5 && age <= limit
    }

    /// Counts retained real turns that had an update today, not model/API calls.
    var todayAgentUsage: [AgentUsageCount] {
        refreshTaskCacheIfNeeded()
        let current = now()
        let day = Calendar.autoupdatingCurrent.startOfDay(for: current)
        if let cache = usageCache, cache.day == day { return cache.values }
        let counts = tasks.filter { $0.source == .liveEvent && $0.updatedAt >= day && $0.updatedAt <= current }
            .reduce(into: [AgentKind: Int]()) { $0[$1.profile.kind, default: 0] += 1 }
        let values = AgentCatalog.supportedKinds.compactMap { kind -> AgentUsageCount? in
            guard let count = counts[kind], count > 0 else { return nil }
            return AgentUsageCount(kind: kind, count: count)
        }.sorted { $0.count == $1.count ? $0.kind.displayName < $1.kind.displayName : $0.count > $1.count }
        usageCache = (day, values)
        return values
    }

    private static let demoTasks: [AgentTask] = [
        AgentTask(
            agent: AgentKind.claude.displayName,
            title: "整理本周作品集素材",
            status: .running,
            progress: 0.64,
            detail: "正在归并 AUI 案例中的交互证据",
            model: AgentKind.claude.defaultModel,
            colorHex: AgentKind.claude.colorHex,
            source: .demo
        ),
        AgentTask(
            agent: AgentKind.codex.displayName,
            title: "检查 Linglongtai HUD 任务链路",
            status: .waiting,
            progress: 0.88,
            detail: "需要你确认是否写入本地演示目录",
            model: AgentKind.codex.defaultModel,
            requiresApproval: true,
            colorHex: AgentKind.codex.colorHex,
            source: .demo
        ),
        AgentTask(
            agent: AgentKind.doubao.displayName,
            title: "整理参考视频交互节点",
            status: .completed,
            progress: 1,
            detail: "已提取 6 个关键状态",
            model: AgentKind.doubao.defaultModel,
            colorHex: AgentKind.doubao.colorHex,
            source: .demo
        ),
        AgentTask(
            agent: AgentKind.workBuddy.displayName,
            title: "同步今天的工作上下文",
            status: .queued,
            progress: 0,
            detail: "等待 Work Buddy 接管下一步",
            model: AgentKind.workBuddy.defaultModel,
            colorHex: AgentKind.workBuddy.colorHex,
            source: .demo
        )
    ]
}
