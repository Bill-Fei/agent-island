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
    @Published var autoOpenApproval: Bool
    @Published var notchOffset: Double
    @Published var notchWidthAdjustment: Double
    @Published var activityWidth: Double
    @Published private(set) var automaticActivityWidth: Bool
    @Published private(set) var demoPreviewActive = false
    @Published private(set) var connections: [String: Date] = [:]
    @Published private(set) var reviewingApproval: ApprovalRelay.Request?
    /// Full parameters shown in the review card; collapsed for every new review.
    @Published var approvalReviewExpanded = false
    /// The card shrank back to the notch after being ignored; hover brings it back.
    @Published private(set) var approvalMinimized = false
    /// Last card content, kept so the card does not go blank while it closes.
    @Published private(set) var displayedApproval: ApprovalRelay.Request?
    /// Start of a press-and-hold on a risky Allow; nil when not holding.
    @Published private(set) var approvalHoldStartedAt: Date?
    /// Short result shown in the notch right after a decision.
    @Published private(set) var approvalOutcome: ApprovalOutcome?
    private var approvalCardShownAt = Date.distantPast
    private var approvalPointerInside = false
    private var approvalPointerLeftAt = Date.distantPast
    /// Where a failed request lives, so the notch can jump straight there.
    private var failedApprovalSessions: [UUID: String] = [:]
    static let approvalMinimizeDelay: TimeInterval = 8
    static let approvalHoldDuration: TimeInterval = 0.6

    struct ApprovalOutcome: Equatable {
        enum Kind: Equatable { case allowed, denied, failed }
        var kind: Kind
        var text: String
        var taskID: UUID
        var until: Date
    }
    @Published private(set) var submittedApprovals: [UUID: Date] = [:]
    @Published private(set) var failedApprovals: Set<UUID> = []
    @Published private(set) var claudeChatDiagnostic = "Claude Chat：等待窗口检查"
    private(set) var contextMenuIsOpen = false

    func approvalRequest(for task: AgentTask) -> ApprovalRelay.Request? {
        guard ApprovalRelay.supports(task.profile.kind) else { return nil }
        guard let current = tasks.first(where: { $0.id == task.id }),
              current.approvalRequestID == task.approvalRequestID,
              current.updatedAt == task.updatedAt,
              current.source.isLive, current.status == .waiting, current.requiresApproval,
              current.sourceEvent != "AmbiguousTurn", now().timeIntervalSince(current.updatedAt) <= 86_400,
              now().timeIntervalSince(current.updatedAt) >= -5,
              let id = current.approvalRequestID else { return nil }
        guard let request = ApprovalRelay.pending(id, taskID: task.id, now: now()),
              request.provider == task.profile.kind else { return nil }
        // Desktop checks permissions it then auto-approves; only its own card,
        // recorded in its log, proves there is a decision waiting for the user.
        if request.hostSessionID != nil, hostPrompt(for: request) == nil { return nil }
        return request
    }

    /// Approval is a separate top-level concern from the selected/ambient
    /// task. A stale selected row must never hide a fresh actionable request.
    var approvalTask: AgentTask? {
        currentActivityTasks
            .filter { needsUserAttention($0) && approvalRequest(for: $0) != nil }
            .max { $0.updatedAt < $1.updatedAt }
    }

    func approvalFeedback(for task: AgentTask) -> String? {
        if failedApprovals.contains(task.id) { return "没批成功 · 回 App 处理" }
        guard let id = task.approvalRequestID, let date = submittedApprovals[id], task.status == .waiting else { return nil }
        return now().timeIntervalSince(date) < 30 ? "已发送，等 App 确认" : "App 还没确认 · 回 App 看看"
    }

    /// Explain where the user must make a decision. A PermissionRequest is
    /// only a permission check until the relay publishes a live request.
    func approvalSurfaceText(for task: AgentTask) -> String? {
        guard task.status == .waiting else { return nil }
        if approvalRequest(for: task) != nil { return "可以在岛上批准" }
        if codexPromptInApp(task) { return "在 Codex 里批准" }
        if task.profile.kind == .claude, ["PermissionRequest", "Notification"].contains(task.sourceEvent ?? "") { return "在 App 里处理" }
        return nil
    }

    func currentStepText(for task: AgentTask) -> String {
        if task.sourceEvent == "ClaudeChatUnknown" { return task.detail }
        if let feedback = approvalFeedback(for: task) { return feedback }
        if approvalRequest(for: task) != nil { return "等你批准 · 看清要做什么再点" }
        if displayedStatus(for: task) == "结果未知" { return "未收到结束信号，无法确认结果" }
        if codexPromptInApp(task) {
            return needsUserAttention(task) ? "Codex 等你批准 · 请在 Codex 里处理" : "Codex 正在确认权限"
        }
        if task.status == .waiting && task.sourceEvent == "PermissionRequest" {
            // Never send the user hunting for a prompt that may not exist.
            return "\(task.agent) 正在确认权限；需要你批准时会在 App 里问你"
        }
        if task.status == .waiting && task.sourceEvent == "Notification", task.profile.kind == .claude {
            return "\(task.agent) 可能在等你确认，请回 App 查看"
        }
        if task.sourceEvent == "PreToolUse",
           let step = task.toolSteps.filter({ $0.state == .running }).max(by: { $0.updatedAt < $1.updatedAt }) {
            return step.label
        }
        return task.detail
    }

    func reviewApproval(for task: AgentTask) {
        approvalReviewExpanded = false
        approvalMinimized = false
        approvalHoldStartedAt = nil
        approvalCardShownAt = now()
        reviewingApproval = approvalRequest(for: task)
        if let request = reviewingApproval { displayedApproval = request }
        refreshPresentation()
    }

    func closeApproval() {
        reviewingApproval = nil
        approvalMinimized = false
        approvalHoldStartedAt = nil
        approvalReviewExpanded = false
        resetInteraction()
    }

    /// Bring a minimized card back (hover or the notch's 待批 control).
    func revealApproval() {
        guard reviewingApproval != nil, approvalMinimized else { return }
        approvalMinimized = false
        approvalCardShownAt = now()
        refreshPresentation()
    }

    /// Requests a person could act on right now, oldest first.
    var pendingApprovalTasks: [AgentTask] {
        currentActivityTasks.filter { needsUserAttention($0) && approvalRequest(for: $0) != nil }
            .sorted { $0.updatedAt < $1.updatedAt }
    }

    /// Risky commands need a press-and-hold; a click or ⌘↩ never allows them.
    func approvalNeedsHold(_ request: ApprovalRelay.Request) -> Bool {
        if let fields = ApprovalShortcut.fields(fromContext: request.context) { return !ApprovalRisk.labels(in: fields).isEmpty }
        return !ApprovalRisk.matches(in: request.context).isEmpty
    }

    func beginApprovalHold() {
        guard reviewingApproval != nil, approvalHoldStartedAt == nil else { return }
        let started = now()
        approvalHoldStartedAt = started
        // Completes on its own once held long enough; releasing earlier cancels.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.approvalHoldDuration) { [weak self] in
            guard let self, self.approvalHoldStartedAt == started else { return }
            self.finishApprovalHold()
        }
    }

    func cancelApprovalHold() { approvalHoldStartedAt = nil }

    /// Completed hold: allow only if it really lasted the full duration.
    func finishApprovalHold() {
        guard let request = reviewingApproval, let started = approvalHoldStartedAt,
              now().timeIntervalSince(started) >= Self.approvalHoldDuration - 0.05 else {
            approvalHoldStartedAt = nil
            return
        }
        approvalHoldStartedAt = nil
        respondToApproval(request, decision: .allow)
    }

    /// The failed notch control: open the exact conversation when known.
    func openFailedApproval(_ task: AgentTask) -> URL? {
        guard let session = failedApprovalSessions[task.id] else { return nil }
        return URL(string: "claude://claude.ai/epitaxy/\(session)")
    }

    private func showApprovalOutcome(_ kind: ApprovalOutcome.Kind, _ text: String, task: UUID, seconds: TimeInterval) {
        approvalOutcome = ApprovalOutcome(kind: kind, text: text, taskID: task, until: now().addingTimeInterval(seconds))
        mediumUntil = max(mediumUntil, now().addingTimeInterval(seconds))
        highlightedTaskID = task
    }

    /// After one decision, the next waiting request takes the same card.
    private func continueWithNextApproval(after request: ApprovalRelay.Request) {
        guard let next = pendingApprovalTasks.first(where: { $0.approvalRequestID != request.id }) else { return }
        select(next)
        reviewApproval(for: next)
    }

    func respondToApproval(_ request: ApprovalRelay.Request, decision: ApprovalRelay.Decision) {
        guard let task = tasks.first(where: { $0.id == request.taskID }),
              approvalRequest(for: task) == request,
              ApprovalRelay.respond(to: request, decision: decision) else {
            let expired = now() >= request.expiresAt
            notice = "批准请求已过期或被处理，请在原应用核实"
            failedApprovals.insert(request.taskID)
            if let session = request.hostSessionID { failedApprovalSessions[request.taskID] = session }
            closeApproval()
            showApprovalOutcome(.failed, expired ? "已超时 · 回 App 处理" : "已在别处处理", task: request.taskID, seconds: 10)
            eventPulseUntil = mediumUntil
            return
        }
        notice = "已提交本次决定，等待 Agent 的真实回调"
        submittedApprovals[request.id] = now()
        failedApprovals.remove(request.taskID)
        closeApproval()
        showApprovalOutcome(decision == .allow ? .allowed : .denied, decision == .allow ? "已允许" : "已拒绝",
                            task: request.taskID, seconds: 1.6)
        continueWithNextApproval(after: request)
    }
    /// One exact open card in the request's own session and tool, shown within
    /// seconds of the request (the hook returns at once, so Desktop shows its
    /// card immediately). Two open cards in a session are ambiguous. Once
    /// matched, the request is bound to that card ID and never to another.
    func hostPrompt(for request: ApprovalRelay.Request) -> ClaudePromptLog.Prompt? {
        guard let session = request.hostSessionID, let created = request.createdAt else { return nil }
        let prompts = promptLog.openPrompts(in: session)
        guard prompts.count == 1, let prompt = prompts.first, prompt.tool == request.toolName else { return nil }
        if let bound = hostBindings[request.id] { return bound == prompt.id ? prompt : nil }
        // Log stamps are whole seconds; the request time is not.
        let delay = prompt.shownAt.timeIntervalSince(created)
        guard delay >= -2, delay <= 5 else { return nil }
        // A card already bound to another request is not this request's card.
        guard !hostBindings.values.contains(prompt.id) else { return nil }
        hostBindings[request.id] = prompt.id
        if hostBindings.count > 64 { hostBindings = hostBindings.filter { $0.key == request.id } }
        return prompt
    }

    /// Codex's PermissionRequest is a real prompt. Codex shows its own card only
    /// once every hook has returned, so while an island request is live the
    /// prompt is on the island; once it is gone (answered elsewhere, expired,
    /// or never published) the card is in Codex.
    func codexPromptInApp(_ task: AgentTask) -> Bool {
        task.profile.kind == .codex && task.status == .waiting && task.sourceEvent == "PermissionRequest" &&
            approvalRequest(for: task) == nil &&
            // Decided on the island: Codex is applying it, not asking again.
            task.approvalRequestID.map { submittedApprovals[$0] == nil } ?? true
    }

    /// An approval answered in the Codex app sends no hook; once its rollout
    /// shows the turn moving on, the task is running again (and animates).
    func resolveCodexApprovalsAnsweredInApp() {
        guard now().timeIntervalSince(lastCodexRolloutPoll) >= 2 || now() < lastCodexRolloutPoll else { return }
        lastCodexRolloutPoll = now()
        codexAppLog.poll(now: now())
        let prompts = tasks.indices.filter { codexPromptInApp(tasks[$0]) && isFresh(tasks[$0]) }
        var changed = false
        for index in prompts {
            let task = tasks[index]
            // Codex's own log names the card's session when it showed it; an
            // unnamed answer can only be attributed when one prompt is open.
            let answer = codexAppLog.answers.last {
                $0.at >= task.updatedAt.addingTimeInterval(-1) && ($0.session == task.sessionID || ($0.session == nil && prompts.count == 1))
            }
            guard answer != nil || codexRollout.progressed(session: task.sessionID, since: task.updatedAt, now: now()) else { continue }
            tasks[index].status = .running
            tasks[index].requiresApproval = false
            tasks[index].sourceEvent = "CodexApprovalAnswered"
            tasks[index].detail = answer?.accepted == false ? "已在 Codex 里拒绝，继续本轮" : "已在 Codex 里批准，继续执行"
            changed = true
        }
        guard changed else { return }
        invalidateTaskCache()
        refreshPresentation()
        saveTasksInBackground()
    }

    func pollHostPrompts() {
        guard promptLog.poll(now: now()) else { return }
        invalidateTaskCache()
        for task in tasks {
            guard let id = task.approvalRequestID, !tracedHostActionable.contains(id),
                  let request = approvalRequest(for: task), request.hostSessionID != nil else { continue }
            tracedHostActionable.insert(id)
            ApprovalTrace.record(id, "hud-actionable")
        }
        refreshPresentation()
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
    private var currentActivityTasksCache: [AgentTask]?
    private var ongoingTasksCache: [AgentTask]?
    // Lifecycle membership is independent of callback freshness. Historical
    // unresolved rows are retained, but are not automatically re-adopted.
    private var ongoingTaskIDs: Set<UUID> = [] {
        didSet { invalidateTaskCache() }
    }
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
    private var claudeChatObserver: ClaudeChatObserver?
    private var claudeChatTaskIDs: [String: UUID] = [:]
    private var lastDoubaoPoll = Date.distantPast
    private var doubaoPollInFlight = false
    private static let doubaoPollInterval: TimeInterval = 3
    private var eventPulseUntil = Date.distantPast
    private var mediumUntil = Date.distantPast
    private var highlightedTaskID: UUID?
    private var attentionPulseTaskID: UUID?
    private var claudeNotificationStarts: [UUID: Date] = [:]
    private var surfacedClaudeNotifications: [UUID: Date] = [:]
    private var approvalRequestStarts: [UUID: Date] = [:]
    /// Desktop's own card lifecycle, followed from its log (see ClaudePromptLog).
    private var promptLog = ClaudePromptLog(urls: [])
    /// Codex answers approvals in its own card without any hook; its rollout shows it.
    private var codexRollout = CodexRollout(root: LinglongtaiPaths.applicationSupport.appendingPathComponent("fixture-codex-sessions"))
    private var lastCodexRolloutPoll = Date.distantPast
    private var codexAppLog = CodexAppLog(root: LinglongtaiPaths.applicationSupport.appendingPathComponent("fixture-codex-logs"))
    /// Codex shows its own card for a PermissionRequest; a brief settle keeps a
    /// check it resolves on its own from popping the island.
    private static let codexPromptSettleDelay: TimeInterval = 3
    /// The first card matched to a request stays its only card.
    private var hostBindings: [UUID: String] = [:]
    private var tracedHostActionable: Set<UUID> = []

    private var surfacedApprovalRequests: Set<UUID> = []
    private static let notificationSettleDelay: TimeInterval = 2
    private static let approvalSettleDelay: TimeInterval = 1.2
    @Published private(set) var calibrationPreview: Presentation?
    private var calibrationUntil = Date.distantPast
    private let now: () -> Date
    private struct Snapshot: Codable, Sendable {
        var tasks: [AgentTask]
        var eventOffset: UInt64
        var connections: [String: Date]?
        var version: Int?
        var ongoingTaskIDs: Set<UUID>?
    }

    private struct BridgeSnapshot: Decodable {
        var version: Int
        var tracker: HookTurnTracker
    }

    nonisolated private static func hookTerminalStates() -> [UUID: Bool] {
        guard let data = try? Data(contentsOf: LinglongtaiPaths.hookTurns),
              let bridge = try? JSONDecoder().decode(BridgeSnapshot.self, from: data),
              bridge.version == 2 else { return [:] }
        return bridge.tracker.terminalStates.mapValues(\.isTerminal)
    }

    private func reconcileOngoingTasks(terminalStates: [UUID: Bool]) {
        for index in tasks.indices where tasks[index].source.isLive &&
            [.queued, .running, .waiting].contains(tasks[index].status) {
            if terminalStates[tasks[index].id] == true {
                ongoingTaskIDs.remove(tasks[index].id)
                // The tracker has no terminal reason; do not invent completion.
                tasks[index].sourceEvent = "HookTrackingEnded"
            } else if terminalStates[tasks[index].id] == false,
                      tasks[index].sourceEvent != "HookTrackingEnded" {
                ongoingTaskIDs.insert(tasks[index].id)
            }
        }
        let latestDoubao = Dictionary(grouping: tasks.filter {
            $0.source.isLive && $0.profile.kind == .doubao && $0.sessionID != nil
        }, by: { $0.sessionID! }).compactMapValues { $0.max { $0.updatedAt < $1.updatedAt }?.id }
        for index in tasks.indices where tasks[index].profile.kind == .doubao {
            guard let session = tasks[index].sessionID, latestDoubao[session] != tasks[index].id,
                  [.queued, .running, .waiting].contains(tasks[index].status) else { continue }
            ongoingTaskIDs.remove(tasks[index].id)
            tasks[index].sourceEvent = "SupersededTrajectory"
        }
        ongoingTaskIDs.formIntersection(Set(tasks.filter {
            $0.source.isLive && [.queued, .running, .waiting].contains($0.status)
        }.map(\.id)))
    }

    private let autoPopKey = "dynamicIsland.autoPopOnEvent"
    private let heavyOnHoverKey = "dynamicIsland.heavyOnHover"
    private let autoOpenApprovalKey = "dynamicIsland.autoOpenApproval"
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
        autoOpenApproval = !isAcceptancePreview && (arguments.contains("--auto-open-approval")
            || UserDefaults.standard.object(forKey: autoOpenApprovalKey) as? Bool ?? false)
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
        ApprovalRelay.cleanupExpired()
        // Isolated runs follow a fixture inside their own data directory only.
        promptLog = ClaudePromptLog(urls: isIsolatedRun
            ? [LinglongtaiPaths.applicationSupport.appendingPathComponent("fixture-claude-main.log")]
            : ClaudePromptLog.defaultURLs)
        _ = promptLog.poll(now: now())
        if !isIsolatedRun { codexRollout = CodexRollout(); codexAppLog = CodexAppLog() }
        loadTasks()
        selectedTaskID = sortedTasks.first?.id
        consumeEvents()
        configureClaudeChatObserver()
        refreshPresentation()
        let timer = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollEvents()
                self?.pollHostPrompts()
                self?.resolveCodexApprovalsAnsweredInApp()
                self?.consumeDoubaoTrajectories()
                self?.refreshPresentation()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        eventTimer = timer
    }

    private func configureClaudeChatObserver() {
        guard !isIsolatedRun else { return }
        // A persisted AX observation is not evidence that a task is still running after restart.
        var reconciled = false
        for index in tasks.indices where tasks[index].sourceEvent?.hasPrefix("ClaudeChat") == true &&
            [.running, .queued, .waiting].contains(tasks[index].status) {
            tasks[index].sourceEvent = "ClaudeChatUnknown"
            tasks[index].detail = "灵动岛已重启，等待 Claude Chat 窗口状态"
            reconciled = true
        }
        if reconciled { saveTasksInBackground() }
        let observer = ClaudeChatObserver()
        observer.onDiagnostic = { [weak self] diagnostic in
            guard let self, self.claudeChatDiagnostic != diagnostic.rawValue else { return }
            self.claudeChatDiagnostic = diagnostic.rawValue
        }
        observer.onSnapshot = { [weak self] snapshot in
            self?.applyClaudeChatSnapshot(snapshot)
        }
        observer.start()
        claudeChatObserver = observer
    }

    func applyClaudeChatSnapshot(_ snapshot: ClaudeChatObserver.Snapshot) {
        let session = snapshot.sessionID
        switch snapshot.phase {
        case .running:
            let id = claudeChatTaskIDs[session] ?? UUID()
            claudeChatTaskIDs[session] = id
            applyClaudeChatEvent(id: id, sessionID: session,
                                 status: .running, sourceEvent: "ClaudeChatStart", detail: snapshot.detail)
        case .completed:
            guard let id = claudeChatTaskIDs[session] else { return }
            applyClaudeChatEvent(id: id, sessionID: session,
                                 status: .completed, sourceEvent: "ClaudeChatStop", detail: snapshot.detail)
            claudeChatTaskIDs.removeValue(forKey: session)
        case .unknown:
            guard let id = claudeChatTaskIDs[session] else { return }
            applyClaudeChatEvent(id: id, sessionID: session,
                                 status: .running, sourceEvent: "ClaudeChatUnknown", detail: snapshot.detail)
        }
    }

    private func applyClaudeChatEvent(id: UUID, sessionID: String, status: AgentTaskStatus,
                                      sourceEvent: String, detail: String) {
        let event = AgentEvent(
            type: "upsert", id: id, agent: AgentKind.claude.displayName,
            title: "Claude Chat", status: status, detail: detail,
            model: "Claude Chat", requiresApproval: false,
            colorHex: AgentKind.claude.colorHex, createdAt: now(), sourceEvent: sourceEvent,
            sessionID: sessionID
        )
        guard apply(event) else { return }
        saveTasksInBackground()
        refreshPresentation()
    }

    var sortedTasks: [AgentTask] {
        refreshTaskCacheIfNeeded()
        if let sortedTasksCache { return sortedTasksCache }
        let sorted = displayTasks.sorted { lhs, rhs in
            // Sort by the same display state used by the two visible list
            // sections. Some sources retain a raw `.running` status while
            // reporting an unknown/untracked result; ranking raw status here
            // would let those ended rows jump ahead of a newly finished task
            // and then move down only after `TaskVisualSection.grouped`.
            let leftState = TaskVisualState.resolve(lhs,
                                                     displayedStatus: displayedStatus(for: lhs),
                                                     needsAttention: needsUserAttention(lhs))
            let rightState = TaskVisualState.resolve(rhs,
                                                      displayedStatus: displayedStatus(for: rhs),
                                                      needsAttention: needsUserAttention(rhs))
            let leftRank = leftState == .attention ? 0 : (leftState.group == .active ? 1 : 2)
            let rightRank = rightState == .attention ? 0 : (rightState.group == .active ? 1 : 2)
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
            (ongoingTaskIDs.contains($0.id) || reference.timeIntervalSince($0.updatedAt) <= 86_400) &&
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

    /// Confirmed starts / resumptions remain unresolved until real terminal
    /// evidence, explicit removal, or a source-backed superseding turn arrives.
    var ongoingTasks: [AgentTask] {
        refreshTaskCacheIfNeeded()
        if let ongoingTasksCache { return ongoingTasksCache }
        let ongoing = liveTasks.filter { ongoingTaskIDs.contains($0.id) }
        ongoingTasksCache = ongoing
        return ongoing
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

    /// Tasks counted as running: the island shows exactly this many, and 0
    /// once every task has ended. A started task keeps counting through quiet
    /// stretches until terminal evidence arrives; rows whose source reports an
    /// unknown result count as ended (结果未知), never as running.
    var currentActivityTasks: [AgentTask] {
        refreshTaskCacheIfNeeded()
        if let currentActivityTasksCache { return currentActivityTasksCache }
        let current = ongoingTasks.filter { isRunning($0) }
        currentActivityTasksCache = current
        return current
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
        currentActivityTasksCache = nil
        ongoingTasksCache = nil
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
                (claudeNotificationStarts[task.id] ?? task.updatedAt).addingTimeInterval(Self.notificationSettleDelay),
                task.updatedAt.addingTimeInterval(Self.codexPromptSettleDelay),
                task.updatedAt.addingTimeInterval(ApprovalRelay.lifetime(for: .codex) + 0.1),
                approvalRequestStarts.values.map { $0.addingTimeInterval(Self.approvalSettleDelay) }.min() ?? .distantFuture,
                task.updatedAt.addingTimeInterval(120),
                task.updatedAt.addingTimeInterval(DoubaoTrajectory.staleAfter),
                task.updatedAt.addingTimeInterval(AgentActivityMotion.unresolvedLimit),
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
        if codexPromptInApp(task) {
            return now().timeIntervalSince(task.updatedAt) >= Self.codexPromptSettleDelay
        }
        if task.approvalRequestID != nil || task.sourceEvent == "PermissionRequest" {
            guard let request = approvalRequest(for: task) else { return false }
            // The card is already on screen; its log line needs no further settling.
            if request.hostSessionID != nil { return true }
            let started = approvalRequestStarts[request.id] ?? task.updatedAt
            return now().timeIntervalSince(started) >= Self.approvalSettleDelay
        }
        if task.profile.kind == .claude, task.sourceEvent == "Notification" {
            return now().timeIntervalSince(claudeNotificationStarts[task.id] ?? task.updatedAt) >= Self.notificationSettleDelay
        }
        return true // Explicit provider notifications and custom waiting events.
    }

    var hasLiveEvent: Bool {
        !currentActivityTasks.isEmpty || highlightedFeedbackTask != nil
    }

    /// A historical unresolved row is not an ambient activity signal. Even a
    /// recent unknown-state update cannot keep the island open via its pulse.
    private var highlightedFeedbackTask: AgentTask? {
        guard now() < eventPulseUntil, let highlightedTaskID,
              let task = tasks.first(where: { $0.id == highlightedTaskID }),
              isFresh(task) else { return nil }
        return task
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
            if latestKnownLiveTask(for: kind) != nil { return L("当前无进行中的会话") }
            return L(connections[kind.rawValue] == nil ? "等待首次任务回调" : "已收到连接 · 等待任务")
        }
        let age = max(0, now().timeIntervalSince(task.updatedAt))
        let freshness = age < 120 ? L("刚刚") : LF("更新于 %@", Self.relativeAge(age))
        if [.queued, .running, .waiting].contains(task.status) && !isRunning(task) {
            return L("结果未知") + " · " + freshness
        }
        if task.status == .running || task.status == .queued {
            let progress = task.progressKnown ? " · \(Int(task.progress * 100))%" : ""
            return L(plainStatus(for: task)) + progress + " · " + freshness
        }
        return L(plainStatus(for: task)) + " · " + freshness
    }

    func connectionLabel(for kind: AgentKind) -> String {
        // Doubao has no hook to call back from; its state arrives by trajectory.
        if kind == .doubao { return "读本地轨迹" }
        return connections[kind.rawValue] == nil ? "未收到回调" : "收到过回调"
    }

    func displayedStatus(for task: AgentTask) -> String {
        // Only two dimensions: running or ended. A row the source cannot
        // resolve is shown as ended with an unknown result, never completed.
        if task.sourceEvent == "SupersededTrajectory" || task.sourceEvent == "HookTrackingEnded" { return "历史记录 · 不再跟踪" }
        if Self.unknownResultEvents.contains(task.sourceEvent ?? "") { return "结果未知" }
        if task.source.isLive && [.queued, .running, .waiting].contains(task.status) && !isRunning(task) { return "结果未知" }
        if task.sourceEvent == "ClaudeChatStart" { return "正在生成" }
        if task.status == .waiting && !needsUserAttention(task) {
            if task.sourceEvent == "PermissionRequest" { return "权限检查中" }
            if let id = task.approvalRequestID, submittedApprovals[id] != nil { return "等待回执" }
            if task.profile.kind == .claude, task.sourceEvent == "Notification", task.approvalRequestID == nil { return "确认通知观察中" }
            return task.approvalRequestID == nil ? "权限检查中" : "等待权限结果"
        }
        return task.statusLabel
    }

    /// The wording a person reads. displayedStatus stays the internal key that
    /// visual-state mapping and checks rely on. Every surface (list, notch,
    /// detail pill) says the same word for the same state:
    /// 等你批准 / 在 App 里处理 / 正在执行 / 已完成 / 出错了 / 已停止.
    func plainStatus(for task: AgentTask) -> String {
        Self.plainWord(for: displayedStatus(for: task))
    }

    static func plainWord(for status: String) -> String {
        switch status {
        case "权限检查中", "确认通知观察中", "等待权限结果": return "在 App 里处理"
        case "等待回执": return "已发送，等 App 确认"
        case "等待确认": return "等你批准"
        case "执行工具", "处理中", "运行中": return "正在执行"
        case "本轮已结束", "已完成": return "已完成"
        case "本轮响应失败", "失败": return "出错了"
        case "本轮已中断": return "已停止"
        default: return status
        }
    }

    var activeTask: AgentTask? {
        if let waiting = currentActivityTasks.first(where: { needsUserAttention($0) }) { return waiting }
        if let task = highlightedFeedbackTask { return task }
        if let selectedTask, (selectedTask.source.isLive || demoPreviewActive || isAcceptancePreview),
           [.queued, .running, .waiting].contains(selectedTask.status),
           demoPreviewActive || isAcceptancePreview || currentActivityTasks.contains(where: { $0.id == selectedTask.id }) {
            // Selection still controls history/detail, but only a fresh real
            // signal (or explicit QA preview) may drive the ambient surface.
            return selectedTask
        }
        if let current = currentActivityTasks.first(where: { $0.status == .running }) ?? currentActivityTasks.first {
            return current
        }
        // Unknown-result rows count as ended and never hold the island open.
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
        return [front] + currentActivityTasks.filter { $0.id != front.id }.prefix(3)
    }

    /// Translated here, not at render: the island measures this exact string to size its
    /// wings, so it must be measured in the language it is shown in.
    var mediumStatusText: String {
        if calibrationPreview != nil { return L("中态预览") }
        if waitingCount > 0 { return waitingCount == 1 ? L("等你批准") : LF("%lld 项等你批准", waitingCount) }
        if let task = highlightedFeedbackTask,
           [.completed, .failed, .cancelled].contains(task.status) {
            let word = Self.plainWord(for: task.statusLabel)
            return currentActivityTasks.isEmpty ? L(word) : L(word) + " · " + LF("%lld 项正在执行", currentActivityTasks.count)
        }
        if currentActivityTasks.count > 1 {
            return LF("%lld 项正在执行", currentActivityTasks.count)
        }
        guard let task = activeTask else { return L("等待事件") }
        return L(plainStatus(for: task))
    }

    var compactCountText: String {
        currentActivityTasks.isEmpty ? "" : "\(currentActivityTasks.count)"
    }

    // MARK: - Content-driven medium width

    /// Wing width asked for by the strings the medium surface renders today.
    /// `nil` leaves the historical fixed width untouched.
    @Published private(set) var mediumWingWidth: Double? = nil
    /// Growing applies at once; shrinking waits while medium is on screen,
    /// because status strings cycle ("3项进行中" → "运行中" → "3项进行中") and
    /// the outline must not breathe.
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
        let name = L(calibrationPreview == nil ? primaryAgentName : "中态预览")
        let iconSize = min(24, max(0, 32 + notchOffset - 4))
            * (1 + Double(max(0, islandIconTasks.count - 1)) * 0.34)
        let content = IslandContentWidth.medium(agentName: name, statusText: mediumStatusText,
                                               iconSize: iconSize, statusReserve: mediumStatusReserve)
        let target = content.wingWidth()
        // The hold only stops a visible outline from breathing. Off screen, a
        // stale width (e.g. measured for the idle placeholder) would make the
        // next medium entry open wide and then shrink, so apply it at once.
        guard let current = mediumWingWidth, presentation == .medium else {
            if mediumWingWidth != target { mediumWingWidth = target }
            pendingNarrowWidth = nil
            pendingNarrowSince = nil
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
        if reviewingApproval != nil {
            if inside != approvalPointerInside {
                approvalPointerInside = inside
                if !inside { approvalPointerLeftAt = now() }
            }
            if inside && approvalMinimized { revealApproval() }
            return
        }
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

    func setAutoOpenApproval(_ enabled: Bool) {
        autoOpenApproval = enabled
        if !isIsolatedRun { UserDefaults.standard.set(enabled, forKey: autoOpenApprovalKey) }
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

    /// Re-read provider state without issuing a retry or stop command.
    /// This action never fabricates a lifecycle event or changes another
    /// conversation's state.
    func resyncStatus(for task: AgentTask) {
        guard tasks.contains(where: { $0.id == task.id }) else { return }
        selectedTaskID = task.id
        consumeEvents()
        reconcileOngoingTasks(terminalStates: Self.hookTerminalStates())
        if task.profile.kind == .doubao {
            consumeDoubaoTrajectories(force: true)
        }
        if task.sourceEvent?.hasPrefix("ClaudeChat") == true {
            claudeChatObserver?.refreshNow()
        }
        notice = "已重新同步 \(task.agent) · 不会重新执行任务"
        refreshPresentation()
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
        ongoingTaskIDs.remove(task.id)
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
        ongoingTaskIDs.removeAll()
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
            ongoingTaskIDs = snapshot.ongoingTaskIDs ?? Set(snapshot.tasks.filter {
                $0.source.isLive && [.queued, .running, .waiting].contains($0.status) && isFresh($0)
            }.map(\.id))
            eventOffset = snapshot.eventOffset
            connections = snapshot.connections ?? [:]
            reconcileOngoingTasks(terminalStates: Self.hookTerminalStates())
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
        ongoingTaskIDs = Set(tasks.filter {
            $0.source.isLive && [.queued, .running, .waiting].contains($0.status) && isFresh($0)
        }.map(\.id))
        reconcileOngoingTasks(terminalStates: Self.hookTerminalStates())
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
            let snapshot = Snapshot(tasks: persistentTasks, eventOffset: eventOffset, connections: connections, version: 2,
                                    ongoingTaskIDs: ongoingTaskIDs)
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
        reconcileOngoingTasks(terminalStates: Self.hookTerminalStates())
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
            let result = await Task.detached(priority: .utility) {
                (try? EventJournal.read(at: url, offset: offset), Self.hookTerminalStates())
            }.value
            guard let self else { return }
            let batch = result.0
            if batch?.blockedByOversizedLine == true { self.notice = "事件行超过 1MiB，已暂停读取；原日志未改动，请核实数据源" }
            guard let batch, batch.end > batch.start, self.eventOffset == offset else {
                self.eventPollInFlight = false
                return
            }
            self.eventOffset = batch.end
            for event in batch.events { _ = self.apply(event) }
            self.reconcileOngoingTasks(terminalStates: result.1)
            self.refreshPresentation()
            self.saveTasksInBackground { [weak self] in self?.eventPollInFlight = false }
        }
    }

    private func saveTasksInBackground(completion: (@MainActor () -> Void)? = nil) {
        checkpointGeneration += 1
        let generation = checkpointGeneration
        checkpointNeedsRetry = true
        let snapshot = Snapshot(tasks: tasks.filter { $0.source != .demo },
                                eventOffset: eventOffset, connections: connections, version: 2,
                                ongoingTaskIDs: ongoingTaskIDs)
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
    private func consumeDoubaoTrajectories(force: Bool = false) {
        guard !isIsolatedRun, !demoPreviewActive, !doubaoPollInFlight else { return }
        let current = now()
        guard force || current.timeIntervalSince(lastDoubaoPoll) >= Self.doubaoPollInterval else { return }
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
            for event in result.1 { didChange = self.apply(event, observedOngoing: true) || didChange }
            if didChange {
                self.saveTasksInBackground()
                self.refreshPresentation()
            }
        }
    }

    @discardableResult
    private func apply(_ event: AgentEvent, observedOngoing: Bool = false) -> Bool {
        if demoPreviewActive { endDemoPreview() }
        if event.sourceEvent != nil, let agent = event.agent, let date = event.createdAt {
            let kind = AgentKind.resolve(agent)
            connections[kind.rawValue] = max(connections[kind.rawValue] ?? .distantPast, date)
        }
        switch event.type {
        case "source-unknown":
            notice = "\(event.agent ?? "Agent") 回调无法识别；统计已暂停该未知区间，请检查接入版本。"
            return true
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
                ongoingTaskIDs.remove(tasks[index].id)
                if abs(now().timeIntervalSince(date)) <= 120 {
                    mediumUntil = now().addingTimeInterval(10)
                    eventPulseUntil = mediumUntil
                    highlightedTaskID = tasks[index].id
                }
            }
            return true
        case "clear":
            tasks.removeAll()
            ongoingTaskIDs.removeAll()
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
            ongoingTaskIDs.remove(id)
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
                if ongoingTaskIDs.remove(obsoleteID) != nil { ongoingTaskIDs.insert(id) }
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
            if let current = tasks.first(where: { $0.id == id }), current.profile.kind == .claude,
               current.status == .waiting, current.sourceEvent == "Notification" {
                if claudeNotificationStarts[id] == nil { claudeNotificationStarts[id] = current.updatedAt }
            } else {
                claudeNotificationStarts.removeValue(forKey: id)
                surfacedClaudeNotifications.removeValue(forKey: id)
            }
            if let current = tasks.first(where: { $0.id == id }),
               let requestID = current.approvalRequestID,
               current.status == .waiting,
               approvalRequest(for: current) != nil {
                if approvalRequestStarts[requestID] == nil {
                    approvalRequestStarts[requestID] = current.updatedAt
                    ApprovalTrace.record(requestID, "hud-actionable")
                }
            } else {
                // Once per newly arrived request; replays and later events stay silent.
                if let requestID = event.approvalRequestID, requestID != previousApproval,
                   (event.createdAt ?? .distantPast) > now().addingTimeInterval(-60) {
                    ApprovalTrace.record(requestID, "hud-not-actionable")
                }
                if let previousApproval { approvalRequestStarts.removeValue(forKey: previousApproval) }
            }
            invalidateTaskCache()
            if let current = tasks.first(where: { $0.id == id }) {
                if [.completed, .failed, .cancelled].contains(current.status) {
                    ongoingTaskIDs.remove(id)
                } else if isFresh(current) || observedOngoing {
                    ongoingTaskIDs.insert(id)
                }
                // Doubao's trajectory represents one current turn per session.
                // A newer boundary supersedes old unresolved rows, but is NOT
                // proof that those old rows completed or were cancelled.
                if current.profile.kind == .doubao, let session = current.sessionID {
                    for index in tasks.indices where tasks[index].id != id &&
                        tasks[index].profile.kind == .doubao && tasks[index].sessionID == session &&
                        tasks[index].updatedAt < current.updatedAt &&
                        [.queued, .running, .waiting].contains(tasks[index].status) {
                        ongoingTaskIDs.remove(tasks[index].id)
                        tasks[index].sourceEvent = "SupersededTrajectory"
                    }
                }
            }
            demoPreviewActive = false
            let important = previousStatus == nil || event.sourceEvent == "UserPromptSubmit" ||
                (!previouslyNeededAttention && tasks.first(where: { $0.id == id }).map { needsUserAttention($0) } == true) ||
                (event.approvalRequestID != nil && event.approvalRequestID != previousApproval) ||
                (event.status != previousStatus && [.waiting, .completed, .failed, .cancelled].contains(event.status ?? .running))
            let permissionCheckOnly = event.sourceEvent == "PermissionRequest" && event.approvalRequestID == nil
            let settlingClaudeNotification = tasks.first(where: { $0.id == id }).map {
                $0.profile.kind == .claude && $0.sourceEvent == "Notification" && !needsUserAttention($0)
            } ?? false
            let settlingApprovalRequest = tasks.first(where: { $0.id == id }).map {
                $0.approvalRequestID != nil && !needsUserAttention($0)
            } ?? false
            if important && !permissionCheckOnly && !settlingClaudeNotification && !settlingApprovalRequest,
               tasks.first(where: { $0.id == id }).map({ isFresh($0) }) == true,
               let createdAt = event.createdAt, abs(now().timeIntervalSince(createdAt)) <= 120 {
                mediumUntil = now().addingTimeInterval(10)
                eventPulseUntil = mediumUntil
                highlightedTaskID = id
                attentionPulseTaskID = tasks.first(where: { $0.id == id }).map { needsUserAttention($0) } == true ? id : nil
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
        if age < 60 { return L("不到 1 分钟") }
        let minutes = Int(age / 60)
        if minutes < 60 { return LF("%lld 分钟前", minutes) }
        return LF("%lld 小时前", minutes / 60)
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
        // A resolved relay/prompt must not leave ten seconds of obsolete
        // attention behind. Do not clear another task's start/end feedback.
        if let id = attentionPulseTaskID, highlightedTaskID == id,
           tasks.first(where: { $0.id == id }).map({ needsUserAttention($0) }) != true {
            mediumUntil = .distantPast
            eventPulseUntil = .distantPast
            highlightedTaskID = nil
            attentionPulseTaskID = nil
        }
        // Short-lived native notices often disappear before a user can open
        // Claude. Mature a continuous wait once; duplicate notices do not
        // restart this clock or repeatedly reopen the island.
        for task in tasks where (task.profile.kind == .claude && task.sourceEvent == "Notification") || codexPromptInApp(task) {
            let start = claudeNotificationStarts[task.id] ?? task.updatedAt
            guard needsUserAttention(task), task.approvalRequestID == nil,
                  surfacedClaudeNotifications[task.id] != start else { continue }
            surfacedClaudeNotifications[task.id] = start
            mediumUntil = now().addingTimeInterval(10)
            eventPulseUntil = mediumUntil
            highlightedTaskID = task.id
            attentionPulseTaskID = task.id
        }
        for task in tasks {
            guard let request = approvalRequest(for: task), needsUserAttention(task),
                  !surfacedApprovalRequests.contains(request.id) else { continue }
            surfacedApprovalRequests.insert(request.id)
            mediumUntil = now().addingTimeInterval(10)
            eventPulseUntil = mediumUntil
            highlightedTaskID = task.id
            attentionPulseTaskID = task.id
        }
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
            approvalMinimized = false
            approvalHoldStartedAt = nil
            approvalReviewExpanded = false
            interaction = IslandInteraction()
            if let current = tasks.first(where: { $0.id == request.taskID }),
               current.status == .waiting, current.approvalRequestID == request.id,
               now() >= request.expiresAt {
                notice = "批准请求已过期或被处理，请在原应用核实"
                failedApprovals.insert(request.taskID)
                if let session = request.hostSessionID { failedApprovalSessions[request.taskID] = session }
                showApprovalOutcome(.failed, "已超时 · 回 App 处理", task: request.taskID, seconds: 10)
                eventPulseUntil = mediumUntil
            } else if !pendingApprovalTasks.isEmpty {
                // Answered in the app or on Feishu: move straight to the next one.
                continueWithNextApproval(after: request)
                if reviewingApproval != nil { return }
            }
        }
        if reviewingApproval != nil {
            // Ignored for a while (and not being held or read): tuck back into the notch.
            if !approvalMinimized, !approvalPointerInside, approvalHoldStartedAt == nil,
               now().timeIntervalSince(max(approvalCardShownAt, approvalPointerLeftAt)) >= Self.approvalMinimizeDelay {
                approvalMinimized = true
            }
            let target: Presentation = approvalMinimized ? .medium : .approval
            if presentation != target { presentation = target }
            return
        }
        if let outcome = approvalOutcome, now() >= outcome.until { approvalOutcome = nil }
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

    /// Sources that report they cannot resolve a turn; shown as 结果未知.
    private static let unknownResultEvents: Set<String> = ["DoubaoSilent", "DoubaoAbandoned", "AmbiguousTurn", "ClaudeChatUnknown"]

    /// Started, without terminal evidence, and not reported unknown. Hook
    /// providers stay quiet during long tool runs, so silence alone does not
    /// end a task until the unresolved limit guards against a lost Stop.
    private func isRunning(_ task: AgentTask) -> Bool {
        guard task.source.isLive, ongoingTaskIDs.contains(task.id),
              [.queued, .running, .waiting].contains(task.status),
              !Self.unknownResultEvents.contains(task.sourceEvent ?? ""),
              !["SupersededTrajectory", "HookTrackingEnded"].contains(task.sourceEvent ?? "") else { return false }
        let age = now().timeIntervalSince(task.updatedAt)
        let limit = task.profile.kind == .doubao ? DoubaoTrajectory.staleAfter : AgentActivityMotion.unresolvedLimit
        return age >= -5 && age <= limit
    }

    private func isFresh(_ task: AgentTask) -> Bool {
        let age = now().timeIntervalSince(task.updatedAt)
        guard !["DoubaoSilent", "DoubaoAbandoned", "AmbiguousTurn", "ClaudeChatUnknown", "SupersededTrajectory", "HookTrackingEnded"].contains(task.sourceEvent ?? "") else { return false }
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
