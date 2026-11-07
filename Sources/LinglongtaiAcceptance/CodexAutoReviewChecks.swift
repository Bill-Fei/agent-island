import Foundation
import LinglongtaiShared

/// "帮我批准" (auto_review): Codex asks no one, so the island must not either.
func runCodexAutoReviewChecks(check: (String, Bool) -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-auto-review-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
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
}
