import Foundation
import LinglongtaiShared

@MainActor
func runClaudeApprovalStoreChecks(check: (String, Bool) -> Void, emit: (AgentEvent) throws -> Void) throws {
    var date = Date()
    let store = TaskStore(now: { date })
    store.clearAllTasks()
    let payload = try JSONSerialization.data(withJSONObject: ["hook_event_name": "PermissionRequest", "tool_name": "Bash", "cwd": "/tmp/approval-store-fixture", "tool_input": ["command": "printf harmless-fixture"]])
    let hostSession = "local_" + UUID().uuidString.lowercased()
    let hostLog = LinglongtaiPaths.applicationSupport.appendingPathComponent("fixture-claude-main.log")
    func hostLine(_ text: String) {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = Data((stamp.string(from: date) + " [info] " + text + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: hostLog) { handle.seekToEndOfFile(); handle.write(line); try? handle.close() }
        else { try? line.write(to: hostLog) }
    }
    func publish(desktopHost: Bool = false) throws -> ApprovalRelay.Request? {
        var event = AgentEvent(type: "upsert", id: UUID(), agent: "Claude", status: .waiting,
                               requiresApproval: true, createdAt: date, sourceEvent: "PermissionRequest")
        // Pin the host explicitly; the checks must not depend on the caller's environment.
        guard var request = ApprovalRelay.makeRequest(payload: payload, event: event, now: date) else { return nil }
        request.hostSessionID = desktopHost ? hostSession : nil
        request.toolName = desktopHost ? "Bash" : nil
        request.createdAt = desktopHost ? date : nil
        request.expiresAt = date.addingTimeInterval(45)
        guard ApprovalRelay.publish(request) else { return nil }
        event.approvalRequestID = request.id
        try emit(event)
        store.consumeEvents()
        return request
    }
    guard let request = try publish(), let task = store.tasks.first(where: { $0.id == request.taskID }) else {
        check("Claude approval store fixture publishes", false); return
    }
    check("Claude live relay waits briefly before attracting attention", store.approvalRequest(for: task) == request && !store.needsUserAttention(task) && store.waitingCount == 0 && store.presentation == .compact)
    date.addTimeInterval(1.2)
    store.refreshPresentation()
    check("Claude live relay attracts attention after a continuous wait", store.approvalRequest(for: task) == request && store.needsUserAttention(task) && store.waitingCount == 1 && store.presentation == .medium)
    store.reviewApproval(for: task)
    check("Claude review selects exact pending request", store.reviewingApproval == request)
    let reload = TaskStore(now: { date })
    check("reload preserves live relay", reload.tasks.first(where: { $0.id == task.id }).flatMap { reload.approvalRequest(for: $0) } == request)
    var impostor = task
    impostor.id = UUID()
    check("approval cannot cross task identity", store.approvalRequest(for: impostor) == nil)
    store.respondToApproval(request, decision: .allow)
    check("submission waits for real callback without fabricating running", store.tasks.first(where: { $0.id == task.id })?.status == .waiting && store.submittedApprovals[request.id] != nil && store.reviewingApproval == nil && store.approvalRequest(for: task) == nil)
    check("approval cannot be submitted twice", !ApprovalRelay.respond(to: request, decision: .deny))
    check("relay consumes exact explicit decision", ApprovalRelay.wait(for: request) == .allow)
    date.addTimeInterval(0.01)
    try emit(AgentEvent(type: "upsert", id: task.id, agent: "Claude", status: .running, requiresApproval: false, createdAt: date, sourceEvent: "PostToolUse"))
    store.consumeEvents()
    check("real callback clears pending approval", store.tasks.first(where: { $0.id == task.id })?.approvalRequestID == nil && store.waitingCount == 0)
    store.clearAllTasks()
    date = Date()
    guard let expired = try publish(), let expiredTask = store.tasks.first(where: { $0.id == expired.taskID }) else {
        check("Claude expiry fixture publishes", false); return
    }
    date = expired.expiresAt.addingTimeInterval(0.01)
    check("expired request removes actionable counter", store.approvalRequest(for: expiredTask) == nil && !store.needsUserAttention(expiredTask) && store.waitingCount == 0)
    store.respondToApproval(expired, decision: .allow)
    check("expired review cannot submit", store.submittedApprovals[expired.id] == nil && store.failedApprovals.contains(expired.taskID))
    ApprovalRelay.cleanup(expired.id)
    store.clearAllTasks()
    date = Date()
    guard let desktop = try publish(desktopHost: true), let desktopTask = store.tasks.first(where: { $0.id == desktop.taskID }) else {
        check("Claude Desktop fixture publishes", false); return
    }
    store.pollHostPrompts()
    check("Desktop permission check without a card never pops the island", store.approvalRequest(for: desktopTask) == nil && !store.needsUserAttention(desktopTask) && store.waitingCount == 0)
    let cardID = UUID().uuidString.lowercased()
    hostLine("Emitted tool permission request \(cardID) for Bash in session \(hostSession)")
    store.pollHostPrompts()
    check("Desktop card log line makes the request actionable at once", store.approvalRequest(for: desktopTask) == desktop && store.needsUserAttention(desktopTask) && store.approvalTask?.id == desktop.taskID)
    let otherCard = UUID().uuidString.lowercased()
    hostLine("Emitted tool permission request \(otherCard) for Bash in session \(hostSession)")
    store.pollHostPrompts()
    check("two open cards in one session are never pressed", store.approvalRequest(for: desktopTask) == nil)
    hostLine("Permission request \(otherCard) for Bash aborted")
    store.pollHostPrompts()
    check("an aborted card no longer counts; the request keeps its first card", store.approvalRequest(for: desktopTask) == desktop && store.hostPrompt(for: desktop)?.id == cardID)
    hostLine("Received permission response for \(cardID): once (tool: Bash)")
    store.pollHostPrompts()
    check("a card answered in the app withdraws the island button at once", store.approvalRequest(for: desktopTask) == nil)
    ApprovalRelay.cleanup(desktop.id)
    guard let stale = try publish(desktopHost: true), let staleTask = store.tasks.first(where: { $0.id == stale.taskID }) else {
        check("Claude Desktop stale fixture publishes", false); return
    }
    date.addTimeInterval(8)
    let lateCard = UUID().uuidString.lowercased()
    hostLine("Emitted tool permission request \(lateCard) for Bash in session \(hostSession)")
    store.pollHostPrompts()
    check("an old unanswered check is never matched to a later card", store.approvalRequest(for: staleTask) == nil)
    hostLine("Permission request \(lateCard) for Bash aborted")
    store.pollHostPrompts()
    ApprovalRelay.cleanup(stale.id)
    date.addTimeInterval(-8) // publish() only accepts requests created at the real present
    guard let unanswered = try publish(desktopHost: true), let unansweredTask = store.tasks.first(where: { $0.id == unanswered.taskID }) else {
        check("Claude Desktop second fixture publishes", false); return
    }
    hostLine("Emitted tool permission request \(UUID().uuidString.lowercased()) for Bash in session \(hostSession)")
    store.pollHostPrompts()
    store.respondToApproval(unanswered, decision: .allow)
    check("island decision on a Desktop card reaches the hook", store.submittedApprovals[unanswered.id] != nil && !store.failedApprovals.contains(unansweredTask.id) && ApprovalRelay.wait(for: unanswered) == .allow)
    store.clearAllTasks()

    let claudeNotification = UUID()
    date = Date()
    func notification(_ sourceEvent: String, status: AgentTaskStatus) throws {
        try emit(AgentEvent(type: "upsert", id: claudeNotification, agent: "Claude", status: status,
                            requiresApproval: status == .waiting, createdAt: date, sourceEvent: sourceEvent))
        store.consumeEvents()
    }
    try notification("UserPromptSubmit", status: .running)
    date.addTimeInterval(11)
    store.refreshPresentation()
    try notification("Notification", status: .waiting)
    check("Claude notification does not pulse before it settles", store.waitingCount == 0 && store.presentation == .compact)
    date.addTimeInterval(2)
    store.refreshPresentation()
    check("Claude notification surfaces only after a continuous wait", store.waitingCount == 1 && store.presentation == .medium)
    try notification("PostToolUse", status: .running)
    check("Claude notification pulse clears when the tool continues", store.waitingCount == 0 && store.presentation == .compact)
    store.clearAllTasks()
}
