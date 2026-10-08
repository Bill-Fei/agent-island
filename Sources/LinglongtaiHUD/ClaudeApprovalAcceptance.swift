import Foundation
import LinglongtaiShared

@MainActor
func runClaudeApprovalStoreChecks(check: (String, Bool) -> Void, emit: (AgentEvent) throws -> Void) throws {
    var date = Date()
    let store = TaskStore(now: { date })
    store.clearAllTasks()
    let payload = try JSONSerialization.data(withJSONObject: ["hook_event_name": "PermissionRequest", "tool_name": "Bash", "cwd": "/tmp/approval-store-fixture", "tool_input": ["command": "printf harmless-fixture"]])
    func publish() throws -> ApprovalRelay.Request? {
        var event = AgentEvent(type: "upsert", id: UUID(), agent: "Claude", status: .waiting,
                               requiresApproval: true, createdAt: date, sourceEvent: "PermissionRequest")
        guard let request = ApprovalRelay.makeRequest(payload: payload, event: event, now: date), ApprovalRelay.publish(request) else { return nil }
        event.approvalRequestID = request.id
        try emit(event)
        store.consumeEvents()
        return request
    }
    guard let request = try publish(), let task = store.tasks.first(where: { $0.id == request.taskID }) else {
        check("Claude approval store fixture publishes", false); return
    }
    check("Claude live relay attracts attention", store.approvalRequest(for: task) == request && store.needsUserAttention(task) && store.waitingCount == 1 && store.presentation == .medium)
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
}
