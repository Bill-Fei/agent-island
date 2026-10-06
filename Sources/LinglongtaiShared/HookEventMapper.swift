import CryptoKit
import Foundation

/// Keeps only allowlisted lifecycle metadata. Never reads transcripts or copies
/// prompt, tool input/output, notification text, cwd, or environment variables.
public enum HookEventMapper {
    public static func map(provider: AgentKind, payload: Data, now: Date = Date()) -> AgentEvent? {
        guard [.codex, .claude, .workBuddy].contains(provider), payload.count <= 1_048_576,
              let input = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let name = input["hook_event_name"] as? String,
              let session = input["session_id"] as? String,
              validIdentifier(session) else { return nil }
        // Nested subagent Stop must not complete the parent session.
        if let agentID = input["agent_id"] as? String, !agentID.isEmpty { return nil }
        let turn: String?
        if let rawTurn = input["turn_id"], !(rawTurn is NSNull) {
            guard let value = rawTurn as? String, validIdentifier(value) else { return nil }
            turn = value
        } else {
            turn = nil
        }
        let sessionID = "s_" + digest(namespace: "session-v2", components: [provider.rawValue, session])
        let turnID = turn.map { "t_" + digest(namespace: "turn-v2", components: [sessionID, $0]) }
        let legacyID = uuid(bytes: Array(SHA256.hash(data: Data((provider.rawValue + ":" + session).utf8)).prefix(16)))
        let id = turnID.map { taskID(sessionID: sessionID, turnID: $0) } ?? legacyID
        var type = "upsert"
        let status: AgentTaskStatus?
        let detail: String
        switch name {
        case "SessionStart": type = "connection"; status = nil; detail = "已收到会话连接事件"
        case "UserPromptSubmit": status = .running; detail = "正在处理本轮请求"
        case "PreToolUse": status = .running; detail = "正在执行工具步骤"
        case "PostToolUse": status = .running; detail = "工具已返回，正在处理本轮请求"
        case "PostToolUseFailure": status = .running; detail = "工具返回错误，等待应用继续处理"
        case "PermissionRequest": status = .waiting; detail = "正在核对工具权限"
        case "Notification":
            guard ["permission_prompt", "elicitation_dialog", "agent_needs_input"].contains(input["notification_type"] as? String ?? "") else { return nil }
            status = .waiting; detail = "应用正在等待你的确认"
        case "Stop": status = .completed; detail = "本轮响应已结束"
        case "StopFailure": status = .failed; detail = "本轮响应发生错误，请查看原应用"
        case "Interrupt": status = .cancelled; detail = "本轮响应已中断"
        case "SessionEnd": type = "end-session"; status = .cancelled; detail = "会话已关闭"
        default: return nil
        }
        var event = AgentEvent(type: type, id: id, agent: provider.displayName,
                          title: provider == .claude ? "Claude Code 会话" : provider.displayName + " 会话",
                          status: status, detail: detail, model: provider.defaultModel,
                          requiresApproval: status == .waiting, colorHex: provider.colorHex,
                          createdAt: now, sourceEvent: name, sessionID: sessionID, turnID: turnID,
                          legacySessionID: legacyID)
        if ["PreToolUse", "PostToolUse", "PostToolUseFailure"].contains(name) {
            event.toolLabel = ToolStep.label(for: input["tool_name"] as? String)
            if let toolID = (input["tool_use_id"] ?? input["call_id"]) as? String, validIdentifier(toolID) {
                event.toolStepID = "tool_" + digest(namespace: "tool-v1", components: [sessionID, turnID ?? "", toolID])
            }
        }
        return event
    }

    static func localTurnID(sessionID: String, nonce: UUID) -> String {
        "l_" + digest(namespace: "local-turn-v2", components: [sessionID, nonce.uuidString])
    }

    static func taskID(sessionID: String, turnID: String) -> UUID {
        uuid(bytes: Array(SHA256.hash(data: identityData(namespace: "task-v2", components: [sessionID, turnID])).prefix(16)))
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 256
    }

    private static func digest(namespace: String, components: [String]) -> String {
        SHA256.hash(data: identityData(namespace: namespace, components: components))
            .map { String(format: "%02x", $0) }.joined()
    }

    private static func identityData(namespace: String, components: [String]) -> Data {
        Data(([namespace] + components).map { "\($0.utf8.count):\($0)" }.joined().utf8)
    }

    private static func uuid(bytes: [UInt8]) -> UUID {
        UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                    bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
