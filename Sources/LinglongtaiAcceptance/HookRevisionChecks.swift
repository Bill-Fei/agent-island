import Foundation
import LinglongtaiShared

func runHookRevisionChecks(check: (String, Bool) -> Void) {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let secretSession = "PRIVATE_SESSION_IDENTIFIER"
    let secretTurn = "PRIVATE_TURN_IDENTIFIER"
    let secret = "PRIVATE_CONVERSATION_SENTINEL"

    func mapped(_ name: String, provider: AgentKind = .claude,
                session: String = "session-a", turn: String? = nil) -> AgentEvent? {
        var input: [String: Any] = ["hook_event_name": name, "session_id": session,
                                  "prompt": secret, "tool_input": ["command": secret],
                                  "transcript_path": "/private/" + secret]
        if let turn { input["turn_id"] = turn }
        guard let data = try? JSONSerialization.data(withJSONObject: input) else { return nil }
        return HookEventMapper.map(provider: provider, payload: data, now: now)
    }

    func route(_ tracker: inout HookTurnTracker, _ name: String,
               provider: AgentKind = .claude, session: String = "session-a",
               turn: String? = nil) -> [AgentEvent] {
        guard let event = mapped(name, provider: provider, session: session, turn: turn) else { return [] }
        return tracker.route(event)
    }

    func task(_ status: AgentTaskStatus, _ source: String) -> AgentTask {
        AgentTask(agent: "Claude", title: "本地验收", status: status,
                  detail: "", model: "Claude Code", source: .liveEvent, sourceEvent: source)
    }

    do {
        var tracker = HookTurnTracker()
        let first = route(&tracker, "UserPromptSubmit").first
        let connection = route(&tracker, "SessionStart").first
        let tool = route(&tracker, "PreToolUse").first
        let returned = route(&tracker, "PostToolUse").first
        let stop = route(&tracker, "Stop").first
        let second = route(&tracker, "UserPromptSubmit").first
        let permission = route(&tracker, "PermissionRequest").first
        let secondStop = route(&tracker, "Stop").first
        check("anonymous serial rounds retain their own tool/permission/stop identity",
              first?.id != nil && first?.id == tool?.id && first?.id == returned?.id &&
              first?.id == stop?.id && second?.id == permission?.id && second?.id == secondStop?.id)
        check("same-session new prompt creates a distinct round",
              first?.id != second?.id && first?.sessionID == second?.sessionID && first?.turnID != second?.turnID)
        check("late SessionStart neither starts nor resets a task", connection?.type == "connection" && connection?.status == nil)
        check("tool return and request phases make no inference about thinking",
              task(.running, "UserPromptSubmit").statusLabel == "处理中" &&
              task(.running, "PreToolUse").statusLabel == "执行工具" &&
              task(.running, "PostToolUse").statusLabel == "处理中" &&
              task(.running, "PostToolUseFailure").statusLabel == "处理中")
        check("actual terminal status wins over an old running phase",
              task(.completed, "PreToolUse").statusLabel == "本轮已结束" &&
              task(.failed, "UserPromptSubmit").statusLabel == "本轮响应失败" &&
              task(.cancelled, "PostToolUse").statusLabel == "本轮已中断")
        check("ambiguous active phases never claim current execution",
              task(.running, "AmbiguousTurn").statusLabel == "结果未知" &&
              task(.waiting, "AmbiguousTurn").statusLabel == "结果未知")

        var concurrent = HookTurnTracker()
        let turnA = route(&concurrent, "UserPromptSubmit", turn: "turn-a").first
        let turnB = route(&concurrent, "UserPromptSubmit", turn: "turn-b").first
        let nativeDuplicate = route(&concurrent, "UserPromptSubmit", turn: "turn-a").first
        let stopA = route(&concurrent, "Stop", turn: "turn-a").first
        let waitB = route(&concurrent, "PermissionRequest", turn: "turn-b").first
        check("native duplicate and concurrent rounds are keyed by session plus turn",
              turnA?.id != nil && turnA?.id == nativeDuplicate?.id && turnA?.id != turnB?.id &&
              stopA?.id == turnA?.id && waitB?.id == turnB?.id && waitB?.status == .waiting)
        check("late native tool callbacks cannot resurrect a stopped round",
              route(&concurrent, "PreToolUse", turn: "turn-a").isEmpty)
        check("untagged late stop after overlapping native rounds cannot close its peer",
              route(&concurrent, "Stop").first?.type == "ambiguous-turn")
        check("same native turn string in another session cannot collide",
              mapped("Stop", session: "session-b", turn: "turn-a")?.id != turnA?.id)
        check("legacy migration handle is stable across native turns",
              turnA?.legacySessionID != nil && turnA?.legacySessionID == turnB?.legacySessionID &&
              turnA?.legacySessionID == mapped("Stop")?.id)

        // Providers that may run rounds side by side keep the ambiguity guard.
        var overlapping = HookTurnTracker()
        let anonymousA = route(&overlapping, "UserPromptSubmit", provider: .workBuddy).first
        let anonymousB = route(&overlapping, "UserPromptSubmit", provider: .workBuddy)
        let uncertainStop = route(&overlapping, "Stop", provider: .workBuddy)
        let uncertainPermission = route(&overlapping, "PermissionRequest", provider: .workBuddy)
        check("overlapping anonymous prompts preserve two independent rows",
              anonymousA?.id != nil && anonymousB.count == 2 && anonymousB[0].id != anonymousA?.id &&
              anonymousB[1].type == "ambiguous-turn")
        check("uncorrelated stop and permission cannot finish or target another round",
              uncertainStop.count == 1 && uncertainStop[0].type == "ambiguous-turn" &&
              uncertainStop[0].id == nil && uncertainStop[0].status == nil &&
              uncertainPermission.first?.type == "ambiguous-turn" && uncertainPermission.first?.status == nil)
        let sessionEnd = route(&overlapping, "SessionEnd", provider: .workBuddy).first
        let afterEnd = route(&overlapping, "UserPromptSubmit", provider: .workBuddy)
        check("session end clears ambiguous routing for the next session round",
              sessionEnd?.type == "end-session" && sessionEnd?.sessionID == anonymousA?.sessionID &&
              afterEnd.count == 1 && afterEnd[0].type == "upsert" && afterEnd[0].id != anonymousA?.id)

        // An interrupted Claude round never sends Stop; the next prompt must
        // still own its tool, permission and stop callbacks.
        var interrupted = HookTurnTracker()
        let abandoned = route(&interrupted, "UserPromptSubmit").first
        _ = route(&interrupted, "PreToolUse")
        let resumed = route(&interrupted, "UserPromptSubmit")
        let resumedPermission = route(&interrupted, "PermissionRequest")
        let resumedStop = route(&interrupted, "Stop")
        check("a new Claude prompt retires an unfinished round instead of going ambiguous",
              resumed.count == 1 && resumed[0].type == "upsert" && resumed[0].id != abandoned?.id &&
              resumedPermission.count == 1 && resumedPermission[0].id == resumed[0].id &&
              resumedPermission[0].status == .waiting &&
              resumedStop.count == 1 && resumedStop[0].id == resumed[0].id && resumedStop[0].status == .completed)
        check("the retired Claude round ends without an invented outcome",
              abandoned?.id.flatMap { interrupted.terminalStates[$0]?.isTerminal } == true)

        // Sessions already stuck by the earlier rule must recover on their next prompt.
        if let stuckSession = mapped("Stop")?.sessionID {
            let stuckJSON = """
            {"sessions":{"\(stuckSession)":{"ambiguous":true,"closed":false,"turns":{
            "t_a":{"id":"\(UUID().uuidString)","isNative":false,"isTerminal":false},
            "t_b":{"id":"\(UUID().uuidString)","isNative":false,"isTerminal":false}}}}}
            """
            var stuck = try JSONDecoder().decode(HookTurnTracker.self, from: Data(stuckJSON.utf8))
            let recovered = route(&stuck, "UserPromptSubmit")
            let recoveredTool = route(&stuck, "PreToolUse")
            check("a Claude session stuck as ambiguous recovers on the next prompt",
                  recovered.count == 1 && recovered[0].type == "upsert" &&
                  recoveredTool.count == 1 && recoveredTool[0].id == recovered[0].id)
        } else {
            check("stuck Claude session fixture maps", false)
        }

        var upgrade = HookTurnTracker()
        let provisional = route(&upgrade, "UserPromptSubmit").first
        let withNative = route(&upgrade, "PreToolUse", turn: "native-arrived-later").first
        let upgradedStop = route(&upgrade, "Stop").first
        check("first native turn metadata upgrades only the sole anonymous round",
              withNative?.replacesTaskID == provisional?.id && withNative?.id != provisional?.id &&
              upgradedStop?.id == withNative?.id && upgradedStop?.turnID == withNative?.turnID)

        var persisted = HookTurnTracker()
        let beforeRestart = route(&persisted, "UserPromptSubmit", session: secretSession).first
        let encoded = try JSONEncoder().encode(persisted)
        var restored = try JSONDecoder().decode(HookTurnTracker.self, from: encoded)
        let afterRestart = route(&restored, "Stop", session: secretSession).first
        check("sidecar round-trip preserves the pending turn across CLI processes",
              beforeRestart?.id != nil && beforeRestart?.id == afterRestart?.id)

        let privateEvent = mapped("UserPromptSubmit", session: secretSession, turn: secretTurn)
        let eventData = try JSONEncoder().encode(privateEvent)
        let allPersisted = String(decoding: encoded + eventData, as: UTF8.self)
        check("raw session/turn identifiers and conversation content never enter persistence",
              !allPersisted.contains(secretSession) && !allPersisted.contains(secretTurn) &&
              !allPersisted.contains(secret) && !allPersisted.contains("transcript_path") &&
              privateEvent?.sessionID?.hasPrefix("s_") == true && privateEvent?.turnID?.hasPrefix("t_") == true)
        check("malformed upstream turn identifiers are rejected",
              mapped("Stop", turn: "") == nil && mapped("Stop", turn: String(repeating: "x", count: 257)) == nil)

        let providerEvents = [AgentKind.codex, .claude, .workBuddy].compactMap {
            mapped("UserPromptSubmit", provider: $0, session: secretSession, turn: secretTurn)
        }
        check("three providers using identical upstream ids remain independent",
              Set(providerEvents.compactMap(\.id)).count == 3 && Set(providerEvents.compactMap(\.sessionID)).count == 3)
    } catch {
        check("hook revision fixtures encode and decode without user data", false)
    }
}
