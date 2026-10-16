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
    check("step summary counts each kind once per execution", task.toolStepSummary == "跑命令 3 次" && task.failedToolStepCount == 1)
    var mixed = AgentTask(agent: "Claude", title: "test", status: .completed, detail: "", model: "")
    check("no summary without returned steps", mixed.toolStepSummary == nil)
    for (index, label) in ["读取文件", "编辑文件", "读取文件", "执行命令"].enumerated() {
        var e = AgentEvent(type: "upsert", createdAt: date.addingTimeInterval(Double(index)), sourceEvent: "PostToolUse")
        e.toolStepID = "mixed-\(index)"
        e.toolLabel = label
        mixed.recordToolEvent(e)
    }
    check("step summary leads with changes, then reads",
          mixed.toolStepSummary == "改文件 1 次 · 跑命令 1 次 · 读文件 2 次")
    let encoded = try! JSONEncoder().encode(task)
    check("tool ledger survives snapshot roundtrip", (try? JSONDecoder().decode(AgentTask.self, from: encoded)) == task)

    var mapped = AgentEvent(type: "upsert", id: UUID(), agent: "Claude", status: .waiting,
                            requiresApproval: true, sourceEvent: "PermissionRequest")
    func payload(_ args: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["hook_event_name": "PermissionRequest", "tool_name": "Bash", "cwd": "/tmp/approval-fixture", "tool_input": args])
    }
    let safe = payload(["command": "printf hello"])
    check("only Claude Code and Codex support single-use approval requests",
          ApprovalRelay.supports(.claude) && ApprovalRelay.supports(.codex) && !ApprovalRelay.supports(.workBuddy) &&
          ApprovalRelay.lifetime(for: .codex) == 20 && ApprovalRelay.lifetime(for: .claude) == 45 &&
          ApprovalRelay.makeRequest(payload: safe, event: mapped, now: date)?.protocolVersion == 2)
    check("credential-like permission input never reaches an island cache", ApprovalRelay.makeRequest(payload: payload(["token": "private"]), event: mapped) == nil)
    check("oversized permission input never reaches an island cache", ApprovalRelay.makeRequest(payload: payload(["command": String(repeating: "x", count: 9000)]), event: mapped) == nil)
    mapped.sourceEvent = "Notification"
    check("notification alone cannot offer approval", ApprovalRelay.makeRequest(payload: safe, event: mapped) == nil)
    mapped.sourceEvent = "PermissionRequest"
    mapped.agent = "豆包"
    check("unverified provider cannot offer approval", ApprovalRelay.makeRequest(payload: safe, event: mapped) == nil)
}
