import Foundation
import LinglongtaiShared

/// Pure release-boundary checks. This suite deliberately never publishes an
/// approval or touches the user's application-support directory.
func runReleaseRevisionChecks(check: (String, Bool) -> Void) {
    let origin = Date(timeIntervalSince1970: 1_950_000_000)
    func event(_ name: String, toolID: String? = "tool-a", seconds: Double = 0) -> AgentEvent {
        var value = AgentEvent(type: "upsert", createdAt: origin.addingTimeInterval(seconds), sourceEvent: name)
        value.toolStepID = toolID
        value.toolLabel = "读取文件"
        return value
    }
    func task() -> AgentTask {
        AgentTask(agent: "Codex", title: "Release fixture", status: .running, detail: "", model: "")
    }

    var ledger = task()
    ledger.recordToolEvent(event("PreToolUse", seconds: 2))
    ledger.recordToolEvent(event("PreToolUse", seconds: 3))
    check("release: repeated pre-tool callbacks remain one in-flight execution",
          ledger.toolSteps.count == 1 && ledger.returnedToolSteps.isEmpty)
    ledger.recordToolEvent(event("PostToolUse", seconds: 1))
    check("release: an older post-tool callback cannot complete a newer in-flight execution",
          ledger.toolSteps.first?.state == .running && ledger.returnedToolSteps.isEmpty)
    ledger.recordToolEvent(event("PostToolUse", seconds: 4))
    let terminalLedger = ledger.toolSteps
    ledger.recordToolEvent(event("PreToolUse", seconds: 5))
    ledger.recordToolEvent(event("PostToolUse", seconds: 6))
    ledger.recordToolEvent(event("PostToolUseFailure", seconds: 7))
    check("release: a completed identified step is not reopened or recounted by replay",
          ledger.toolSteps == terminalLedger && ledger.returnedToolSteps.count == 1)
    ledger.recordToolEvent(event("PostToolUseFailure", toolID: "tool-b", seconds: 8))
    check("release: a returned failure is recorded even if its pre-tool callback was missed",
          ledger.returnedToolSteps.count == 2 && ledger.returnedToolSteps.first?.state == .failed)
    ledger.recordToolEvent(event("PreToolUse", toolID: "tool-c", seconds: 9))
    check("release: executed-step totals exclude still-running tools",
          ledger.toolSteps.count == 3 && ledger.returnedToolSteps.count == 2)
    check("release: returned steps are newest first",
          ledger.returnedToolSteps.map(\.id) == ["tool-b", "tool-a"])
    let beforeNonTools = ledger
    for name in ["UserPromptSubmit", "PermissionRequest", "Notification", "Stop", "SessionEnd"] {
        ledger.recordToolEvent(event(name, toolID: "not-a-tool", seconds: 10))
    }
    var missingDate = event("PostToolUse", toolID: "missing-date")
    missingDate.createdAt = nil
    ledger.recordToolEvent(missingDate)
    check("release: lifecycle events and callbacks without timestamps cannot invent steps", ledger == beforeNonTools)

    var observations = task()
    observations.recordToolEvent(event("PreToolUse", toolID: nil, seconds: 0))
    observations.recordToolEvent(event("PostToolUse", toolID: nil, seconds: 1))
    observations.recordToolEvent(event("PostToolUse", toolID: nil, seconds: 1))
    check("release: exact anonymous callback replay is deduplicated without pairing unknown executions",
          observations.toolSteps.count == 2 && observations.returnedToolSteps.count == 1 && observations.hasUnidentifiedToolSteps)
    observations.recordToolEvent(event("PostToolUse", toolID: nil, seconds: 2))
    check("release: distinct anonymous observations stay explicitly unidentified",
          observations.returnedToolSteps.count == 2 && observations.hasUnidentifiedToolSteps)

    do {
        let rawID = "PRIVATE_RELEASE_TOOL_CALL"
        func mapped(_ name: String, turn: String = "turn-a", callKey: String = "tool_use_id", provider: AgentKind = .codex) throws -> AgentEvent? {
            let input: [String: Any] = [
                "hook_event_name": name, "session_id": "release-session", "turn_id": turn,
                callKey: rawID, "tool_name": "Read", "tool_input": ["path": "PRIVATE_RELEASE_PATH"]
            ]
            return HookEventMapper.map(provider: provider, payload: try JSONSerialization.data(withJSONObject: input), now: origin)
        }
        let pre = try mapped("PreToolUse"), post = try mapped("PostToolUse")
        check("release: pre/post for a real tool call share one stable hashed step identity",
              pre?.toolStepID != nil && pre?.toolStepID == post?.toolStepID && pre?.toolLabel == "读取文件")
        check("release: the call_id alias maps to the same execution identity",
              try mapped("PostToolUse", callKey: "call_id")?.toolStepID == pre?.toolStepID)
        check("release: identical raw call IDs remain isolated by provider and turn",
              try mapped("PostToolUse", turn: "turn-b")?.toolStepID != pre?.toolStepID &&
              mapped("PostToolUse", provider: .claude)?.toolStepID != pre?.toolStepID)
        let encoded = String(decoding: try JSONEncoder().encode(pre), as: UTF8.self)
        check("release: tool accounting does not persist raw call IDs or tool inputs",
              !encoded.contains(rawID) && !encoded.contains("PRIVATE_RELEASE_PATH"))
        check("release: step ledger survives encoding with its exact deduplicated outcome",
              try JSONDecoder().decode(AgentTask.self, from: JSONEncoder().encode(ledger)) == ledger)
    } catch {
        check("release: tool identity fixture serialization succeeded: \(error)", false)
    }

    var permission = AgentEvent(type: "upsert", id: UUID(), agent: "Codex", status: .waiting,
                                requiresApproval: true, createdAt: origin, sourceEvent: "PermissionRequest")
    func payload(_ input: Any, tool: String = "Bash") -> Data {
        (try? JSONSerialization.data(withJSONObject: ["hook_event_name": "PermissionRequest", "tool_name": tool, "cwd": "/tmp/release-fixture", "tool_input": input])) ?? Data()
    }
    let safe = payload(["command": "printf release-fixture"])
    for provider in [AgentKind.codex, .workBuddy] {
        permission.agent = provider.displayName
        check("release: \(provider.rawValue) PermissionRequest stays observer-only",
              ApprovalRelay.makeRequest(payload: safe, event: permission, now: origin) == nil)
    }
    permission.agent = "Claude"
    check("release: complete Claude Code request reaches relay validation", ApprovalRelay.makeRequest(payload: safe, event: permission, now: origin) != nil)
    let missingCwd = try! JSONSerialization.data(withJSONObject: ["hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_input": ["command": "printf fixture"]])
    check("release: a missing working directory never produces an under-specified approval",
          ApprovalRelay.makeRequest(payload: missingCwd, event: permission, now: origin) == nil)
    for input in [["authorization": "bearer fixture"], ["command": "read .env"], ["password": "fixture"], ["nested": "api_key=fixture"]] {
        check("release: sensitive approval context is excluded from secondary surface",
              ApprovalRelay.makeRequest(payload: payload(input), event: permission, now: origin) == nil)
    }
    check("release: malformed approval payload falls back safely",
          ApprovalRelay.makeRequest(payload: Data("invalid".utf8), event: permission, now: origin) == nil)
    check("release: scalar tool input cannot become an approval request",
          ApprovalRelay.makeRequest(payload: payload("not-an-object"), event: permission, now: origin) == nil)
    check("release: oversized context is rejected rather than truncated before approval",
          ApprovalRelay.makeRequest(payload: payload(["command": String(repeating: "x", count: 8_193)]), event: permission, now: origin) == nil)
    permission.id = nil
    check("release: missing task identity cannot create a detached approval request",
          ApprovalRelay.makeRequest(payload: safe, event: permission, now: origin) == nil)
    permission.id = UUID()
    for source in ["Notification", "PreToolUse", "Stop"] {
        permission.sourceEvent = source
        check("release: \(source) cannot impersonate an actionable PermissionRequest",
              ApprovalRelay.makeRequest(payload: safe, event: permission, now: origin) == nil)
    }
    permission.sourceEvent = "PermissionRequest"
    for provider in [AgentKind.doubao, .custom] {
        permission.agent = provider.displayName
        check("release: unsupported \(provider.rawValue) approval is never fabricated",
              ApprovalRelay.makeRequest(payload: safe, event: permission, now: origin) == nil)
    }

    var hover = IslandInteraction()
    hover.samplePointer(inside: true, at: 0)
    hover.samplePointer(inside: true, at: 0.199)
    check("release: hover remains compact throughout the full intent dwell",
          hover.presentation(hasLiveEvent: true, autoPop: true, hoverEnabled: true, prefersMedium: false) == .compact)
    hover.samplePointer(inside: false, at: 0.199)
    hover.samplePointer(inside: true, at: 2)
    hover.samplePointer(inside: true, at: 2.199)
    check("release: a cancelled dwell cannot be accumulated across separate visits", !hover.isHovering)
    hover.samplePointer(inside: true, at: 2.2)
    check("release: 200 continuous milliseconds after re-entry opens detail", hover.isHovering)
    check("release: hover opt-out still blocks dwell-triggered expansion",
          hover.presentation(hasLiveEvent: true, autoPop: true, hoverEnabled: false, prefersMedium: false) == .compact)
}
