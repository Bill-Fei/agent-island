import Foundation

/// Hash-only routing state. The caller must load, route, persist and append
/// under one shared lock; independent instances do not synchronize processes.
public struct HookTurnTracker: Codable, Sendable {
    private struct Turn: Codable, Sendable {
        var id: UUID
        var isNative: Bool
        var isTerminal: Bool
    }

    private struct Session: Codable, Sendable {
        var turns: [String: Turn] = [:]
        var ambiguous = false
        var closed = false
        var active: [String: Turn] { turns.filter { !$0.value.isTerminal } }
    }

    private var sessions: [String: Session] = [:]
    public init() {}

    public mutating func route(_ event: AgentEvent, localTurnID: UUID = UUID()) -> [AgentEvent] {
        guard let sessionID = event.sessionID, let name = event.sourceEvent else { return [] }
        var session = sessions[sessionID] ?? Session()
        if event.type == "connection" {
            // WorkBuddy may connect after submitting; never reset active work.
            session.closed = false
            sessions[sessionID] = session
            return [event]
        }
        if event.type == "end-session" {
            for key in Array(session.turns.keys) { session.turns[key]?.isTerminal = true }
            session.ambiguous = false
            session.closed = true
            sessions[sessionID] = session
            return [event]
        }
        guard event.type == "upsert", let status = event.status else { return [] }
        let terminal = [.completed, .failed, .cancelled].contains(status)

        if let turnID = event.turnID {
            var routed = event
            if let previous = session.turns[turnID], previous.isTerminal { return [] }
            if session.turns[turnID] == nil, !session.ambiguous,
               name != "UserPromptSubmit", session.active.count == 1,
               let anonymous = session.active.first, !anonymous.value.isNative {
                routed.replacesTaskID = anonymous.value.id
                session.turns.removeValue(forKey: anonymous.key)
            }
            guard let id = routed.id else { return [] }
            session.turns[turnID] = Turn(id: id, isNative: true, isTerminal: terminal)
            // Even after one explicitly identified round stops, an untagged
            // callback could still belong to that round rather than its peer.
            if session.active.count > 1 { session.ambiguous = true }
            if session.active.isEmpty { session.ambiguous = false }
            session.closed = false
            sessions[sessionID] = session
            return [routed]
        }

        if name == "UserPromptSubmit" {
            let overlaps = !session.active.isEmpty
            let turnID = HookEventMapper.localTurnID(sessionID: sessionID, nonce: localTurnID)
            let routed = assigning(event, sessionID: sessionID, turnID: turnID)
            guard let id = routed.id else { return [] }
            session.turns[turnID] = Turn(id: id, isNative: false, isTerminal: false)
            session.closed = false
            session.ambiguous = overlaps || session.ambiguous
            sessions[sessionID] = session
            return session.ambiguous ? [routed, ambiguity(from: event)] : [routed]
        }

        if session.closed { return [] }
        if session.ambiguous || session.active.count > 1 {
            session.ambiguous = true
            sessions[sessionID] = session
            return [ambiguity(from: event)]
        }
        if let active = session.active.first {
            let routed = assigning(event, sessionID: sessionID, turnID: active.key)
            session.turns[active.key]?.isTerminal = terminal
            sessions[sessionID] = session
            return [routed]
        }
        // A callback after a closed turn may be delayed. Only a prompt or an
        // explicit new turn id is sufficient evidence for a new row.
        if !session.turns.isEmpty { return [] }

        // Hooks can be installed mid-session; retain the first real event.
        let turnID = HookEventMapper.localTurnID(sessionID: sessionID, nonce: localTurnID)
        let routed = assigning(event, sessionID: sessionID, turnID: turnID)
        guard let id = routed.id else { return [] }
        session.turns[turnID] = Turn(id: id, isNative: false, isTerminal: terminal)
        sessions[sessionID] = session
        return [routed]
    }

    private func assigning(_ event: AgentEvent, sessionID: String, turnID: String) -> AgentEvent {
        var result = event
        result.turnID = turnID
        result.id = HookEventMapper.taskID(sessionID: sessionID, turnID: turnID)
        return result
    }

    private func ambiguity(from event: AgentEvent) -> AgentEvent {
        var result = event
        result.type = "ambiguous-turn"
        result.id = nil
        result.turnID = nil
        result.status = nil
        result.requiresApproval = false
        result.replacesTaskID = nil
        result.detail = "同一会话有重叠请求，事件未携带轮次标识，等待明确状态更新"
        return result
    }
}
