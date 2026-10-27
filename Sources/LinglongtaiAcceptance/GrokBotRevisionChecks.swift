import Foundation
import LinglongtaiShared

/// Grok Bot is observed through its local conversation replica instead of a
/// hook. These checks pin the lifecycle derivation and the privacy boundary.
func runGrokBotRevisionChecks(check: (String, Bool) -> Void) {
    let now = Date()
    func ms(_ age: TimeInterval) -> Double { (now.timeIntervalSince1970 - age) * 1000 }
    func replica(_ entries: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "value": ["entries": entries]])
    }
    func user(_ id: String, age: TimeInterval) -> [String: Any] {
        ["kind": "message", "role": "user", "id": id, "timestampMs": ms(age), "isStreaming": false, "richText": "私密内容"]
    }
    func reply(age: TimeInterval, type: String = "text", extra: [String: Any] = [:]) -> [String: Any] {
        var row: [String: Any] = ["kind": "send-message", "id": UUID().uuidString, "timestampMs": ms(age),
                                  "message": ["type": type, "content": "私密回复"]]
        row.merge(extra) { $1 }
        return row
    }
    func phase(_ entries: [[String: Any]]) -> GrokBotActivity.Phase? {
        GrokBotActivity.observation(sessionKey: "agent", data: replica(entries)).map { GrokBotActivity.phase(of: $0, now: now) }
    }

    check("grok: fresh prompt without reply is running", phase([user("u1", age: 5)]) == .running(replying: false))
    check("grok: reply still settling is running", phase([user("u1", age: 20), reply(age: 10)]) == .running(replying: true))
    check("grok: settled reply finishes the turn", phase([user("u1", age: 120), reply(age: 100)]) == .finished(awaitingUser: false))
    check("grok: unanswered widget waits for the user",
          phase([user("u1", age: 20), reply(age: 10, type: "widget")]) == .finished(awaitingUser: true))
    check("grok: answered widget does not wait",
          phase([user("u1", age: 120), reply(age: 100, type: "widget", extra: ["respondedValue": "ok"])]) == .finished(awaitingUser: false))
    if case .unknown = phase([user("u1", age: 600)]) { check("grok: silence without reply is unknown, never completed", true) }
    else { check("grok: silence without reply is unknown, never completed", false) }
    check("grok: no user message is not a turn", phase([reply(age: 5)]) == nil)
    check("grok: older reply belongs to the previous turn",
          phase([user("u0", age: 300), reply(age: 290), user("u1", age: 5)]) == .running(replying: false))

    let observation = GrokBotActivity.observation(sessionKey: "agent", data: replica([user("u1", age: 120), reply(age: 100)]))!
    let event = GrokBotActivity.event(for: observation, now: now)
    let encoded = String(data: (try? JSONEncoder().encode(event)) ?? Data(), encoding: .utf8) ?? ""
    check("grok: events never carry message content", !encoded.contains("私密"))
    check("grok: events are read-only", event.requiresApproval == false && AgentKind.resolve(event.agent ?? "") == .grokBot)
    check("grok: hook channel still refuses Grok Bot",
          HookEventMapper.map(provider: .grokBot, payload: Data(#"{"hook_event_name":"Stop","session_id":"abc"}"#.utf8)) == nil)

    // Persistence file names are base32 of the storage key.
    let agentID = "d3a7fa7d-1053-49f1-b41c-08650687c69b"
    let key = "sand.client.slice.account.me.transcript.replicas.\(agentID)"
    let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
    var bits = "", name = ""
    for byte in Array(key.utf8) { bits += String(byte, radix: 2).leftPadded(to: 8) }
    while bits.count % 5 != 0 { bits += "0" }
    var index = bits.startIndex
    while index < bits.endIndex {
        let next = bits.index(index, offsetBy: 5)
        name.append(alphabet[Int(bits[index..<next], radix: 2)!])
        index = next
    }
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("linglongtai-grok-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    try? replica([user("u1", age: 5)]).write(to: base.appendingPathComponent(name + ".blob"))
    try? Data("{}".utf8).write(to: base.appendingPathComponent("unrelated.blob"))
    check("grok: replica files are found by decoded key", GrokBotActivity.transcriptFiles(root: base).map(\.key) == [agentID])
    var tracker = GrokBotTracker()
    let first = tracker.poll(root: base, now: now)
    check("grok: tracker reports a live turn once", first.count == 1 && first.first?.status == .running && tracker.poll(root: base, now: now).isEmpty)
}

private extension String {
    func leftPadded(to length: Int) -> String { String(repeating: "0", count: max(0, length - count)) + self }
}
