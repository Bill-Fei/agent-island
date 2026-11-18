import Foundation
import LinglongtaiShared
import SQLite3

/// "帮我批准" (auto_review): Codex asks no one, so the island must not either.
func runCodexAutoReviewChecks(check: (String, Bool) -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-auto-review-\(UUID().uuidString)/sessions")
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: now)
    let folder = root.appendingPathComponent(String(format: "%04d/%02d/%02d", parts.year!, parts.month!, parts.day!))
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    func rollout(_ reviewers: [String], padding: Int = 0) -> (session: String, url: URL) {
        let session = UUID().uuidString.lowercased()
        let url = folder.appendingPathComponent("rollout-2026-11-07T12-00-00-\(session).jsonl")
        var lines = [#"{"timestamp":"2026-11-07T04:00:00.000Z","type":"session_meta","payload":{}}"#]
        for reviewer in reviewers {
            lines.append(#"{"timestamp":"2026-11-07T04:00:01.000Z","type":"turn_context","payload":{"approval_policy":"on-request","approvals_reviewer":"\#(reviewer)"}}"#)
            lines.append(#"{"timestamp":"2026-11-07T04:00:02.000Z","type":"response_item","payload":{"type":"custom_tool_call"}}"#)
        }
        if padding > 0 {
            let filler = String(repeating: "x", count: 777)
            for _ in 0..<padding { lines.append(#"{"timestamp":"2026-11-07T04:00:03.000Z","type":"response_item","payload":{"type":"function_call_output","output":"\#(filler)"}}"#) }
        }
        try? lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        return (session, url)
    }
    func input(session: String, transcript: String?) -> Data {
        var object: [String: Any] = ["hook_event_name": "PermissionRequest", "session_id": session]
        if let transcript { object["transcript_path"] = transcript }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    let auto = rollout(["user", "auto_review"])
    check("codex auto-review: transcript path is recognised",
          CodexRollout.reviewsApprovalsItself(hookInput: input(session: auto.session, transcript: auto.url.path), root: root, now: now))
    check("codex auto-review: found by session without transcript path",
          CodexRollout.reviewsApprovalsItself(hookInput: input(session: auto.session, transcript: nil), root: root, now: now))
    let long = rollout(["user", "auto_review"], padding: 4_000)
    check("codex auto-review: setting found behind several MB of output",
          CodexRollout.reviewsApprovalsItself(hookInput: input(session: long.session, transcript: long.url.path), root: root, now: now))
    let user = rollout(["auto_review", "user"])
    check("codex auto-review: latest turn asking the user still shows the island card",
          !CodexRollout.reviewsApprovalsItself(hookInput: input(session: user.session, transcript: user.url.path), root: root, now: now))
    check("codex auto-review: transcript outside the sessions folder is ignored",
          !CodexRollout.reviewsApprovalsItself(hookInput: input(session: UUID().uuidString, transcript: "/tmp/rollout-x.jsonl"), root: root, now: now))
    check("codex auto-review: unknown session falls back to asking",
          !CodexRollout.reviewsApprovalsItself(hookInput: input(session: UUID().uuidString, transcript: nil), root: root, now: now))

    let rawSession = UUID().uuidString.lowercased()
    let rawTurn = UUID().uuidString.lowercased()
    let otherTurn = UUID().uuidString.lowercased()
    let session = CodexRollout.sessionDigest(rawSessionID: rawSession)
    func digest(_ raw: String) -> String {
        "t_" + IdentityDigest.digest(namespace: "turn-v2", components: [session, raw])
    }
    let activityURL = folder.appendingPathComponent("rollout-2026-11-07T12-00-00-\(rawSession).jsonl")
    let metadata = #"{"type":"session_meta","payload":{"id":"\#(rawSession)","fixture":"\#(String(repeating: "x", count: 22_000))"}}"# + "\n"
    func append(_ kind: String, turn: String) {
        let line = #"{"timestamp":"2026-11-07T04:00:00.000Z","type":"event_msg","payload":{"type":"\#(kind)","turn_id":"\#(turn)"}}"# + "\n"
        if let handle = try? FileHandle(forWritingTo: activityURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: activityURL, atomically: true, encoding: .utf8)
        }
    }
    var reader = CodexRollout(root: root)
    check("codex activity: missing rollout is unavailable", reader.activity(session: session, turn: digest(rawTurn), now: now) == .unavailable)
    try? metadata.write(to: activityURL, atomically: true, encoding: .utf8)
    append("task_started", turn: rawTurn)
    check("codex activity: start observes exact turn", reader.activity(session: session, turn: digest(rawTurn), now: now.addingTimeInterval(11)) == .observed)
    append("task_complete", turn: otherTurn)
    check("codex activity: other turn cannot finish target", reader.activity(session: session, turn: digest(rawTurn), now: now.addingTimeInterval(12)) == .observed)
    check("codex activity: other turn completion is recognized", reader.activity(session: session, turn: digest(otherTurn), now: now.addingTimeInterval(12)) == .completed)
    append("turn_aborted", turn: rawTurn)
    check("codex activity: appended abort invalidates cache", reader.activity(session: session, turn: digest(rawTurn), now: now.addingTimeInterval(13)) == .cancelled)
    let longReply = String(repeating: "x", count: 80_000)
    let longCompletion = #"{"timestamp":"2026-11-07T04:00:00.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"\#(rawTurn)","last_agent_message":"\#(longReply)"}}"# + "\n"
    if let handle = try? FileHandle(forWritingTo: activityURL) {
        handle.seekToEndOfFile()
        handle.write(Data(longCompletion.utf8))
        try? handle.close()
    }
    check("codex activity: latest matching completion wins", reader.activity(session: session, turn: digest(rawTurn), now: now.addingTimeInterval(14)) == .completed)
    check("codex activity: unknown turn remains unavailable", reader.activity(session: session, turn: digest(UUID().uuidString.lowercased()), now: now.addingTimeInterval(14)) == .unavailable)
    let failedTurn = UUID().uuidString.lowercased()
    let failedLine = #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"\#(failedTurn)","last_agent_message":"","error":{"message":"fixture"}}}"# + "\n"
    let nestedTurn = UUID().uuidString.lowercased()
    let nestedLine = #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"\#(nestedTurn)","extra":{"error":{"message":"not a failure"}},"last_agent_message":"\#(longReply)"}}"# + "\n"
    let fakeTurn = UUID().uuidString.lowercased()
    let fakeLine = #"{"type":"response_item","payload":{"type":"other","nested":{"type":"event_msg","payload":{"type":"task_complete","turn_id":"\#(fakeTurn)"}}}}"# + "\n"
    if let handle = try? FileHandle(forWritingTo: activityURL) {
        handle.seekToEndOfFile()
        handle.write(Data((failedLine + nestedLine + fakeLine).utf8))
        try? handle.close()
    }
    check("codex activity: top-level payload error marks failed", reader.activity(session: session, turn: digest(failedTurn), now: now.addingTimeInterval(14)) == .failed)
    check("codex activity: nested error does not mark failure", reader.activity(session: session, turn: digest(nestedTurn), now: now.addingTimeInterval(14)) == .completed)
    check("codex activity: nested event cannot forge completion", reader.activity(session: session, turn: digest(fakeTurn), now: now.addingTimeInterval(14)) == .unavailable)
    let padding = String(repeating: "x", count: 64_000)
    let filler = #"{"type":"response_item","payload":{"output":"\#(padding)"}}"# + "\n"
    if let handle = try? FileHandle(forWritingTo: activityURL) {
        handle.seekToEndOfFile()
        for _ in 0..<140 { handle.write(Data(filler.utf8)) }
        try? handle.close()
    }
    check("codex activity: older evidence outside read window is unavailable",
          reader.activity(session: session, turn: digest(rawTurn), now: now.addingTimeInterval(15)) == .unavailable)

    let database = root.deletingLastPathComponent().appendingPathComponent("state_5.sqlite")
    var connection: OpaquePointer?
    let opened = sqlite3_open(database.path, &connection) == SQLITE_OK
    check("codex activity: fixture index opens", opened)
    if let connection {
        let oldRaw = UUID().uuidString.lowercased()
        let emptyRaw = UUID().uuidString.lowercased()
        let escapedRaw = UUID().uuidString.lowercased()
        let oldFolder = root.appendingPathComponent("2026/10/01")
        try? FileManager.default.createDirectory(at: oldFolder, withIntermediateDirectories: true)
        let oldURL = oldFolder.appendingPathComponent("rollout-2026-10-01T12-00-00-\(oldRaw).jsonl")
        let oldTurn = UUID().uuidString.lowercased()
        let oldContent = #"{"type":"session_meta","payload":{"id":"\#(oldRaw)"}}"# + "\n" +
            #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"\#(oldTurn)"}}"# + "\n"
        try? oldContent.write(to: oldURL, atomically: true, encoding: .utf8)
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside")
        try? FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let escapeURL = outside.appendingPathComponent("rollout-2026-10-01T12-00-00-\(escapedRaw).jsonl")
        try? oldContent.write(to: escapeURL, atomically: true, encoding: .utf8)
        let link = root.appendingPathComponent("escaped")
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let escapedPath = link.appendingPathComponent(escapeURL.lastPathComponent)
        let sql = "CREATE TABLE threads(id TEXT PRIMARY KEY, rollout_path TEXT);" +
            "INSERT INTO threads VALUES('\(oldRaw)','\(oldURL.path)');" +
            "INSERT INTO threads VALUES('\(emptyRaw)','');" +
            "INSERT INTO threads VALUES('\(escapedRaw)','\(escapedPath.path)');"
        check("codex activity: fixture index created", sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(connection)
        var indexed = CodexRollout(root: root)
        let oldSession = CodexRollout.sessionDigest(rawSessionID: oldRaw)
        let oldDigest = "t_" + IdentityDigest.digest(namespace: "turn-v2", components: [oldSession, oldTurn])
        check("codex activity: indexed old session completes", indexed.activity(session: oldSession, turn: oldDigest, now: now) == .completed)
        check("codex activity: indexed path survives scan throttle", indexed.activity(session: oldSession, turn: oldDigest, now: now.addingTimeInterval(1)) == .completed)
        let absent = CodexRollout.sessionDigest(rawSessionID: UUID().uuidString.lowercased())
        check("codex activity: complete index confirms absent session", indexed.activity(session: absent, turn: oldDigest, now: now.addingTimeInterval(2)) == .missingSession)
        check("codex activity: indexed empty path remains unavailable", indexed.activity(session: CodexRollout.sessionDigest(rawSessionID: emptyRaw), turn: oldDigest, now: now.addingTimeInterval(3)) == .unavailable)
        check("codex activity: symlinked parent outside root remains unavailable", indexed.activity(session: CodexRollout.sessionDigest(rawSessionID: escapedRaw), turn: oldDigest, now: now.addingTimeInterval(4)) == .unavailable)
    }
}
