import Foundation
import LinglongtaiShared

func runButlerRevisionChecks(check: (String, Bool) -> Void) {
    let date = Date()
    var task = AgentTask(agent: "Codex", title: "test", status: .running, detail: "", model: "")
    func event(_ name: String, id: String? = "tool-a", seconds: Double = 0) -> AgentEvent {
        var e = AgentEvent(type: "upsert", createdAt: date.addingTimeInterval(seconds), sourceEvent: name)
        e.toolStepID = id
        e.toolLabel = "执行命令"
        return e
    }
    task.recordToolEvent(event("UserPromptSubmit"))
    check("prompts are not counted as tools", task.toolSteps.isEmpty)
    task.recordToolEvent(event("PreToolUse"))
    check("pre-tool is not an executed step", task.returnedToolSteps.isEmpty)
    task.recordToolEvent(event("PostToolUse", seconds: 1))
    task.recordToolEvent(event("PostToolUse", seconds: 2))
    check("identified step is counted once across duplicate callbacks", task.returnedToolSteps.count == 1)
    task.recordToolEvent(event("PostToolUseFailure", id: "tool-b", seconds: 3))
    check("tool failures remain explicit", task.returnedToolSteps.first?.state == .failed)
    task.recordToolEvent(event("PostToolUse", id: nil, seconds: 4))
    check("unidentified callbacks are marked observations", task.hasUnidentifiedToolSteps)
    check("unexpected tool names are not copied into UI", ToolStep.label(for: "PRIVATE_DATA") == "工具调用")
    let encoded = try! JSONEncoder().encode(task)
    check("tool ledger survives snapshot roundtrip", (try? JSONDecoder().decode(AgentTask.self, from: encoded)) == task)

    var mapped = AgentEvent(type: "upsert", id: UUID(), agent: "Codex", status: .waiting,
                            requiresApproval: true, sourceEvent: "PermissionRequest")
    func payload(_ args: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["tool_name": "Bash", "cwd": "/tmp/approval-fixture", "tool_input": args])
    }
    let safe = payload(["command": "printf hello"])
    let request = ApprovalRelay.makeRequest(payload: safe, event: mapped, now: date)
    check("permission relay binds one exact task and expires in 45 seconds",
          request?.taskID == mapped.id && request?.expiresAt == date.addingTimeInterval(45))
    check("credentials are not copied into approval cache", ApprovalRelay.makeRequest(payload: payload(["token": "private"]), event: mapped) == nil)
    check("oversized approval inputs fall back rather than truncate", ApprovalRelay.makeRequest(payload: payload(["command": String(repeating: "x", count: 9000)]), event: mapped) == nil)
    mapped.sourceEvent = "Notification"
    check("notification alone cannot offer approval", ApprovalRelay.makeRequest(payload: safe, event: mapped) == nil)
    mapped.sourceEvent = "PermissionRequest"
    mapped.agent = "豆包"
    check("unverified provider cannot offer approval", ApprovalRelay.makeRequest(payload: safe, event: mapped) == nil)
}
